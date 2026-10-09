import AppKit
#if canImport(ClickyCore)
import ClickyCore
#endif

/// VS Code through the opt-in Clicky bridge extension: versioned range edits in the document editor, and
/// insert-only `sendText(text, false)` into the active integrated terminal. Without the bridge, VS Code
/// targets stay preview-only. The bridge cannot tell whether the editor or the terminal had keyboard focus,
/// so the terminal is offered as an explicit alternate destination.
@MainActor
final class WritingVSCodeAdapter {
    static let bundleIdentifiers: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
    static var bridgeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Clicky/vscode-bridge", isDirectory: true)
    }

    private struct Binding { let socket: URL; let uri: String?; let terminalID: Int? }
    private var bindings: [UUID: Binding] = [:]
    private let client = VSCodeBridgeClient(directory: WritingVSCodeAdapter.bridgeDirectory)

    func capture(_ application: NSRunningApplication) async -> WritingTargets {
        let window = WindowSnapshotCapture.target(for: application)?.windowIdentifier
        let base = (name: application.localizedName ?? "VS Code", bundle: application.bundleIdentifier ?? "", pid: application.processIdentifier)
        guard client.tokenExists(), let (socket, state) = await client.focusedWindow() else {
            return WritingTargets(primary: TextTargetSnapshot(kind: .vscodeEditor, applicationName: base.name, bundleIdentifier: base.bundle,
                                                              processIdentifier: base.pid, windowIdentifier: window, paneIdentity: nil,
                                                              selection: .caret(0)!, contentRevision: "", blockedReason: .bridgeUnavailable),
                                  alternate: nil)
        }
        var targets = WritingTargets()
        if let editor = state.editor {
            let snapshot = Self.editorSnapshot(editor, name: base.name, bundle: base.bundle, pid: base.pid, window: window)
            remember(snapshot.token, Binding(socket: socket, uri: editor.uri, terminalID: nil))
            targets.primary = snapshot
        }
        if let terminal = state.terminal, let id = terminal.id {
            let snapshot = Self.terminalSnapshot(terminal, id: id, name: base.name, bundle: base.bundle, pid: base.pid, window: window)
            remember(snapshot.token, Binding(socket: socket, uri: nil, terminalID: id))
            if targets.primary == nil { targets.primary = snapshot } else { targets.alternate = snapshot }
        }
        return targets
    }

    private static func editorSnapshot(_ editor: VSCodeBridgeState.Editor, name: String, bundle: String, pid: Int32, window: UInt32?,
                                       token: UUID = UUID()) -> TextTargetSnapshot {
        let selection = editor.selections.first.flatMap { UTF16Range(location: $0.start, length: $0.end - $0.start) } ?? .caret(0)!
        return TextTargetSnapshot(token: token, kind: .vscodeEditor, applicationName: name, bundleIdentifier: bundle, processIdentifier: pid,
                                  windowIdentifier: window, paneIdentity: editor.uri, selection: selection, contentRevision: String(editor.version),
                                  blockedReason: editor.selections.count == 1 ? nil : .unsupportedTarget)
    }

    private static func terminalSnapshot(_ terminal: VSCodeBridgeState.Terminal, id: Int, name: String, bundle: String, pid: Int32,
                                         window: UInt32?, token: UUID = UUID()) -> TextTargetSnapshot {
        TextTargetSnapshot(token: token, kind: .terminal, applicationName: name + " terminal", bundleIdentifier: bundle, processIdentifier: pid,
                           windowIdentifier: window, paneIdentity: "vscode-terminal:\(id)", selection: .caret(0)!, contentRevision: "terminal",
                           blockedReason: terminal.shellIntegration && !terminal.busy ? nil : .terminalNotReady)
    }

    func owns(_ token: UUID) -> Bool { bindings[token] != nil }

    func live(_ bound: TextTargetSnapshot) async -> TextTargetSnapshot? {
        guard let binding = bindings[bound.token], let state = try? await client.state(socket: binding.socket),
              let application = NSRunningApplication(processIdentifier: bound.processIdentifier) else { return nil }
        let window = WindowSnapshotCapture.target(for: application)?.windowIdentifier
        if binding.uri != nil {
            guard let editor = state.editor else { return nil }
            return Self.editorSnapshot(editor, name: bound.applicationName, bundle: bound.bundleIdentifier, pid: bound.processIdentifier,
                                       window: window, token: bound.token)
        }
        guard let terminal = state.terminal, let id = terminal.id else { return nil }
        return Self.terminalSnapshot(terminal, id: id, name: String(bound.applicationName.dropLast(" terminal".count)),
                                     bundle: bound.bundleIdentifier, pid: bound.processIdentifier, window: window, token: bound.token)
    }

    func readSource(_ bound: TextTargetSnapshot) async throws -> ExactSource {
        guard let binding = bindings[bound.token], let uri = binding.uri, let version = Int(bound.contentRevision) else {
            throw WritingContractError.sourceMismatch
        }
        let text = try await client.readRange(socket: binding.socket, uri: uri, version: version, range: bound.selection)
        return try ExactSource(text: text, range: bound.selection)
    }

    func readSurrounding(_ bound: TextTargetSnapshot, limit: Int = 1_000) async -> WritingHostPayload.Surrounding? {
        guard let binding = bindings[bound.token], let uri = binding.uri, let version = Int(bound.contentRevision) else { return nil }
        let start = max(0, bound.selection.location - limit)
        let before = try? await client.readRange(socket: binding.socket, uri: uri, version: version,
                                                 range: UTF16Range(location: start, length: bound.selection.location - start)!)
        var after: String?
        // The document length is unknown here; shrink the window until it fits.
        for length in [limit, limit / 4, 64, 0] where after == nil {
            after = try? await client.readRange(socket: binding.socket, uri: uri, version: version,
                                                range: UTF16Range(location: bound.selection.end, length: length)!)
        }
        return WritingHostPayload.Surrounding(before: before ?? "", after: after ?? "")
    }

    func focusRestored(_ bound: TextTargetSnapshot) async -> Bool {
        guard let binding = bindings[bound.token] else { return false }
        return (try? await client.state(socket: binding.socket))?.focused == true
    }

    func apply(_ bound: TextTargetSnapshot, range: UTF16Range, text: String, expectedSource: String) async -> WritingApplyOutcome {
        guard let binding = bindings[bound.token] else { return .notApplied(.targetUnavailable) }
        do {
            if let id = binding.terminalID {
                guard TerminalPayload.classify(text) == .singleLine else { return .notApplied(.rejectedByTarget) }
                try await client.insertTerminal(socket: binding.socket, terminalID: id, text: text)
                return .acknowledged(WritingAppliedEdit(targetToken: bound.token, insertedRange: .caret(0)!.replaced(by: text),
                                                        insertedText: text, replacedText: "", postRevision: "terminal"))
            }
            guard let uri = binding.uri, let version = Int(bound.contentRevision) else { return .notApplied(.targetUnavailable) }
            let result = try await client.replaceRange(socket: binding.socket, uri: uri, version: version, range: range,
                                                       text: text, expected: expectedSource)
            guard result.applied else { return .notApplied(.rejectedByTarget) }
            guard result.verified == true, let start = result.start, let end = result.end, let newVersion = result.version,
                  let inserted = UTF16Range(location: start, length: end - start) else { return .deliveryUnknown }
            return .applied(WritingAppliedEdit(targetToken: bound.token, insertedRange: inserted, insertedText: text,
                                               replacedText: expectedSource, postRevision: String(newVersion)))
        } catch let error as VSCodeBridgeError {
            return Self.outcome(for: error)
        } catch {
            return .deliveryUnknown
        }
    }

    private static func outcome(for error: VSCodeBridgeError) -> WritingApplyOutcome {
        switch error {
        case .unavailable: return .notApplied(.targetUnavailable)
        case .timedOut, .protocolViolation: return .deliveryUnknown
        case .remote(let code):
            switch code {
            case "stale": return .notApplied(.contentChanged)
            case "sourceChanged": return .notApplied(.sourceChanged)
            case "busy", "noShellIntegration": return .notApplied(.terminalNotReady)
            case "terminalChanged": return .notApplied(.targetChanged)
            case "notFound", "unauthorized": return .notApplied(.targetUnavailable)
            default: return .notApplied(.rejectedByTarget)
            }
        }
    }

    /// Guarded inverse through the same versioned edit: refused unless the inserted text is untouched.
    func restore(_ bound: TextTargetSnapshot, _ edit: WritingAppliedEdit) async -> Bool {
        guard let binding = bindings[bound.token], let uri = binding.uri, let version = Int(edit.postRevision) else { return false }
        let result = try? await client.replaceRange(socket: binding.socket, uri: uri, version: version, range: edit.insertedRange,
                                                    text: edit.replacedText, expected: edit.insertedText)
        return result?.applied == true && result?.verified == true
    }

    private var order: [UUID] = []
    private func remember(_ token: UUID, _ binding: Binding) {
        bindings[token] = binding; order.append(token)
        while order.count > 16 { bindings.removeValue(forKey: order.removeFirst()) }
    }
}
