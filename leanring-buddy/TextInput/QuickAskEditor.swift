import AppKit
import SwiftUI

struct QuickAskEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String = ""
    var compact: Bool = false
    /// Command+Shift+A; the cursor-following ghost pill cannot be reached with the mouse.
    var onAttach: (() -> Void)? = nil
    /// Command+Shift+S toggles including the whole screen.
    var onIncludeScreen: (() -> Void)? = nil
    /// Option+Shift+E cycles per-prompt effort.
    var onCycleEffort: (() -> Void)? = nil
    /// Long multi-line pastes collapse into a chip instead of the editor.
    var onPasteSnippet: ((String) -> Void)? = nil
    /// Backspace in an empty editor removes the newest quote/chip.
    var onDeleteEmpty: (() -> Void)? = nil
    /// Command+N starts a new conversation.
    var onNewConversation: (() -> Void)? = nil
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // Legacy (always-visible) scrollers draw a track inside the compact pill; show only while scrolling.
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        let editor = PromptTextView()
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
        editor.onAttach = onAttach
        editor.onIncludeScreen = onIncludeScreen
        editor.onCycleEffort = onCycleEffort
        editor.onPasteSnippet = onPasteSnippet
        editor.onDeleteEmpty = onDeleteEmpty
        editor.onNewConversation = onNewConversation
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: compact ? 330 : 380, height: CGFloat.greatestFiniteMagnitude)
        editor.font = .systemFont(ofSize: compact ? 13 : 14)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.textContainerInset = compact ? NSSize(width: 2, height: 3) : NSSize(width: 8, height: 8)
        editor.string = text
        editor.placeholder = placeholder
        editor.setAccessibilityPlaceholderValue(placeholder)
        editor.setAccessibilityIdentifier("quickAskEditor")
        scrollView.documentView = editor
        DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? PromptTextView else { return }
        editor.isEditable = context.environment.isEnabled
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
        editor.onAttach = onAttach
        editor.onIncludeScreen = onIncludeScreen
        editor.onCycleEffort = onCycleEffort
        editor.onPasteSnippet = onPasteSnippet
        editor.onDeleteEmpty = onDeleteEmpty
        editor.onNewConversation = onNewConversation
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuickAskEditor
        init(_ parent: QuickAskEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            if let layout = editor.layoutManager, let container = editor.textContainer {
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container).height
                if parent.compact {
                    parent.height = min(120, max(20, used + 2 * editor.textContainerInset.height))
                } else {
                    parent.height = min(180, max(88, used + 20))
                }
            }
            editor.needsDisplay = true
        }
    }
}

private final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAttach: (() -> Void)?
    var onIncludeScreen: (() -> Void)?
    var onCycleEffort: (() -> Void)?
    var onPasteSnippet: ((String) -> Void)?
    var onDeleteEmpty: (() -> Void)?
    var onNewConversation: (() -> Void)?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(white: 1, alpha: 0.45)
        ]
        placeholder.draw(at: NSPoint(x: origin.x + padding, y: origin.y), withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if [UInt16(36), UInt16(76)].contains(event.keyCode), !event.modifierFlags.contains(.shift) { onSubmit?(); return }
            if event.keyCode == 53 { onCancel?(); return }
            if let onAttach, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "a" { onAttach(); return }
            if let onIncludeScreen, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "s" { onIncludeScreen(); return }
            // Physical E key so the dead-key character Option+E would insert never reaches the text.
            if let onCycleEffort, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option, .shift],
               event.keyCode == 14 { onCycleEffort(); return }
            if let onNewConversation, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "n" { onNewConversation(); return }
            if let onDeleteEmpty, event.keyCode == 51, string.isEmpty,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { onDeleteEmpty(); return }
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let onPasteSnippet, !hasMarkedText(), let text = NSPasteboard.general.string(forType: .string),
           PastedSnippet.shouldCollapse(text) { onPasteSnippet(text); return }
        super.paste(sender)
    }
}
