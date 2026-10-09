import SwiftUI

/// The walkthrough step shown in the island: progress, instruction, status and shortcut hints.
struct IslandStepCard: View {
    @ObservedObject var guide: VisualGuideController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(counter).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                segments
            }
            Text(title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = guide.task?.step?.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusRow
            Divider().overlay(Color.white.opacity(0.1)).padding(.top, 2)
            Text("⌥⇧← back · ⌥⇧→ skip · ⌥⇧R retry · ⌥⇧⌫ end")
                .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("islandStepCard")
    }

    private var uncertain: Bool { guide.task?.phase == .uncertain }
    private var accent: Color { uncertain ? DS.Colors.warning : DS.Colors.blue400 }

    private var completed: [Bool] {
        if let demo = guide.demo { return Array(repeating: false, count: demo.index) }
        return (guide.task?.milestones ?? []).map { $0.completion == .verified }
    }

    private var current: Int { completed.count + 1 }

    /// Only the deterministic demo has a known length; a model's route is advisory, so live guides show Step N.
    private var total: Int? {
        guard guide.demo != nil else { return nil }
        return max(GuidePreviewFixture.instructions.count, current)
    }

    private var counter: String {
        if let index = guide.task?.historyIndex { return "Earlier · Step \(index + 1)" }
        return total.map { "\(current)/\($0)" } ?? "Step \(current)"
    }

    private var title: String {
        guide.task?.historyItem?.instruction ?? guide.demo?.instruction ?? guide.task?.step?.text ?? guide.task?.goal ?? ""
    }

    /// Provenance of a past instruction; manual and already-satisfied steps never read as verified.
    private var historyProvenance: String? {
        switch guide.task?.historyItem?.completion {
        case .verified?: return "Past guidance · verified"
        case .manuallyAcknowledged?: return "Past guidance · marked done manually, not verified"
        case .satisfied?: return "Past guidance · already satisfied when checked"
        case nil: return nil
        }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(Array(completed.enumerated()), id: \.offset) { _, verified in
                if verified { Capsule().fill(DS.Colors.success) }
                else { Capsule().strokeBorder(DS.Colors.success, lineWidth: 1) }
            }
            Capsule().fill(accent)
            ForEach(0..<max(0, (total ?? current) - current), id: \.self) { _ in Capsule().fill(DS.Colors.surface4) }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 6) {
            if let historyProvenance {
                Text(historyProvenance).foregroundStyle(DS.Colors.textSecondary)
            } else if guide.task?.phase == .waiting, !guide.isBusy {
                StatusDot(color: DS.Colors.blue400, glow: true)
                Text(waitingText).foregroundStyle(DS.Colors.textSecondary)
            } else if guide.isBusy || guide.task?.phase == .verifying {
                SpinnerRing(size: 8)
                Text(guide.status).foregroundStyle(DS.Colors.textSecondary)
            } else if uncertain {
                StatusDot(color: DS.Colors.warning)
                Text(guide.status).foregroundStyle(DS.Colors.textSecondary)
            } else {
                Text(guide.status).foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .font(.system(size: 11))
    }

    private var waitingText: String {
        switch guide.task?.step?.action?.kind {
        case .click: return "Waiting for your click"
        case .right_click: return "Waiting for your right-click"
        case .double_click: return "Waiting for your double-click"
        default: return "Waiting for your key"
        }
    }
}
