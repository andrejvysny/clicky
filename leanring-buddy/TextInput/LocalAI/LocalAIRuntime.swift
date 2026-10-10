import Combine
import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

extension LocalModelGroup {
    var role: LocalWorkerRole { self == .speech ? .speech : .inference }
    var title: String {
        switch self {
        case .vision: return "Vision"
        case .cleanup: return "Cleanup"
        case .speech: return "Speech"
        }
    }
}

/// Expensive jobs hold a role's worker; a foreground job (voice, Lab Run) preempts a benchmark job.
enum LocalAIJobClass: Sendable { case foreground, benchmark }

enum LocalAIError: LocalizedError, Equatable {
    case needsExplicitLoad(String), notInstalled(String), notLoaded(String), busy, workerMissing
    case overBudget(String), thermal(String), stillInUse(String)

    var errorDescription: String? {
        switch self {
        case .needsExplicitLoad(let model): return "Load \(model) first."
        case .notInstalled(let model): return "\(model) is not installed. Download or import it in the Models tab."
        case .notLoaded(let model): return "\(model) is not loaded."
        case .busy: return "Another local job is running. Wait for it to finish or cancel it."
        case .workerMissing: return "The local worker is not bundled with this build. Set CLICKY_LOCAL_WORKER in a debug build."
        case .overBudget(let detail): return detail
        case .thermal(let state):
            return "This Mac is running hot (thermal state \(state)). Benchmarks are paused; let it cool down and try again."
        case .stillInUse(let model): return "\(model) is loaded or busy. Unload it first."
        }
    }
}

/// Owns local model assets, worker processes, load/unload policy and resource protection for the Local AI Lab
/// and future voice features. It starts nothing by itself: with the default Manual policy no worker, download,
/// disk hashing or inference happens until the user presses Load or Run.
@MainActor
final class LocalAIRuntime: ObservableObject {
    /// Set by the app delegate so Settings entry points can reach the one runtime.
    static var shared: LocalAIRuntime?

    enum Phase: Equatable {
        case missing, downloading, installed, loading, ready, running, canceling, unloading
        case failed(String)
    }

    struct GroupState: Equatable {
        var selectedEntryID: String
        var phase: Phase = .missing
        var downloadProgress: Double?
        var loadMilliseconds: Double?
        var lastError: String?
    }

    enum WorkerState: Equatable {
        case stopped, starting
        case ready(LocalWorkerReadiness)
        case failed(String)
    }

    struct MemorySnapshot: Equatable {
        var hostFootprintBytes: UInt64 = 0
        var workers: [LocalWorkerRole: LocalMemoryReport] = [:]
        var pressure: LocalMemoryPressure = .normal
        var thermal: ProcessInfo.ThermalState = .nominal
        var measuredAt: Date?
    }

    struct LoadedModel {
        let entryID: String
        let reference: LocalModelReference
        let generation: UInt64
    }

    static let defaultEntryIDs: [LocalModelGroup: String] = [
        .vision: "qwen3-vl-4b-instruct-4bit", .cleanup: "s1-mini", .speech: "parakeet-tdt-0.6b-v3-coreml",
    ]

    @Published var groups: [LocalModelGroup: GroupState] = [:]
    @Published var workers: [LocalWorkerRole: WorkerState] = [.inference: .stopped, .speech: .stopped]
    @Published var memory = MemorySnapshot()
    @Published var installedByEntry: [String: InstalledLocalModel] = [:]
    @Published var residency: LocalResidencySettings {
        didSet { persistResidency() }
    }
    @Published var protectForeground: Bool {
        didSet {
            preferences.set(protectForeground, forKey: "localProtectForeground")
            // Raising the nice value needs no privilege; lowering it again is not possible, so turning the
            // option off only affects workers started afterwards.
            if protectForeground { applyPriorityToRunningWorkers() }
        }
    }
    var workerAvailable: Bool { env.workerExecutable() != nil }

    let env: LocalAIEnvironment
    let preferences: UserDefaults
    let store: LocalModelStore
    var loaded: [LocalModelGroup: LoadedModel] = [:]
    var generations: [LocalModelGroup: UInt64] = [:]
    var loadTasks: [LocalModelGroup: (generation: UInt64, task: Task<Void, Error>)] = [:]
    var downloadTasks: [LocalModelGroup: Task<Void, Never>] = [:]
    var connections: [LocalWorkerRole: LocalWorkerConnection] = [:]
    var workerTokens: [LocalWorkerRole: UUID] = [:]
    var startTasks: [LocalWorkerRole: Task<LocalWorkerConnection, Error>] = [:]
    var activeJobs: [LocalWorkerRole: LocalAIJob] = [:]
    var idle = LocalIdleTracker()
    var idleTimer: Timer?
    var pressureTask: Task<Void, Never>?

    init(environment: LocalAIEnvironment? = nil, preferences: UserDefaults = .standard) {
        let environment = environment ?? .live
        env = environment
        self.preferences = preferences
        store = LocalModelStore(root: environment.modelsRoot)
        residency = preferences.data(forKey: "localResidency")
            .flatMap { try? JSONDecoder().decode(LocalResidencySettings.self, from: $0) } ?? LocalResidencySettings()
        protectForeground = preferences.object(forKey: "localProtectForeground") as? Bool ?? true
        for group in LocalModelGroup.allCases {
            groups[group] = GroupState(selectedEntryID: Self.initialSelection(group, catalog: environment.catalog, preferences: preferences))
        }
        // Receipts are small JSON files; no model file is opened or hashed here.
        refreshInstalled()
        let events = environment.memoryPressure()
        pressureTask = Task { [weak self] in
            for await level in events {
                guard let self else { return }
                await handlePressure(level)
            }
        }
    }

    private static func initialSelection(_ group: LocalModelGroup, catalog: [LocalModelCatalogEntry], preferences: UserDefaults) -> String {
        let candidates = catalog.filter { $0.group == group }
        if let saved = preferences.string(forKey: "localModel.\(group.rawValue)"), candidates.contains(where: { $0.id == saved }) { return saved }
        if let preferred = defaultEntryIDs[group], candidates.contains(where: { $0.id == preferred }) { return preferred }
        return candidates.first?.id ?? ""
    }

    // MARK: Queries

    func entries(for group: LocalModelGroup) -> [LocalModelCatalogEntry] { env.catalog.filter { $0.group == group } }

    func selectedEntry(_ group: LocalModelGroup) -> LocalModelCatalogEntry? {
        let identifier = groups[group]?.selectedEntryID
        return env.catalog.first { $0.id == identifier && $0.group == group }
    }

    func installedModel(_ group: LocalModelGroup) -> InstalledLocalModel? {
        guard let entry = selectedEntry(group), let model = installedByEntry[entry.id], model.revision == entry.revision else { return nil }
        return model
    }

    func isLoaded(_ group: LocalModelGroup) -> Bool { loaded[group] != nil }
    func loadedReference(_ group: LocalModelGroup) -> LocalModelReference? { loaded[group]?.reference }
    func displayName(_ group: LocalModelGroup) -> String { selectedEntry(group)?.displayName ?? group.title }

    func readiness(for role: LocalWorkerRole) -> LocalWorkerReadiness? {
        if case .ready(let readiness) = workers[role] { return readiness }
        return nil
    }

    func refreshInstalled() {
        installedByEntry = Dictionary(store.installed().map { ($0.entryID, $0) }, uniquingKeysWith: { first, second in
            first.installedAt >= second.installedAt ? first : second
        })
        for group in LocalModelGroup.allCases where loaded[group] == nil && downloadTasks[group] == nil {
            if case .failed = groups[group]?.phase { continue }
            groups[group]?.phase = restPhase(group)
        }
    }

    func restPhase(_ group: LocalModelGroup) -> Phase {
        if loaded[group] != nil { return .ready }
        return installedModel(group) == nil ? .missing : .installed
    }

    private func persistResidency() {
        if let data = try? JSONEncoder().encode(residency) { preferences.set(data, forKey: "localResidency") }
    }

    // MARK: Selection and policy

    /// Switching models unloads the current one and cancels a load in flight; it never touches any assistant provider.
    func select(_ entryID: String, for group: LocalModelGroup) async {
        guard entryID != groups[group]?.selectedEntryID,
              env.catalog.contains(where: { $0.id == entryID && $0.group == group }) else { return }
        invalidate(group)
        await unloadLoaded(group)
        groups[group]?.selectedEntryID = entryID
        groups[group]?.lastError = nil
        groups[group]?.loadMilliseconds = nil
        preferences.set(entryID, forKey: "localModel.\(group.rawValue)")
        groups[group]?.phase = restPhase(group)
        stopWorkersIfIdle()
    }

    /// Supersedes any load in flight: its late completion is unloaded again instead of becoming resident.
    func invalidate(_ group: LocalModelGroup) {
        generations[group, default: 0] += 1
        loadTasks[group]?.task.cancel()
        loadTasks[group] = nil
    }

    func setPhase(_ group: LocalModelGroup, _ phase: Phase, generation: UInt64? = nil) {
        if let generation, generations[group, default: 0] != generation { return }
        groups[group]?.phase = phase
    }

    // MARK: Load and unload

    func load(_ group: LocalModelGroup) async throws {
        if loaded[group] != nil { return }
        if let existing = loadTasks[group] { try await existing.task.value; return }
        guard let entry = selectedEntry(group) else { throw LocalAIError.notInstalled(group.title) }
        guard let installed = installedModel(group) else { throw LocalAIError.notInstalled(entry.displayName) }
        guard env.workerExecutable() != nil else {
            groups[group]?.lastError = LocalAIError.workerMissing.errorDescription
            throw LocalAIError.workerMissing
        }
        if groups[group]?.phase == .unloading { throw LocalAIError.busy }
        if memory.pressure == .critical {
            let detail = "The system is under critical memory pressure. Close other apps, then Load \(entry.displayName) again."
            groups[group]?.lastError = detail
            throw LocalAIError.overBudget(detail)
        }
        let generation = generations[group, default: 0] + 1
        generations[group] = generation
        groups[group]?.phase = .loading
        groups[group]?.lastError = nil
        let task = Task { try await performLoad(group, generation: generation, entry: entry, installed: installed) }
        loadTasks[group] = (generation, task)
        defer { if loadTasks[group]?.generation == generation { loadTasks[group] = nil } }
        try await task.value
    }

    private func performLoad(_ group: LocalModelGroup, generation: UInt64, entry: LocalModelCatalogEntry,
                             installed: InstalledLocalModel) async throws {
        let role = group.role
        var connection: LocalWorkerConnection?
        var requested = false
        var slot: LocalAIJob?
        defer { if let slot { finish(slot) } }
        do {
            slot = try await claimSlot(group, jobClass: .foreground)
            try ensureCurrent(group, generation)
            let resident = await residentFootprint()
            try ensureCurrent(group, generation)
            let estimate = LocalResidencyPlanner.estimatedFootprint(weightBytes: entry.totalBytes)
            if case .overBudget(let required, let available) = LocalResidencyPlanner.memoryAdmission(
                estimatedBytes: estimate, residentBytes: resident, physicalMemory: env.physicalMemory) {
                let detail = "\(entry.displayName) needs about \(Self.megabytes(required)) MB but only \(Self.megabytes(available)) MB of the local model memory budget is free. Unload another model first."
                setPhase(group, restPhase(group), generation: generation)
                groups[group]?.lastError = detail
                throw LocalAIError.overBudget(detail)
            }
            connection = try await ensureWorker(role)
            try ensureCurrent(group, generation)
            requested = true
            let result = try await LocalSpeechPipeline.run(connection!, .load(request: UUID(), model: installed.reference, warmUp: false))
            try ensureCurrent(group, generation)
            loaded[group] = LoadedModel(entryID: entry.id, reference: installed.reference, generation: generation)
            idle.touch(group, at: env.now())
            groups[group]?.loadMilliseconds = result.worker.loadMilliseconds ?? result.hostMilliseconds
            groups[group]?.phase = .ready
        } catch {
            if generations[group, default: 0] != generation || error is CancellationError {
                // The worker may have finished loading before it saw the cancel: make sure nothing stays resident.
                if requested, let connection { await discard(connection, installed.reference.identifier) }
                stopWorkersIfIdle()
                throw CancellationError()
            }
            if case LocalAIError.overBudget = error { throw error }
            if case LocalAIError.busy = error {
                setPhase(group, restPhase(group), generation: generation)
                groups[group]?.lastError = LocalAIError.busy.errorDescription
                throw error
            }
            let message = Self.describe(error)
            groups[group]?.phase = .failed(message)
            groups[group]?.lastError = message
            stopWorkersIfIdle()
            throw error
        }
    }

    private func ensureCurrent(_ group: LocalModelGroup, _ generation: UInt64) throws {
        if generations[group, default: 0] != generation { throw CancellationError() }
    }

    func unload(_ group: LocalModelGroup) async {
        invalidate(group)
        await unloadLoaded(group)
        stopWorkersIfIdle()
    }

    func unloadLoaded(_ group: LocalModelGroup) async {
        let role = group.role
        guard let model = loaded[group] else {
            if case .failed = groups[group]?.phase {} else { groups[group]?.phase = restPhase(group) }
            return
        }
        // Mark it gone first, so no new job or load can start against weights that are being released.
        loaded[group] = nil
        groups[group]?.phase = .unloading
        if let job = activeJobs[role], job.group == group { cancelJob(job); await job.completion?.value }
        if let connection = connections[role], connection.isRunning { await discard(connection, model.reference.identifier) }
        idle.forget(group)
        groups[group]?.loadMilliseconds = nil
        if groups[group]?.phase == .unloading { groups[group]?.phase = restPhase(group) }
    }

    /// Unload request that survives cancellation of the calling task and ignores worker-side errors.
    func discard(_ connection: LocalWorkerConnection, _ identifier: String) async {
        await Task { _ = try? await LocalSpeechPipeline.run(connection, .unload(request: UUID(), modelIdentifier: identifier)) }.value
    }

    func ensureReady(_ group: LocalModelGroup, explicitRun: Bool) async throws {
        switch LocalResidencyPlanner.admission(policy: residency[group], isLoaded: isLoaded(group), explicitRun: explicitRun) {
        case .ready: return
        case .needsExplicitLoad: throw LocalAIError.needsExplicitLoad(displayName(group))
        case .loadAutomatically: try await load(group)
        case .overBudget(let required, let available):
            throw LocalAIError.overBudget("Needs \(Self.megabytes(required)) MB, \(Self.megabytes(available)) MB free.")
        }
    }

    /// Loads only groups whose policy is Load at startup; with the default Manual policy this does nothing.
    func startupPreload() async {
        for group in LocalResidencyPlanner.groupsToPreload(residency) where installedModel(group) != nil {
            try? await load(group)
        }
    }

    nonisolated static func megabytes(_ bytes: UInt64) -> UInt64 { bytes / (1024 * 1024) }

    nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? LocalWorkerError { return error.message }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if let error = error as? LocalModelInstallError { return Self.describe(install: error) }
        return error.localizedDescription
    }

    private nonisolated static func describe(install error: LocalModelInstallError) -> String {
        switch error {
        case .insufficientDisk(let required, let available):
            return "Not enough disk space: \(required / 1_048_576) MB needed, \(available / 1_048_576) MB free."
        case .unsafePath(let path): return "Unsafe file path in model: \(path)"
        case .missingFile(let path): return "Missing file: \(path)"
        case .sizeMismatch(let path): return "Wrong file size: \(path)"
        case .hashMismatch(let path): return "Checksum mismatch: \(path)"
        case .unexpectedFile(let path): return "Unexpected file: \(path)"
        case .canceled: return "Canceled."
        case .network(let detail): return "Network error: \(detail)"
        case .alreadyInstalled: return "This model is already installed."
        case .inProgress: return "Another install of this model is running."
        }
    }
}
