import AppKit
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Routes each bound destination to its adapter: macOS Terminal, VS Code (bridge), or AX text fields
/// (validated: Chrome). Snapshot tokens remember which adapter owns a destination.
@MainActor
final class WritingNativeTargets {
    private let field = WritingAXFieldAdapter()
    private let terminal = WritingTerminalAdapter()
    private let vscode = WritingVSCodeAdapter()

    func capture(_ processIdentifier: Int32?) async -> WritingTargets {
        guard let processIdentifier, processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated else {
            return WritingTargets()
        }
        let bundle = application.bundleIdentifier ?? ""
        if bundle == WritingTerminalAdapter.bundleIdentifier { return WritingTargets(primary: await terminal.capture(application)) }
        if WritingVSCodeAdapter.bundleIdentifiers.contains(bundle) { return await vscode.capture(application) }
        return WritingTargets(primary: field.capture(application))
    }

    func live(_ bound: TextTargetSnapshot) async -> TextTargetSnapshot? {
        if vscode.owns(bound.token) { return await vscode.live(bound) }
        return bound.kind == .terminal ? await terminal.live(bound) : field.live(bound)
    }

    func readSource(_ bound: TextTargetSnapshot) async throws -> ExactSource {
        if vscode.owns(bound.token) { return try await vscode.readSource(bound) }
        return bound.kind == .terminal ? try terminal.readSource(bound) : try field.readSource(bound)
    }

    func readSurrounding(_ bound: TextTargetSnapshot) async -> WritingHostPayload.Surrounding? {
        if vscode.owns(bound.token) { return await vscode.readSurrounding(bound) }
        return bound.kind == .textField ? field.readSurrounding(bound) : nil
    }

    /// Re-activates the original application only when Clicky itself took it away (its own panel or Settings);
    /// a deliberate switch to some other application is never overridden.
    func restoreFocus(_ bound: TextTargetSnapshot) async -> Bool {
        guard let application = NSRunningApplication(processIdentifier: bound.processIdentifier), !application.isTerminated else { return false }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front != bound.processIdentifier {
            guard front == ProcessInfo.processInfo.processIdentifier else { return false }
            application.activate(options: [])
        }
        guard await WritingAX.poll(timeout: 1.0, { NSWorkspace.shared.frontmostApplication?.processIdentifier == bound.processIdentifier })
        else { return false }
        if vscode.owns(bound.token) {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.0
            while ProcessInfo.processInfo.systemUptime < deadline {
                if await vscode.focusRestored(bound) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        if bound.kind == .terminal { return await WritingAX.poll(timeout: 1.0) { terminal.focusRestored(bound) } }
        return await WritingAX.poll(timeout: 1.0) { field.focusRestored(bound) }
    }

    func apply(_ bound: TextTargetSnapshot, range: UTF16Range, text: String, expected: String) async -> WritingApplyOutcome {
        if vscode.owns(bound.token) { return await vscode.apply(bound, range: range, text: text, expectedSource: expected) }
        if bound.kind == .terminal { return await terminal.apply(bound, text: text) }
        return await field.apply(bound, range: range, text: text, expectedSource: expected)
    }

    func restore(_ bound: TextTargetSnapshot, _ edit: WritingAppliedEdit) async -> Bool {
        if vscode.owns(bound.token) { return await vscode.restore(bound, edit) }
        // Terminal input is never cleared or undone by Clicky.
        return bound.kind == .textField ? await field.restore(bound, edit) : false
    }

    var environment: WritingEnvironment {
        WritingEnvironment(
            captureTargets: { [weak self] in await self?.capture($0) ?? WritingTargets() },
            liveTarget: { [weak self] in await self?.live($0) },
            readSource: { [weak self] in
                guard let self else { throw WritingContractError.sourceMismatch }
                return try await readSource($0)
            },
            readSurrounding: { [weak self] in await self?.readSurrounding($0) },
            frontmostProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            restoreFocus: { [weak self] in await self?.restoreFocus($0) ?? false },
            waitForSubmitKeyRelease: { await WritingAX.poll(timeout: 10, { WritingAX.submitKeysUp }) },
            apply: { [weak self] in await self?.apply($0, range: $1, text: $2, expected: $3) ?? .notApplied(.targetUnavailable) },
            restore: { [weak self] in await self?.restore($0, $1) ?? false },
            copy: { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) },
            makeAgent: { provider, executable, root, effort in
                let profile = try GuideAgentProfile(provider: provider, root: root, taskID: UUID(), effort: effort, contract: .writing)
                return GuideAgentSession(profile: profile, executable: executable)
            })
    }
}
