import AppKit
import ApplicationServices
#if canImport(ClickyCore)
import ClickyCore
#endif

/// macOS Terminal: insert-only at a ready shell prompt. Readiness and pane identity come from Terminal's
/// scripting properties (window id, tab tty, busy, foreground process) — read-only; never `do script`.
/// Delivery is a controlled paste of one printable line; Clicky never sends Return.
@MainActor
final class WritingTerminalAdapter {
    static let bundleIdentifier = "com.apple.Terminal"
    /// Automatic insertion is limited to the shell with native evidence (Terminal + zsh, see MAC_VALIDATION).
    /// Other shells keep the Copy path until they are validated.
    static let shells: Set<String> = ["zsh"]
    private var elements: [UUID: AXUIElement] = [:]
    private let clipboard = WritingClipboard.shared

    struct PaneState: Equatable {
        let windowIdentifier: UInt32
        let tty: String
        let busy: Bool
        let foreground: String
        var ready: Bool {
            let name = foreground.hasPrefix("-") ? String(foreground.dropFirst()) : foreground
            return !busy && WritingTerminalAdapter.shells.contains((name as NSString).lastPathComponent)
        }
    }

    enum StateError: Error { case automationDenied, unavailable }

    /// Reads the front window's selected tab. Runs osascript off the main thread with a hard timeout.
    nonisolated static func paneState() async throws -> PaneState {
        let script = """
        set sep to character id 9
        tell application "Terminal"
            set w to front window
            set t to selected tab of w
            set p to processes of t
            return (id of w as text) & sep & (tty of t) & sep & (busy of t as text) & sep & (last item of p)
        end tell
        """
        return try await Task.detached {
            let process = Process(); let output = Pipe(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate(); throw StateError.unavailable }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failure = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if failure.contains("-1743") { throw StateError.automationDenied }
            let fields = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            guard process.terminationStatus == 0, fields.count == 4, let window = UInt32(fields[0]) else { throw StateError.unavailable }
            return PaneState(windowIdentifier: window, tty: fields[1], busy: fields[2] == "true", foreground: fields[3])
        }.value
    }

    func capture(_ application: NSRunningApplication) async -> TextTargetSnapshot? {
        let pid = application.processIdentifier
        let element = WritingAX.focusedElement(of: pid)
        let state: PaneState?
        var blocked: WritingBlockReason?
        do { state = try await Self.paneState() }
        catch StateError.automationDenied { state = nil; blocked = .automationDenied }
        catch { state = nil; blocked = .terminalNotReady }
        if let state, !state.ready { blocked = .terminalNotReady }
        if element == nil, blocked == nil { blocked = .terminalNotReady }
        let snapshot = TextTargetSnapshot(kind: .terminal, applicationName: application.localizedName ?? "Terminal",
                                          bundleIdentifier: Self.bundleIdentifier, processIdentifier: pid,
                                          windowIdentifier: state?.windowIdentifier, paneIdentity: state?.tty,
                                          selection: element.flatMap(WritingAX.selectedRange) ?? .caret(0)!,
                                          contentRevision: element.flatMap(WritingAX.characterCount).map(String.init) ?? "",
                                          blockedReason: blocked)
        if let element { remember(snapshot.token, element) }
        return snapshot
    }

    func live(_ bound: TextTargetSnapshot) async -> TextTargetSnapshot? {
        guard let element = elements[bound.token], let state = try? await Self.paneState(),
              let count = WritingAX.characterCount(element) else { return nil }
        return TextTargetSnapshot(token: bound.token, kind: .terminal, applicationName: bound.applicationName,
                                  bundleIdentifier: bound.bundleIdentifier, processIdentifier: bound.processIdentifier,
                                  windowIdentifier: state.windowIdentifier, paneIdentity: state.tty,
                                  selection: WritingAX.selectedRange(element) ?? .caret(0)!, contentRevision: String(count),
                                  blockedReason: state.ready ? nil : .terminalNotReady)
    }

    /// Selected terminal history, as read-only rewrite source. It is never replaced.
    func readSource(_ bound: TextTargetSnapshot) throws -> ExactSource {
        guard let element = elements[bound.token], let text = WritingAX.value(element, kAXSelectedTextAttribute) as? String
        else { throw WritingContractError.sourceMismatch }
        return try ExactSource(text: text, range: bound.selection)
    }

    func focusRestored(_ bound: TextTargetSnapshot) -> Bool {
        guard let element = elements[bound.token],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == bound.processIdentifier else { return false }
        return WritingAX.focusedElement(of: bound.processIdentifier).map { CFEqual($0, element) } ?? false
    }

    func apply(_ bound: TextTargetSnapshot, text: String, authorized: WritingAuthorization) async -> WritingApplyOutcome {
        guard TerminalPayload.classify(text) == .singleLine else { return .notApplied(.rejectedByTarget) }
        guard let element = elements[bound.token], let before = WritingAX.characterCount(element) else { return .notApplied(.targetUnavailable) }
        guard let state = try? await Self.paneState() else { return .notApplied(.terminalNotReady) }
        guard state.windowIdentifier == bound.windowIdentifier, state.tty == bound.paneIdentity else { return .notApplied(.targetChanged) }
        guard state.ready else { return .notApplied(.terminalNotReady) }
        // No suspension from here to the keystroke. The caret baseline is sampled before the paste is posted,
        // so a fast echo cannot be mistaken for the starting position.
        guard authorized() else { return .notApplied(.canceled) }
        guard focusRestored(bound) else { return .notApplied(.focusChanged) }
        let caretBefore = WritingAX.selectedRange(element)
        guard let snapshot = clipboard.snapshot() else { return .notApplied(.clipboardUnavailable) }
        guard let staged = clipboard.stage(text, preserving: snapshot) else { return .notApplied(.clipboardUnavailable) }
        WritingAX.postPaste(to: bound.processIdentifier)
        // Evidence of the echo: the insertion caret advanced by exactly the text. Buffer growth alone could be
        // unrelated output, and Terminal's AX count drops a character per soft wrap, so it is not used.
        let length = text.utf16.count
        let landed = await WritingAX.poll(timeout: 2.0) {
            guard let caretBefore, caretBefore.isEmpty, let now = WritingAX.selectedRange(element), now.isEmpty else { return false }
            return now.location - caretBefore.location == length
        }
        guard landed else { clipboard.leaveUnsettled(staged); return .deliveryUnknown }
        clipboard.restore(staged)
        guard let after = try? await Self.paneState(), after.tty == state.tty, !after.busy else { return .deliveryUnknown }
        return .applied(WritingAppliedEdit(targetToken: bound.token, insertedRange: .caret(0)!.replaced(by: text), insertedText: text,
                                           replacedText: "", postRevision: String(WritingAX.characterCount(element) ?? before)))
    }

    private var order: [UUID] = []
    private func remember(_ token: UUID, _ element: AXUIElement) {
        elements[token] = element; order.append(token)
        while order.count > 8 { elements.removeValue(forKey: order.removeFirst()) }
    }
}
