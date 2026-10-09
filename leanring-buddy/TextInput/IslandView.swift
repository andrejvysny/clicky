import AppKit
import SwiftUI

/// Renders the island's current mode. Glyphs, not words, in compact states.
struct IslandView: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var ask: AskController
    @ObservedObject var guide: VisualGuideController

    init(controller: IslandController) {
        self.controller = controller; ask = controller.ask; guide = controller.ask.guide
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onPreferenceChange(IslandHeightKey.self) { _ in controller.layoutPanel() }
            .background(GeometryReader { Color.clear.preference(key: IslandHeightKey.self, value: $0.size.height) })
    }

    @ViewBuilder private var content: some View {
        let metrics = controller.metrics
        switch controller.mode {
        case .hidden:
            EmptyView()
        case .guide:
            IslandShell(metrics: metrics, width: controller.width) {
                Text("\(progress.count + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.blue400)
            } right: {
                IslandProgressBar(completed: progress)
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.toggleGuide() }
            .help("Guide controls")
        case .guideAttention:
            let uncertain = guide.task?.phase == .uncertain
            IslandShell(metrics: metrics, width: controller.width, expanded: true,
                        ring: uncertain ? DS.Colors.warning : nil) {
                IslandGlyph.ask()
            } right: {
            } content: {
                attentionBody
            }
        }
    }

    private var hasStep: Bool { guide.task?.step != nil || guide.demo != nil }

    /// A step card replaces the headline; blocked states keep their question and actions beneath it.
    @ViewBuilder private var attentionBody: some View {
        let onCollapse: (() -> Void)? = controller.isBlocked || guide.demo != nil ? nil : { controller.toggleGuide() }
        IslandBody {
            if hasStep { IslandStepCard(guide: guide) }
            IslandGuideControls(controller: guide, onCollapse: onCollapse, showsHeadline: !hasStep)
        }
    }

    private var progress: [Bool] {
        if let demo = guide.demo { return Array(repeating: false, count: demo.index) }
        return (guide.task?.milestones ?? []).map { $0.completion == .verified }
    }
}

/// Reply text: markdown and selectable; long replies are clipped here and readable in full from the menu.
struct IslandReplyText: View {
    let text: String
    var lineLimit = 12

    var body: some View {
        Text(ReplyMarkdown.attributed(text))
            .font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

private struct IslandHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
