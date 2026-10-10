import AppKit
import SwiftUI

/// Plain NSTextView: no smart quotes, dashes, replacement or spelling correction, and the text is never trimmed.
struct WritingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var identifier: String
    var monospaced = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(DS.Colors.surface1)
        scrollView.borderType = .noBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.string = text
        editor.setAccessibilityIdentifier(identifier)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingTextEditor
        init(_ parent: WritingTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
