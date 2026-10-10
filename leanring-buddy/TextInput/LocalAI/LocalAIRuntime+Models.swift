import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Explicit model asset operations. Nothing here runs unless the user pressed the matching button.
extension LocalAIRuntime {
    /// Runs blocking or byte-streaming store work off the main actor while still honoring cancellation.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached { try await work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func download(_ group: LocalModelGroup) {
        guard assetsFree(group), let entry = selectedEntry(group), installedModel(group) == nil else { return }
        groups[group]?.phase = .downloading
        groups[group]?.downloadProgress = 0
        groups[group]?.lastError = nil
        let store = self.store
        downloadTasks[group] = Task { [weak self] in
            do {
                let runtime = self
                _ = try await Self.offMain {
                    try await store.download(entry) { done, total in
                        guard total > 0 else { return }
                        Task { @MainActor in
                            if runtime?.groups[group]?.phase == .downloading { runtime?.groups[group]?.downloadProgress = Double(done) / Double(total) }
                        }
                    }
                }
                self?.finishAssetOperation(group, error: nil)
            } catch {
                self?.finishAssetOperation(group, error: error)
            }
            self?.downloadTasks[group] = nil
        }
    }

    func cancelDownload(_ group: LocalModelGroup) {
        guard let task = downloadTasks[group] else { return }
        groups[group]?.phase = .canceling
        task.cancel()
    }

    /// Copies a folder the user chose into the verified store; every file is size- and hash-checked first.
    func importFolder(_ folder: URL, for group: LocalModelGroup) async {
        guard assetsFree(group), let entry = selectedEntry(group) else { return }
        groups[group]?.phase = .downloading
        groups[group]?.downloadProgress = nil
        groups[group]?.lastError = nil
        let store = self.store
        let task = Task { [weak self] in
            do {
                _ = try await Self.offMain { try await store.importFolder(folder, as: entry) }
                self?.finishAssetOperation(group, error: nil)
            } catch {
                self?.finishAssetOperation(group, error: error)
            }
            self?.downloadTasks[group] = nil
        }
        downloadTasks[group] = task
        await task.value
    }

    func verify(_ group: LocalModelGroup) async {
        guard assetsFree(group), let model = installedModel(group) else { return }
        let store = self.store
        let task = Task { [weak self] in
            do {
                try await Self.offMain { try await store.verify(model) }
                self?.groups[group]?.lastError = nil
                self?.settlePhase(group)
            } catch {
                let message = "Verification failed: " + Self.describe(error)
                self?.groups[group]?.lastError = message
                if self?.assetPhaseOwned(group) == true { self?.groups[group]?.phase = .failed(message) }
            }
            self?.downloadTasks[group] = nil
        }
        downloadTasks[group] = task
        groups[group]?.phase = .downloading; groups[group]?.downloadProgress = nil
        await task.value
    }

    /// Deletes the installed files. Refused while the model is loaded, loading or busy.
    func remove(_ group: LocalModelGroup) throws {
        guard let entry = selectedEntry(group) else { return }
        guard loaded[group] == nil, loadTasks[group] == nil, downloadTasks[group] == nil, activeJobs[group.role]?.group != group else {
            throw LocalAIError.stillInUse(entry.displayName)
        }
        do { try store.remove(entry.id) } catch {
            groups[group]?.lastError = Self.describe(error)
            throw error
        }
        groups[group]?.lastError = nil
        if case .failed = groups[group]?.phase { groups[group]?.phase = .missing }
        refreshInstalled()
        groups[group]?.phase = restPhase(group)
    }

    /// Downloads, imports and verification touch the files a worker may be reading: refuse while the group is
    /// loading, loaded, running or unloading, or while another asset operation or any job uses it.
    func assetsFree(_ group: LocalModelGroup) -> Bool {
        guard downloadTasks[group] == nil, loaded[group] == nil, loadTasks[group] == nil, activeJobs[group.role]?.group != group else { return false }
        switch groups[group]?.phase {
        case .loading, .ready, .running, .canceling, .unloading: return false
        default: return true
        }
    }

    /// Asset operations own the phase only while it is one of theirs.
    private func assetPhaseOwned(_ group: LocalModelGroup) -> Bool {
        switch groups[group]?.phase {
        case .loading, .ready, .running, .unloading: return false
        default: return loaded[group] == nil
        }
    }

    private func settlePhase(_ group: LocalModelGroup) {
        if assetPhaseOwned(group) { groups[group]?.phase = restPhase(group) }
    }

    private func finishAssetOperation(_ group: LocalModelGroup, error: Error?) {
        groups[group]?.downloadProgress = nil
        refreshInstalled()
        guard assetPhaseOwned(group) else { return }
        guard let error else { groups[group]?.phase = restPhase(group); return }
        if case LocalModelInstallError.canceled = error { groups[group]?.phase = restPhase(group); return }
        if error is CancellationError { groups[group]?.phase = restPhase(group); return }
        let message = Self.describe(error)
        groups[group]?.lastError = message
        groups[group]?.phase = .failed(message)
    }
}
