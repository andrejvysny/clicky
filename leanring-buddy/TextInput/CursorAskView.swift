import AppKit
import SwiftUI

/// Quick Ask beside the pointer, in the island's black style: one input row with attachments as icons
/// and effort dots by the send button. An existing reply is pushed below the input, unchanged.
struct CursorAskView: View {
    @ObservedObject var controller: AskController
    @ObservedObject private var writing: WritingCoordinator
    let onCancel: () -> Void
    let onLayoutChanged: () -> Void
    @State private var editorHeight: CGFloat = 22
    @State private var picker = SlashPickerState()
    @State private var caret = 0
    @State private var composing = false

    init(controller: AskController, onCancel: @escaping () -> Void, onLayoutChanged: @escaping () -> Void) {
        self.controller = controller; _writing = ObservedObject(wrappedValue: controller.writing)
        self.onCancel = onCancel; self.onLayoutChanged = onLayoutChanged
    }

    private var pickerQuery: String? { SlashPickerState.query(draft: controller.draft, caretUTF16: caret, hasMarkedText: composing) }
    private var suggestions: [SlashCommand] {
        guard let query = pickerQuery else { return [] }
        return SlashCommandRegistry(definitions: controller.writingDefinitions.definitions,
                                    hasSelection: writing.target?.mayHaveSelection ?? false).suggestions(for: query)
    }
    private var pickerVisible: Bool { picker.isVisible(query: pickerQuery, count: suggestions.count) }
    private var emptyDraft: Bool { controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { controller.canSubmit || (emptyDraft && writing.canApply) }

    private var placeholder: String {
        if writing.canRefine, writing.proposal == nil { return "Answer the question…" }
        if writing.canRefine { return "Refine the draft… (↩ alone applies)" }
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
        // Ghost layout: no surrounding card. The input pill and the answer float as separate translucent pieces.
        VStack(alignment: .leading, spacing: 6) {
            inputRow
            voiceRow
            if pickerVisible {
                SlashPickerView(suggestions: suggestions, highlighted: picker.highlighted) { command in
                    controller.draft = "/" + command.alias + " "
                }
            }
            if writing.phase != .idle || writing.hasProposal {
                WritingProposalView(writing: writing)
            }
            if hasMessage {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = controller.attachmentError ?? controller.errorMessage {
                        Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsStatus {
                        Text(controller.status).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(2)
                    }
                    if !controller.response.isEmpty {
                        IslandReplyText(text: controller.response, lineLimit: 8)
                            .accessibilityIdentifier(controller.presentationHasSubmission ? "quickAskResponse" : "quickAskLastReply")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ghostPill()
            }
        }
        .frame(width: IslandLayout.cursorAskWidth, alignment: .leading)
        .environment(\.colorScheme, .dark)
        .background(GeometryReader { Color.clear.preference(key: AskHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(AskHeightKey.self) { _ in onLayoutChanged() }
        .onChange(of: editorHeight) { _ in onLayoutChanged() }
        .onChange(of: pickerQuery) { _, query in picker.update(query: query, count: suggestions.count) }
    }

    private var showsStatus: Bool {
        controller.presentationHasSubmission && !controller.isBusy && controller.status != "Ready"
    }

    private var hasMessage: Bool {
        controller.attachmentError != nil || controller.errorMessage != nil || showsStatus || !controller.response.isEmpty
    }

    /// One line for a voice session started here, or the note about voice text now in the draft. Never any transcript.
    @ViewBuilder private var voiceRow: some View {
        if let status = controller.voiceStatus {
            HStack(spacing: 8) {
                if status.canStop { StatusDot(color: DS.Colors.destructiveText) } else { SpinnerRing(size: 9) }
                Text(status.line).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                if status.canStop { Button("Stop") { controller.onVoiceStop?() }.islandButton(.secondary).accessibilityIdentifier("voiceStop") }
                Button("Cancel") { controller.onVoiceCancel?() }.islandButton(.quiet).accessibilityIdentifier("voiceCancel")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ghostPill()
        } else if let note = controller.visibleVoiceNote {
            HStack(spacing: 8) {
                Text(note).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
                Spacer(minLength: 4)
                if controller.canUseOriginalVoiceTranscript {
                    Button("Use original") { controller.useOriginalVoiceTranscript() }.islandButton(.secondary)
                        .accessibilityIdentifier("voiceUseOriginal")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ghostPill()
        }
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
                           onPickerKey: handlePickerKey,
                           onCaretChange: { caret = $0; composing = $1 },
                           onSubmit: submitOrApply, onCancel: onCancel)
                .frame(height: editorHeight)
                .id(controller.editorGeneration)
            writingChips
            effortPips
            Button { submitOrApply() } label: {
                ZStack {
                    Circle().fill(canSend ? ClickyChrome.ask : ClickyChrome.ask.opacity(0.35)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black)
                }
            }
            .buttonStyle(.plain).disabled(!canSend)
            .help("Send (Enter) · ⌘N new conversation")
            .accessibilityLabel("Send").accessibilityIdentifier("quickAskSend").clickyPointerCursor()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .ghostPill()
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

    /// Enter in an empty input applies a reviewed draft; otherwise it submits the prompt.
    private func submitOrApply() {
        if emptyDraft, writing.canApply { writing.apply() } else { _ = controller.submit() }
    }

    private func handlePickerKey(_ key: SlashPickerState.PickerKey) -> Bool {
        var state = picker
        let decision = state.handle(key, query: pickerQuery, suggestions: suggestions)
        picker = state
        switch decision {
        case .complete(let draft): controller.draft = draft; return true
        case .dismiss, .moveHighlight: return true
        case .submit, .passThrough: return false
        }
    }

    /// Per-request context opt-in and the explicit VS Code editor/terminal choice.
    @ViewBuilder private var writingChips: some View {
        if let target = writing.target, !writing.isBusy {
            if target.hasSelection, target.kind != .terminal {
                Button { writing.includeSurrounding.toggle() } label: {
                    Image(systemName: "text.append").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(writing.includeSurrounding ? ClickyChrome.ask : DS.Colors.textTertiary)
                }
                .buttonStyle(.plain).clickyPointerCursor()
                .help(writing.includeSurrounding ? "Next request includes up to 1,000 characters around the selection · click to turn off"
                      : "Selection only · click to also send up to 1,000 characters around it with the next request")
                .accessibilityLabel("Include surrounding text").accessibilityIdentifier("quickAskSurrounding")
            }
            if writing.alternateTarget != nil {
                Button { writing.switchDestination() } label: {
                    Image(systemName: target.kind == .terminal ? "terminal" : "doc.plaintext").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain).clickyPointerCursor()
                .help(target.kind == .terminal ? "Destination: VS Code terminal · click for the editor" : "Destination: VS Code editor · click for the terminal")
                .accessibilityLabel("Switch VS Code destination").accessibilityIdentifier("quickAskDestination")
            }
        }
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
