import SwiftUI

/// Settings entry for on-device AI: the three model groups at a glance and the button that opens the Lab.
/// Reading this section loads nothing and starts no worker.
struct LocalAISettingsSection: View {
    var body: some View {
        if let runtime = LocalAIRuntime.shared { Content(runtime: runtime) }
    }

    private struct Content: View {
        @ObservedObject var runtime: LocalAIRuntime

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LocalModelGroup.allCases, id: \.rawValue) { group in
                    HStack(spacing: 8) {
                        Text(group.title).font(.system(size: 12))
                        Text(runtime.selectedEntry(group)?.displayName ?? "No model")
                            .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
                        Spacer(minLength: 4)
                        LabPhaseBadge(phase: runtime.groups[group]?.phase ?? .missing, progress: runtime.groups[group]?.downloadProgress)
                    }
                }
                Button("Local AI Lab…") { LocalAILabWindow.shared.show(runtime: runtime) }.islandButton(.secondary)
                Text("On-device models run only when you load one. Nothing downloads, records or loads on its own.")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
