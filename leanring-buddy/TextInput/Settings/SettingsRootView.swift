import SwiftUI

/// Sidebar on the left, the selected pane on the right.
struct SettingsRootView: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            if let pane = SettingsCatalog.descriptor(context.selection) {
                pane.makeView().id(pane.id)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("clickySettings")
    }
}

struct SettingsSidebar: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Triangle().fill(ClickyChrome.ask).frame(width: 14, height: 12).rotationEffect(.degrees(35))
                Text("Clicky").font(.system(size: 13, weight: .semibold))
            }
            .padding(.leading, 18).padding(.top, 46).padding(.bottom, 18)
            ForEach(SettingsSidebarSection.allCases) { section in
                Text(section.title).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Colors.textTertiary)
                    .padding(.leading, 20).padding(.bottom, 4)
                ForEach(SettingsCatalog.panes.filter { $0.section == section }) { pane in item(pane) }
                Spacer().frame(height: 18)
            }
            Spacer(minLength: 0)
            if let runtime = context.runtime { SidebarStatusFooter(runtime: runtime) }
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(SettingsColors.sidebar)
    }

    private func item(_ pane: SettingsPaneDescriptor) -> some View {
        let selected = context.selection == pane.id
        return Button { context.selection = pane.id } label: {
            Text(pane.title).font(.system(size: 13))
                .foregroundStyle(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickyPointerCursor()
        .padding(.horizontal, 10)
        .accessibilityIdentifier("settingsPane-\(pane.id.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Worker status and memory pressure on every page. Values come from the last measurement only;
/// nothing is polled in the background.
private struct SidebarStatusFooter: View {
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        let memory = runtime.memory
        VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.bottom, 6)
            line(color: workerColor(.inference), title: "Inference worker",
                 value: workerValue(.inference))
            line(color: workerColor(.speech), title: "Speech worker", value: workerValue(.speech))
            let pressured = memory.pressure != .normal
            line(color: pressured ? DS.Colors.warningText : DS.Colors.success,
                 title: pressured ? "Memory pressure" : "Memory normal",
                 value: memory.measuredAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–",
                 titleColor: pressured ? DS.Colors.warningText : DS.Colors.textSecondary)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
    }

    private func line(color: Color, title: String, value: String, titleColor: Color = DS.Colors.textSecondary) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11)).foregroundStyle(titleColor)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private func workerValue(_ role: LocalWorkerRole) -> String {
        switch runtime.workers[role] {
        case .ready: return LabFormat.megabytes(runtime.memory.workers[role]?.physicalFootprintBytes)
        case .starting: return "starting"
        case .failed: return "failed"
        default: return "off"
        }
    }

    private func workerColor(_ role: LocalWorkerRole) -> Color {
        switch runtime.workers[role] {
        case .ready: return DS.Colors.success
        case .starting: return DS.Colors.info
        case .failed: return DS.Colors.warningText
        default: return DS.Colors.textTertiary
        }
    }
}
