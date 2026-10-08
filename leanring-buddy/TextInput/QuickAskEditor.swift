import AppKit
import SwiftUI

struct QuickAskEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let editor = PromptTextView()
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
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
        editor.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
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
                parent.height = min(180, max(88, layout.usedRect(for: container).height + 20))
            }
        }
    }
}

private final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if [UInt16(36), UInt16(76)].contains(event.keyCode), !event.modifierFlags.contains(.shift) { onSubmit?(); return }
            if event.keyCode == 53 { onCancel?(); return }
        }
        super.keyDown(with: event)
    }
}
