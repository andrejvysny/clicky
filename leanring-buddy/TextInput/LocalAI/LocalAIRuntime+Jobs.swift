import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Bookkeeping for the one expensive job a role's worker may run at a time.
final class LocalAIJob {
    let id = UUID()
    let group: LocalModelGroup
    let jobClass: LocalAIJobClass
    var cancel: () -> Void = {}
    var completion: Task<Void, Never>?

    init(group: LocalModelGroup, jobClass: LocalAIJobClass) { self.group = group; self.jobClass = jobClass }
}

extension LocalAIRuntime {
    /// Runs `body` as the role's single expensive job. A foreground job cancels a running benchmark job first;
    /// any other overlap is refused with `.busy` rather than queued silently. The body runs off the main actor,
    /// so large payload writes never block the UI.
    /// `slotWait` lets a foreground caller wait that many seconds for another foreground job to finish instead of
    /// failing with `.busy` at once; the wait ends early on cancellation.
    func perform<T: Sendable>(_ group: LocalModelGroup, jobClass: LocalAIJobClass = .foreground, slotWait: TimeInterval = 0,
                              _ body: @escaping @Sendable (LocalWorkerConnection, LocalModelReference) async throws -> T) async throws -> T {
        if jobClass == .benchmark { try requireCoolEnough() }
        let role = group.role
        if jobClass == .foreground, slotWait > 0 { try await waitForForegroundSlot(role, seconds: slotWait) }
        let job = try await claimSlot(group, jobClass: jobClass)
        guard let model = loaded[group], let connection = connections[role], connection.isRunning else {
            finish(job)
            throw LocalAIError.notLoaded(displayName(group))
        }
        let reference = model.reference
        let work = Task.detached { try await body(connection, reference) }
        job.cancel = { work.cancel() }
        job.completion = Task { _ = await work.result }
        if groups[group]?.phase == .ready { groups[group]?.phase = .running }
        idle.touch(group, at: env.now())
        let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
        finish(job)
        return try result.get()
    }

    /// Takes the role's single expensive-job slot. A foreground claim cancels a running benchmark job first; if
    /// another job took the slot while waiting, or any other job holds it, the claim is refused with `.busy`.
    /// Loads claim the slot too, so a load never overlaps inference on the same worker.
    func claimSlot(_ group: LocalModelGroup, jobClass: LocalAIJobClass) async throws -> LocalAIJob {
        let role = group.role
        if let active = activeJobs[role] {
            guard active.jobClass == .benchmark, jobClass == .foreground else { throw LocalAIError.busy }
            cancelJob(active)
            await active.completion?.value
            if activeJobs[role]?.id == active.id { activeJobs[role] = nil }
            if activeJobs[role] != nil { throw LocalAIError.busy }
        }
        let job = LocalAIJob(group: group, jobClass: jobClass)
        activeJobs[role] = job
        return job
    }

    /// Polls until no foreground job holds the role's slot or `seconds` pass; `claimSlot` then decides as usual.
    func waitForForegroundSlot(_ role: LocalWorkerRole, seconds: TimeInterval) async throws {
        // Wall time, not `env.now`: the wait bounds what the user experiences even when tests fake idle time.
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(seconds * 1000))
        while let active = activeJobs[role], active.jobClass == .foreground, clock.now < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func cancelJob(_ job: LocalAIJob) {
        if groups[job.group]?.phase == .running { groups[job.group]?.phase = .canceling }
        job.cancel()
    }

    func cancelJobs(for group: LocalModelGroup) {
        if let job = activeJobs[group.role], job.group == group { cancelJob(job) }
    }

    func finish(_ job: LocalAIJob) {
        let role = job.group.role
        if activeJobs[role]?.id == job.id { activeJobs[role] = nil }
        if loaded[job.group] != nil, [.running, .canceling].contains(groups[job.group]?.phase) { groups[job.group]?.phase = .ready }
        idle.touch(job.group, at: env.now())
        stopWorkersIfIdle()
    }

    /// Streams a generation for a loaded text or vision model. The image (if any) is sent from a detached task.
    func generate(group: LocalModelGroup, messages: [LocalChatMessage], imagePNG: Data? = nil,
                  parameters: LocalGenerationParameters, jobClass: LocalAIJobClass = .foreground, slotWait: TimeInterval = 0)
        -> AsyncThrowingStream<LocalWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await perform(group, jobClass: jobClass, slotWait: slotWait) { connection, reference in
                        let command = LocalWorkerCommand.generate(request: UUID(), modelIdentifier: reference.identifier, messages: messages,
                                                                  parameters: parameters, hasImage: imagePNG != nil)
                        for try await event in connection.request(command, payload: imagePNG ?? Data()) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Recognition on the speech worker, optional cleanup on the inference worker. The caller must have loaded
    /// speech; cleanup is used only when its group is loaded too.
    func speechPipeline(cleanup: Bool, prompt: LocalCleanupPrompt = .s1Mini) throws -> LocalSpeechPipeline {
        guard let speech = loaded[.speech], let speechConnection = connections[.speech], speechConnection.isRunning else {
            throw LocalAIError.notLoaded(displayName(.speech))
        }
        idle.touch(.speech, at: env.now())
        var inference: LocalWorkerConnection?
        var cleanupModel: String?
        if cleanup, let model = loaded[.cleanup], let connection = connections[.inference], connection.isRunning {
            inference = connection
            cleanupModel = model.reference.identifier
            idle.touch(.cleanup, at: env.now())
        }
        return LocalSpeechPipeline(speech: speechConnection, recognizer: speech.reference.identifier,
                                   inference: inference, cleanupModel: cleanupModel, prompt: prompt)
    }
}
