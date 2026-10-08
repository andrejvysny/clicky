import AppKit
import SwiftUI

/// Quick Ask as the expanded island (design M9): one input row under the notch, attachments inline as
/// icons, effort pips in the right wing. An existing reply is pushed below the input, unchanged.
struct IslandAskView: View {
    @ObservedObject var controller: AskController
    let metrics: IslandMetrics
    let onCancel: () -> Void
    let onLayoutChanged: () -> Void
    @State private var editorHeight: CGFloat = 22

    private var placeholder: String {
        if controller.selection != nil { return "Ask about the selection…" }
        if controller.provider == .preview { return "Ask Clicky (preview, no AI)…" }
        // A live session means this is a follow-up in the same conversation.
        if controller.session != nil && !controller.response.isEmpty { return "Follow up…" }
        return controller.provider == .codex ? "Ask Codex…" : "Ask Claude…"
    }

    private var canAttach: Bool {
        controller.captureTargetName != nil && !controller.isBusy && controller.attachment == nil && !controller.isCapturing
    }

    var body: some View {
        IslandShell(metrics: metrics, width: IslandLayout.askWidth, expanded: true) {
            IslandGlyph.ask()
        } right: {
            effortPips
        } content: {
            IslandBody {
                if controller.isBusy { busyRow } else { inputRow }
                if let error = controller.attachmentError ?? controller.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.presentationHasSubmission {
                    Text(controller.status).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(2)
                }
                if !controller.response.isEmpty {
                    IslandReplyText(text: controller.response, lineLimit: 8)
                        .accessibilityIdentifier(controller.presentationHasSubmission ? "quickAskResponse" : "quickAskLastReply")
                }
            }
        }
        .background(GeometryReader { Color.clear.preference(key: AskHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(AskHeightKey.self) { _ in onLayoutChanged() }
        .onChange(of: editorHeight) { _ in onLayoutChanged() }
    }

    private var effortPips: some View {
        Button { controller.cycleEffort() } label: {
            EffortPips(effort: controller.displayedEffort, size: 3).padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.effortAdjustable)
        .help(controller.effortAdjustable ? "Effort \(controller.displayedEffort.displayName) · ⌥⇧E · resets after sending"
              : "Effort \(controller.displayedEffort.displayName) · fixed for this task")
        .accessibilityLabel("Effort \(controller.displayedEffort.displayName)")
        .accessibilityIdentifier("quickAskEffort")
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 8) {
            attachmentIcons
            QuickAskEditor(text: $controller.draft, height: $editorHeight, placeholder: placeholder, compact: true,
                           onAttach: canAttach ? { controller.attachWindowSnapshot() } : nil,
                           onIncludeScreen: controller.screenInclusion.isAvailable ? { controller.toggleScreenAttachment() } : nil,
                           onCycleEffort: { controller.cycleEffort() },
                           onPasteSnippet: { controller.addSnippet($0) },
                           onDeleteEmpty: deleteNewestContext,
                           onNewConversation: { controller.newConversation() },
                           onSubmit: { _ = controller.submit() }, onCancel: onCancel)
                .frame(height: editorHeight)
                .id(controller.editorGeneration)
            Button { _ = controller.submit() } label: {
                ZStack {
                    Circle().fill(controller.canSubmit ? ClickyChrome.ask : ClickyChrome.ask.opacity(0.35)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black)
                }
            }
            .buttonStyle(.plain).disabled(!controller.canSubmit)
            .help("Send (Enter) · ⌘N new conversation")
            .accessibilityLabel("Send").accessibilityIdentifier("quickAskSend").clickyPointerCursor()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Icons only; hovering spells out what each one is. ⌫ in an empty prompt removes the newest.
    @ViewBuilder private var attachmentIcons: some View {
        if let selection = controller.selection {
            IslandGlyph.selection
                .help("Selection · \(selection.applicationName) · \(selection.lineCount) lines\n\(selection.text.prefix(200))")
                .accessibilityIdentifier("quickAskSelection")
        }
        ForEach(controller.snippets) { snippet in
            Text("{ }").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(DS.Colors.blue400)
                .help("Pasted text · \(snippet.lineCount) lines · ⌫ removes")
                .accessibilityIdentifier("quickAskSnippet")
        }
        if controller.isCapturing {
            SpinnerRing(size: 9)
        } else if let image = controller.attachment {
            IslandGlyph.window(attached: true)
                .help("Screenshot attached · \(image.displayName)")
                .accessibilityIdentifier("quickAskAttachment")
        } else if let name = controller.captureTargetName, controller.screenInclusion.isAvailable {
            IslandGlyph.window(attached: false)
                .help("Clicky may look at the \(name) window if your question needs it · ⌘⇧A attaches now")
        }
    }

    private var busyRow: some View {
        HStack(spacing: 8) {
            SpinnerRing(size: 10)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = controller.busySince.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
                Text("Working · \(seconds) s").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 4)
            Button { controller.stopReply() } label: {
                ZStack {
                    Circle().fill(DS.Colors.textPrimary).frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 1).fill(Color.black).frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain).help("Stop").accessibilityLabel("Stop reply").clickyPointerCursor()
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func deleteNewestContext() {
        if let last = controller.snippets.last { controller.removeSnippet(last.id) }
        else if controller.selection != nil { controller.removeSelection() }
        else if controller.attachment != nil { controller.removeAttachment() }
    }
}

private struct AskHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
