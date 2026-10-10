import AppKit
import SwiftUI

struct LabModelsTab: View {
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !runtime.workerAvailable {
                LabCard { labError("The local worker is not bundled with this build, so models can be downloaded but not loaded. Debug builds can point CLICKY_LOCAL_WORKER at a worker executable.") }
            }
            ForEach(LocalModelGroup.allCases, id: \.rawValue) { LabModelCard(runtime: runtime, group: $0) }
            LabCard(title: "Resource protection") {
                Toggle("Protect foreground apps", isOn: $runtime.protectForeground).font(.system(size: 12))
                labNote("Lowers CPU priority only; GPU sharing is not guaranteed.")
                labNote("Models load only when you press Load (or by the policy you choose below). Opening this window, recording or running a test never downloads anything.")
            }
        }
    }
}

private struct LabModelCard: View {
    @ObservedObject var runtime: LocalAIRuntime
    let group: LocalModelGroup
    @State private var confirmRemove = false

    private var state: LocalAIRuntime.GroupState { runtime.groups[group] ?? .init(selectedEntryID: "") }
    private var entry: LocalModelCatalogEntry? { runtime.selectedEntry(group) }
    private var busy: Bool {
        switch state.phase {
        case .downloading, .loading, .running, .canceling, .unloading: return true
        default: return false
        }
    }

    var body: some View {
        LabCard(title: group.title) {
            HStack(spacing: 10) {
                Picker("Model", selection: Binding(get: { state.selectedEntryID }, set: { id in Task { await runtime.select(id, for: group) } })) {
                    ForEach(runtime.entries(for: group)) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 360).disabled(state.phase == .downloading || state.phase == .loading)
                LabPhaseBadge(phase: state.phase, progress: state.downloadProgress)
                Spacer()
                if let load = state.loadMilliseconds { Text("loaded in \(LabFormat.milliseconds(load))").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary) }
            }
            if let entry {
                Text("\(LabFormat.size(entry.totalBytes)) · \(entry.license) · \(entry.quantization) · rev \(entry.revision.prefix(7))")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                if !entry.notes.isEmpty { labNote(entry.notes) }
            } else {
                labNote("No model of this kind is in the catalog.")
            }
            if state.phase == .downloading, let progress = state.downloadProgress { ProgressView(value: progress).tint(ClickyChrome.ask) }
            if let error = state.lastError { labError(error) }
            actions
            policy
        }
        .confirmationDialog("Remove \(entry?.displayName ?? "model") from this Mac?", isPresented: $confirmRemove) {
            Button("Remove files", role: .destructive) {
                do { try runtime.remove(group) } catch { runtime.groups[group]?.lastError = error.localizedDescription }
            }
        } message: { Text("The downloaded files are deleted. You can download or import them again.") }
    }

    private var actions: some View {
        let installed = runtime.installedModel(group) != nil
        let loadedNow = runtime.isLoaded(group)
        return HStack(spacing: 6) {
            if state.phase == .downloading || state.phase == .canceling {
                Button("Cancel") { runtime.cancelDownload(group) }.islandButton(.warning).disabled(state.phase == .canceling || state.downloadProgress == nil)
            } else {
                Button("Download") { runtime.download(group) }.islandButton(.primary).disabled(installed || busy || entry == nil)
            }
            Button("Import folder…") { importFolder() }.islandButton(.secondary).disabled(installed || busy || entry == nil)
            Button("Verify") { Task { await runtime.verify(group) } }.islandButton(.secondary).disabled(!installed || busy)
            Button("Remove") { confirmRemove = true }.islandButton(.secondary).disabled(!installed || loadedNow || busy)
            Spacer()
            if loadedNow {
                Button("Unload") { Task { await runtime.unload(group) } }.islandButton(.secondary).disabled(state.phase == .unloading)
            } else if state.phase == .loading {
                Button("Cancel load") { Task { await runtime.unload(group) } }.islandButton(.warning)
            } else {
                Button("Load") { Task { try? await runtime.load(group) } }.islandButton(.primary).disabled(!installed || busy)
            }
        }
    }

    private var policy: some View {
        HStack(spacing: 14) {
            Picker("Policy", selection: Binding(get: { runtime.residency[group].load }, set: { runtime.residency[group].load = $0 })) {
                ForEach(LocalLoadPolicy.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .frame(maxWidth: 260).font(.system(size: 12))
            Picker("Idle unload", selection: Binding(get: { runtime.residency[group].idleUnloadMinutes ?? 0 },
                                                      set: { runtime.residency[group].idleUnloadMinutes = $0 == 0 ? nil : $0 })) {
                Text("Never").tag(0)
                ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
            }
            .frame(maxWidth: 200).font(.system(size: 12))
            Spacer()
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder containing the model files (a Hugging Face download or cache snapshot)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runtime.importFolder(url, for: group) }
    }
}
