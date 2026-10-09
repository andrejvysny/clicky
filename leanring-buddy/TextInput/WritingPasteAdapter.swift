import AppKit
import ApplicationServices
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Fallback for applications without a verified adapter (VS Code without the bridge, editors and apps other
/// than Chrome, third-party terminals): paste at the application's own cursor, exactly like the user's ⌘V.
/// Identity is the process, its front window and, with Accessibility, the focused element at binding time.
/// Write and snippets paste automatically after the usual gates (Return released, same app, window and focused
/// control, Stop not pressed); nothing can be read back, so outcomes are `acknowledged`, never `applied`.
@MainActor
final class WritingPasteAdapter {
    /// Third-party terminals: single printable lines only (a pasted newline could execute a command).
    static let terminalBundles: Set<String> = [
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
    ]
    /// How long the staged text stays on the clipboard before the user's clipboard returns. ⌘V is consumed while
    /// the target handles the key event, normally within milliseconds; an app stalled longer than this would
    /// paste the restored clipboard instead. Restoration happens only while Clicky still owns the pasteboard.
    static let consumptionDelay: UInt64 = 600_000_000

    private struct Binding { let element: AXUIElement? }
    private var bindings: [UUID: Binding] = [:]
    private var order: [UUID] = []
    private let clipboard = WritingClipboard.shared

    func owns(_ token: UUID) -> Bool { bindings[token] != nil }

    func capture(_ application: NSRunningApplication, kind preferred: WritingTargetKind? = nil) -> TextTargetSnapshot {
        let pid = application.processIdentifier
        let bundle = application.bundleIdentifier ?? ""
        let element = WritingAX.focusedElement(of: pid)
        let kind = preferred ?? (Self.terminalBundles.contains(bundle) ? .terminal : .textField)
        // The selection range when Accessibility exposes it (metadata only); otherwise unknown, shown as a caret.
        let selection = element.flatMap(WritingAX.selectedRange) ?? .caret(0)!
        let snapshot = TextTargetSnapshot(kind: kind, applicationName: application.localizedName ?? "App", bundleIdentifier: bundle,
                                          processIdentifier: pid, windowIdentifier: WindowSnapshotCapture.target(for: application)?.windowIdentifier,
                                          paneIdentity: nil, selection: selection, contentRevision: "",
                                          blockedReason: element.map(WritingAX.isSecure) == true ? .secureField : nil, pasteOnly: true)
        remember(snapshot.token, Binding(element: element))
        return snapshot
    }

    /// Same process and window, and the same focused control when Accessibility can tell.
    func live(_ bound: TextTargetSnapshot) -> TextTargetSnapshot? {
        guard let binding = bindings[bound.token], let application = NSRunningApplication(processIdentifier: bound.processIdentifier),
              !application.isTerminated else { return nil }
        let focused = WritingAX.focusedElement(of: bound.processIdentifier)
        let moved = binding.element.map { element in focused.map { !CFEqual($0, element) } ?? true } ?? false
        return TextTargetSnapshot(token: bound.token, kind: bound.kind, applicationName: bound.applicationName,
                                  bundleIdentifier: bound.bundleIdentifier, processIdentifier: bound.processIdentifier,
                                  windowIdentifier: WindowSnapshotCapture.target(for: application)?.windowIdentifier,
                                  paneIdentity: moved ? "focus-moved" : nil,
                                  selection: binding.element.flatMap(WritingAX.selectedRange) ?? .caret(0)!, contentRevision: "",
                                  blockedReason: focused.map(WritingAX.isSecure) == true ? .secureField : nil, pasteOnly: true)
    }

    /// The selected text for a Rewrite: Accessibility's `AXSelectedText` when the app exposes it, otherwise a
    /// ⌘C to that application with the user's clipboard put back. A known empty selection never copies (some
    /// editors copy the whole line when nothing is selected).
    func readSource(_ bound: TextTargetSnapshot) async throws -> ExactSource {
        guard let binding = bindings[bound.token] else { throw WritingContractError.sourceMismatch }
        if let element = binding.element {
            guard !WritingAX.isSecure(element) else { throw WritingContractError.sourceMismatch }
            if let text = WritingAX.value(element, kAXSelectedTextAttribute) as? String, !text.isEmpty {
                return try ExactSource(text: text, range: Self.range(bound, text))
            }
            if let range = WritingAX.selectedRange(element), range.isEmpty { throw WritingRequestError.noSelection }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == bound.processIdentifier,
              let text = await clipboard.copySelection({ WritingAX.postCopy(to: bound.processIdentifier) }), !text.isEmpty
        else { throw WritingRequestError.noSelection }
        return try ExactSource(text: text, range: Self.range(bound, text))
    }

    /// The bound selection when Accessibility reported a matching one; otherwise an opaque range of the
    /// copied length (the paste replaces whatever the app still has selected).
    private static func range(_ bound: TextTargetSnapshot, _ text: String) -> UTF16Range {
        if bound.selection.length == text.utf16.count { return bound.selection }
        return UTF16Range(location: 0, length: text.utf16.count)!
    }

    func focusRestored(_ bound: TextTargetSnapshot) -> Bool {
        guard let binding = bindings[bound.token],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == bound.processIdentifier else { return false }
        guard let element = binding.element else { return true }
        return WritingAX.focusedElement(of: bound.processIdentifier).map { CFEqual($0, element) } ?? false
    }

    func apply(_ bound: TextTargetSnapshot, text: String, authorized: WritingAuthorization) async -> WritingApplyOutcome {
        if bound.kind == .terminal, TerminalPayload.classify(text) != .singleLine { return .notApplied(.rejectedByTarget) }
        // No suspension from here to the keystroke: authority, focus, clipboard snapshot and staging are one step.
        guard authorized() else { return .notApplied(.canceled) }
        guard focusRestored(bound) else { return .notApplied(.focusChanged) }
        if let element = bindings[bound.token]?.element, WritingAX.isSecure(element) { return .notApplied(.targetUnavailable) }
        guard let snapshot = clipboard.snapshot() else { return .notApplied(.clipboardUnavailable) }
        guard let staged = clipboard.stage(text, preserving: snapshot) else { return .notApplied(.clipboardUnavailable) }
        WritingAX.postPaste(to: bound.processIdentifier)
        try? await Task.sleep(nanoseconds: Self.consumptionDelay)
        clipboard.restore(staged)
        return .acknowledged(WritingAppliedEdit(targetToken: bound.token, insertedRange: .caret(0)!.replaced(by: text),
                                                insertedText: text, replacedText: "", postRevision: ""))
    }

    private func remember(_ token: UUID, _ binding: Binding) {
        bindings[token] = binding; order.append(token)
        while order.count > 8 { bindings.removeValue(forKey: order.removeFirst()) }
    }
}
