import SwiftUI

/// On-device models: a memory strip in plain words, then one compact row per model.
/// Reading this pane loads nothing and starts no worker; numbers change only on Refresh or after a run.
struct ModelsPane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        if let runtime = context.runtime {
            Content(runtime: runtime)
        } else {
            SettingsPage(title: "Models") { SettingsNote("Local AI is not available in this build.") }
        }
    }

    private struct Content: View {
        @ObservedObject var runtime: LocalAIRuntime

        var body: some View {
            SettingsPage(title: "Models", subtitle: "On-device models run only when loaded. Nothing downloads or loads on its own.") {
                HStack(spacing: 6) {
                    Button("Refresh") { Task { await runtime.refreshMemory() } }.islandButton(.secondary)
                    Button("Clear caches") { Task { await runtime.clearCaches(); await runtime.refreshMemory() } }.islandButton(.quiet)
                }
            } content: {
                MemoryStrip(runtime: runtime)
                if !runtime.workerAvailable {
                    SettingsNote("The local worker is not bundled with this build, so models can be downloaded but not loaded. Debug builds can point CLICKY_LOCAL_WORKER at a worker executable.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    SettingsGroup("Installed") {
                        ForEach(Array(LocalModelGroup.allCases.enumerated()), id: \.element.rawValue) { index, group in
                            if index > 0 { SettingsDivider() }
                            ModelRow(runtime: runtime, group: group)
                        }
                    }
                    SettingsNote(runtime.memory.measuredAt.map { "Measured \($0.formatted(date: .omitted, time: .shortened)). Click Refresh to measure again." }
                                 ?? "Not measured yet. Click Refresh; workers report only their own memory.")
                        .padding(.leading, 4)
                }
                SettingsGroup("Resource protection") {
                    SettingsRow(title: "Protect foreground apps", subtitle: "Lowers CPU priority only. GPU sharing is not guaranteed.") {
                        SettingsSwitch(isOn: $runtime.protectForeground, label: "Protect foreground apps")
                    }
                }
            }
        }
    }
}

private struct MemoryStrip: View {
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        let memory = runtime.memory
        let inference = memory.workers[.inference]
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                cell("Inference worker", LabFormat.megabytes(inference?.physicalFootprintBytes))
                cell("Speech worker", LabFormat.megabytes(memory.workers[.speech]?.physicalFootprintBytes))
                cell("GPU now / peak", "\(LabFormat.megabytes(inference?.mlxActiveBytes)) / \(LabFormat.megabytes(inference?.mlxPeakBytes))")
                cell("Memory pressure", memory.pressure.rawValue.capitalized,
                     color: memory.pressure == .normal ? DS.Colors.textPrimary : DS.Colors.warningText)
                cell("Thermal", Self.thermal(memory.thermal).capitalized,
                     color: memory.thermal == .nominal || memory.thermal == .fair ? DS.Colors.textPrimary : DS.Colors.warningText)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func cell(_ title: String, _ value: String, color: Color = DS.Colors.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
