import AppKit
import SwiftUI

/// One model group: role, model, size, status, load time and a single primary action.
/// Details, policy and destructive actions live in the expanded row.
struct ModelRow: View {
    @ObservedObject var runtime: LocalAIRuntime
    let group: LocalModelGroup
    @State private var expanded = false
    @State private var confirmRemove = false

    private var state: LocalAIRuntime.GroupState { runtime.groups[group] ?? .init(selectedEntryID: "") }
    private var entry: LocalModelCatalogEntry? { runtime.selectedEntry(group) }
    private var installed: Bool { runtime.installedModel(group) != nil }
    private var busy: Bool {
        switch state.phase {
        case .downloading, .loading, .running, .canceling, .unloading: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded { details.padding(.horizontal, 14).padding(.bottom, 12) }
        }
        .confirmationDialog("Remove \(entry?.displayName ?? "model") from this Mac?", isPresented: $confirmRemove) {
            Button("Remove files", role: .destructive) {
                do { try runtime.remove(group) } catch { runtime.groups[group]?.lastError = error.localizedDescription }
            }
        } message: { Text("The downloaded files are deleted. You can download or import them again.") }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Text(group.title).font(.system(size: 13)).foregroundStyle(DS.Colors.textSecondary).frame(width: 74, alignment: .leading)
            modelMenu.frame(maxWidth: .infinity, alignment: .leading)
            sizeOrProgress.frame(width: 76, alignment: .trailing)
            LabPhaseBadge(phase: state.phase, progress: state.downloadProgress).frame(width: 96, alignment: .leading)
            Text(state.loadMilliseconds.map { LabFormat.milliseconds($0) } ?? "").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary).frame(width: 52, alignment: .trailing)
            primaryAction.frame(width: 92, alignment: .trailing)
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(DS.Colors.textTertiary)
                    .frame(width: 16, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickyPointerCursor()
            .accessibilityLabel(expanded ? "Hide \(group.title) details" : "Show \(group.title) details")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(runtime.entries(for: group)) { option in
                Button(option.displayName) { Task { await runtime.select(option.id, for: group) } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(entry?.displayName ?? "No model").font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .disabled(state.phase == .downloading || state.phase == .loading || runtime.entries(for: group).count < 2)
        .clickyPointerCursor()
    }

    @ViewBuilder private var sizeOrProgress: some View {
        if state.phase == .downloading, let progress = state.downloadProgress {
            ProgressView(value: progress).tint(ClickyChrome.ask).frame(width: 70)
        } else {
            Text(entry.map { LabFormat.size($0.totalBytes) } ?? "").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch state.phase {
        case .missing:
            Button("Download") { runtime.download(group) }.islandButton(.primary).disabled(entry == nil)
        case .downloading, .canceling:
            Button("Cancel") { runtime.cancelDownload(group) }.islandButton(.warning)
                .disabled(state.phase == .canceling || state.downloadProgress == nil)
        case .installed:
            Button("Load") { Task { try? await runtime.load(group) } }.islandButton(.primary).disabled(!runtime.workerAvailable)
        case .loading:
            Button("Cancel load") { Task { await runtime.unload(group) } }.islandButton(.warning)
        case .ready, .running, .unloading:
            Button("Unload") { Task { await runtime.unload(group) } }.islandButton(.secondary).disabled(state.phase == .unloading)
        case .failed:
            Button("Retry") { retry() }.islandButton(.secondary)
        }
    }

    private func retry() {
        if installed { Task { try? await runtime.load(group) } } else { runtime.download(group) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                HStack(alignment: .top, spacing: 12) {
                    fact("License", entry.license)
                    fact("Format", entry.quantization)
                    fact("Source", entry.repository)
                    fact("Revision", String(entry.revision.prefix(8)))
                }
            }
            if let error = state.lastError ?? failure {
                Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("Load").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                Picker("", selection: Binding(get: { runtime.residency[group].load }, set: { runtime.residency[group].load = $0 })) {
                    ForEach(LocalLoadPolicy.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                Text("Unload when idle").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                Picker("", selection: Binding(get: { runtime.residency[group].idleUnloadMinutes ?? 0 },
                                              set: { runtime.residency[group].idleUnloadMinutes = $0 == 0 ? nil : $0 })) {
                    Text("Never").tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden().frame(width: 100)
                Spacer(minLength: 8)
                Button("Verify") { Task { await runtime.verify(group) } }.islandButton(.secondary).disabled(!installed || busy)
                Button("Import folder…") { importFolder() }.islandButton(.secondary).disabled(installed || busy || entry == nil)
                Button("Remove") { confirmRemove = true }.islandButton(.quiet).disabled(!installed || runtime.isLoaded(group) || busy)
            }
            SettingsNote(footnote)
        }
        .padding(12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private var failure: String? { if case .failed(let message) = state.phase { return message }; return nil }

    private var footnote: String {
        var parts: [String] = []
        if runtime.isLoaded(group) { parts.append("Remove is available after Unload.") }
        if let notes = entry?.notes, !notes.isEmpty { parts.append(notes) }
        return parts.isEmpty ? "Models load only when you press Load or by the load policy above." : parts.joined(separator: " ")
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            Text(value).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
