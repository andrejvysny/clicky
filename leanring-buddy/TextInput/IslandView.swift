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
        case .working:
            IslandShell(metrics: metrics, width: controller.width) {
                SpinnerRing(size: 11)
            } right: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = ask.busySince.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                    // Elapsed time appears only after 10 s.
                    if seconds >= 10 {
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textTertiary)
                    }
                }
            }
            .onTapGesture { ask.stopReply() }
            .help("Working · click to stop")
        case .reply:
            IslandShell(metrics: metrics, width: controller.width, expanded: true) {
                IslandGlyph.ask()
            } right: {
                Text("⌥⇧C copy").foregroundStyle(DS.Colors.textTertiary)
            } content: {
                IslandBody { IslandReplyText(text: ask.response) }
            }
            .onTapGesture { controller.tuckReply() }
            .accessibilityIdentifier("islandReply")
        case .replyTucked:
            IslandShell(metrics: metrics, width: controller.width) {
                EmptyView()
            } right: {
                IslandGlyph.dot(ClickyChrome.ask)
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.toggleReply() }
            .help("Show the last reply")
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
                        ring: uncertain || guide.needsSharingApproval ? DS.Colors.warning : nil) {
                if guide.demo != nil || guide.task?.step != nil {
                    Text("\(progress.count + 1)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(uncertain ? DS.Colors.warning : DS.Colors.blue400)
                } else { IslandGlyph.ask() }
            } right: {
                if guide.task?.step != nil { IslandProgressBar(completed: progress, current: uncertain ? DS.Colors.warning : ClickyChrome.ask) }
            } content: {
                IslandBody { IslandGuideControls(controller: guide, onCollapse: controller.guideExpanded ? { controller.toggleGuide() } : nil) }
            }
        case .displayApproval:
            IslandShell(metrics: metrics, width: controller.width, expanded: true, ring: DS.Colors.warning) {
                IslandGlyph.ask()
            } right: {
                IslandGlyph.window(attached: false)
            } content: {
                IslandBody {
                    Text("No window is focused. Share this display for the rest of this session?")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Share display") { guide.approveDisplay() }.islandButton(.warning)
                        Button("Text only") { guide.declineDisplay() }.islandButton(.secondary)
                    }
                }
            }
        case .error:
            IslandShell(metrics: metrics, width: controller.width, expanded: controller.errorExpanded) {
                IslandGlyph.dot(DS.Colors.destructiveText)
            } right: {
                Text(shortError).foregroundStyle(DS.Colors.destructiveText).lineLimit(1)
            } content: {
                if controller.errorExpanded, let message = ask.errorMessage {
                    IslandBody {
                        Text(message).font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if guide.task != nil { Button("Retry") { guide.retry() }.islandButton(.primary) }
                            Button("Dismiss") { ask.dismissError() }.islandButton(.secondary)
                        }
                    }
                }
            }
            .onTapGesture { controller.toggleError() }
            .help(ask.errorMessage ?? "")
        }
    }

    private var progress: [Bool] {
        if let demo = guide.demo { return Array(repeating: false, count: demo.index) }
        return (guide.task?.milestones ?? []).map { $0.completion == .verified }
    }

    /// A few words for the wing; the full reason is one click away.
    private var shortError: String {
        let message = (ask.errorMessage ?? "").lowercased()
        if message.contains("sign in") || message.contains("signed in") { return "Not signed in" }
        if message.contains("executable") || message.contains("version") { return "Not set up" }
        if message.contains("window") || message.contains("target") { return "Lost window" }
        return "Failed"
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
