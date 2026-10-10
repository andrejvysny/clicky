import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Worker process lifecycle and resource protection. Workers start only for an explicit Load, a Load at startup
/// policy or an explicit benchmark Run, stop when their last model unloads, and are never restarted automatically.
extension LocalAIRuntime {
    static let crashMessage = "Worker stopped unexpectedly — Load again"
    static let crashMessageOnDemand = "Worker stopped unexpectedly — it will reload on next use"

    /// Neither variant replays the failed request; on-demand and startup policies reload only when the user asks again.
    func crashText(_ group: LocalModelGroup) -> String {
        residency[group].load == .manual ? Self.crashMessage : Self.crashMessageOnDemand
    }

    func ensureWorker(_ role: LocalWorkerRole) async throws -> LocalWorkerConnection {
        if let connection = connections[role], connection.isRunning { return connection }
        if let pending = startTasks[role] { return try await pending.value }
        guard let executable = env.workerExecutable() else {
            workers[role] = .failed(LocalAIError.workerMissing.errorDescription ?? "")
            throw LocalAIError.workerMissing
        }
        let token = UUID()
        workerTokens[role] = token
        workers[role] = .starting
        let connection = env.makeConnection(executable, role) { [weak self] exit in
            let runtime = self
            Task { @MainActor in runtime?.workerExited(role, token: token, exit: exit) }
        }
        let task = Task { () -> LocalWorkerConnection in
            _ = try await connection.start()
            return connection
        }
        startTasks[role] = task
        defer { startTasks[role] = nil }
        do {
            let ready = try await task.value
            guard workerTokens[role] == token, let readiness = connection.readiness else { throw CancellationError() }
            connections[role] = ready
            workers[role] = .ready(readiness)
            if protectForeground { _ = LocalWorkerPriority.foregroundProtected.apply(to: readiness.processIdentifier) }
            startIdleTimer()
            return ready
        } catch {
            workerTokens[role] = nil
            connection.terminate()
            workers[role] = .failed(Self.describe(error))
            throw error
        }
    }

    func applyPriorityToRunningWorkers() {
        for (_, state) in workers {
            if case .ready(let readiness) = state { _ = LocalWorkerPriority.foregroundProtected.apply(to: readiness.processIdentifier) }
        }
    }

    func roleInUse(_ role: LocalWorkerRole) -> Bool {
        LocalModelGroup.allCases.contains { $0.role == role && (loaded[$0] != nil || loadTasks[$0] != nil) }
            || activeJobs[role] != nil
    }

    func stopWorkersIfIdle() {
        for role in Array(connections.keys) where startTasks[role] == nil && !roleInUse(role) { stopWorker(role) }
        if connections.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    private func stopWorker(_ role: LocalWorkerRole) {
        workerTokens[role] = nil
        connections.removeValue(forKey: role)?.shutdown()
        workers[role] = .stopped
    }

    /// A worker ended. Deliberate stops clear the token first, so only crashes, kills and protocol violations land here.
    func workerExited(_ role: LocalWorkerRole, token: UUID, exit: LocalWorkerExit) {
        guard workerTokens[role] == token, startTasks[role] == nil else { return }
        workerTokens[role] = nil
        connections[role] = nil
        activeJobs[role] = nil
        let roleGroups = LocalModelGroup.allCases.filter { $0.role == role }
        workers[role] = .failed(roleGroups.contains { residency[$0].load == .manual } ? Self.crashMessage : Self.crashMessageOnDemand)
        for group in roleGroups {
            invalidate(group)
            loaded[group] = nil
            idle.forget(group)
            switch groups[group]?.phase {
            case .loading, .ready, .running, .canceling, .unloading:
                groups[group]?.phase = .failed(crashText(group))
                groups[group]?.lastError = crashText(group)
            default: break
            }
        }
        if connections.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    // MARK: Memory and pressure

    func refreshMemory() async {
        var reports: [LocalWorkerRole: LocalMemoryReport] = [:]
        for (role, connection) in connections where connection.isRunning {
            do {
                for try await event in connection.request(.memory(request: UUID())) {
                    if case .memory(_, _, let report) = event { reports[role] = report }
                }
            } catch {}
        }
        memory = MemorySnapshot(hostFootprintBytes: env.hostFootprint(), workers: reports, pressure: memory.pressure,
                                thermal: env.thermalState(), measuredAt: Date())
    }

    /// Measured (not catalog) footprint of everything currently resident, for memory admission.
    func residentFootprint() async -> UInt64 {
        guard !connections.isEmpty else { return 0 }
        await refreshMemory()
        return memory.workers.values.reduce(0) { $0 + $1.physicalFootprintBytes }
    }

    func clearCaches() async {
        for connection in connections.values where connection.isRunning {
            _ = try? await LocalSpeechPipeline.run(connection, .clearCaches(request: UUID()))
        }
    }

    /// Warning: stop background benchmarks and drop caches. Critical: also unload models that are not mid-job.
    func handlePressure(_ level: LocalMemoryPressure) async {
        memory.pressure = level
        guard level != .normal else { return }
        for job in activeJobs.values where job.jobClass == .benchmark { cancelJob(job) }
        await clearCaches()
        if level == .critical {
            let busy = Set(activeJobs.values.map(\.group))
            for group in LocalModelGroup.allCases where loaded[group] != nil && !busy.contains(group) { await unload(group) }
        }
    }

    func requireCoolEnough() throws {
        let state = env.thermalState()
        memory.thermal = state
        if state == .serious { throw LocalAIError.thermal("serious") }
        if state == .critical { throw LocalAIError.thermal("critical") }
    }

    // MARK: Idle unload

    func startIdleTimer() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.idleTick() }
        }
    }

    func idleTick() async {
        let busy = Set(activeJobs.values.map(\.group))
        let due = idle.due(at: env.now(), settings: residency, loaded: Set(loaded.keys), busy: busy)
        for group in due { await unload(group) }
    }

    // MARK: Shutdown

    /// App quit: cancel work and stop every worker. Nothing is persisted but preferences.
    func shutdown() {
        pressureTask?.cancel(); pressureTask = nil
        idleTimer?.invalidate(); idleTimer = nil
        for group in LocalModelGroup.allCases { invalidate(group); downloadTasks[group]?.cancel() }
        for job in activeJobs.values { cancelJob(job) }
        activeJobs.removeAll()
        for role in Array(connections.keys) { stopWorker(role) }
        for (role, task) in startTasks { workerTokens[role] = nil; task.cancel() }
        loaded.removeAll()
    }
}
