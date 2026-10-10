import Foundation
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// One scripted step of the fake writing provider.
enum WritingScript {
    case reply(GuidePresentation)
    case fail(Error)
    /// Holds the turn open until the test calls `release`; ignores cancellation like a real late reply.
    case suspend
}

/// A scripted provider conversation. State is lock-protected so tests can poll it synchronously.
nonisolated final class FakeWritingAgent: GuideAgentRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [WritingScript] = []
    private var recorded: [GuideAgentTurn] = []
    private var closes = 0
    private var pending: CheckedContinuation<GuidePresentation, Error>?

    var turns: [GuideAgentTurn] { lock.withLock { recorded } }
    var closeCount: Int { lock.withLock { closes } }
    var hasPendingTurn: Bool { lock.withLock { pending != nil } }
    func enqueue(_ script: WritingScript) { lock.withLock { scripts.append(script) } }

    func turn(_ request: GuideAgentTurn) async throws -> GuidePresentation {
        let script = lock.withLock { () -> WritingScript? in
            recorded.append(request)
            return scripts.isEmpty ? nil : scripts.removeFirst()
        }
        switch script {
        case .reply(let presentation)?: return presentation
        case .fail(let error)?: throw error
        case .suspend?: return try await withCheckedThrowingContinuation { continuation in lock.withLock { pending = continuation } }
        case nil: throw AskError.incompleteTurn
        }
    }

    func release(_ presentation: GuidePresentation) {
        let continuation = lock.withLock { () -> CheckedContinuation<GuidePresentation, Error>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: presentation)
    }

    func identifier() async -> String? { "scripted-writing" }
    func close() async { lock.withLock { closes += 1 } }
}

/// Mutable fake desktop plus the `WritingEnvironment` built over it. Everything else is production code.
@MainActor
final class FakeWritingWorld {
    typealias ApplyCall = (target: TextTargetSnapshot, range: UTF16Range, text: String, expectedSource: String)

    nonisolated static let pid: Int32 = 4242

    var primary: TextTargetSnapshot?
    var alternate: TextTargetSnapshot?
    var ambiguous = false
    /// What `liveTarget` returns; nil means "the bound target, unchanged".
    var live: TextTargetSnapshot?
    var sourceText = ""
    var surrounding: WritingHostPayload.Surrounding?
    var frontmost: Int32? = FakeWritingWorld.pid
    var focusRestorable = true
    var keyReleased = true
    /// nil computes `.applied` from the inputs.
    var applyResult: WritingApplyOutcome?
    var restoreResult = true
    var definitions = WritingDefinitions.empty
    /// Runs inside the adapter just before its commit-point authorization check (models work suspended there).
    var beforeCommit: (() -> Void)?
    /// Ordered native effects: "keyRelease", "closeComposer", "restoreFocus", "apply", "restore".
    private(set) var events: [String] = []
    private(set) var canceledAtCommit = 0

    private(set) var applyCalls: [ApplyCall] = []
    private(set) var readSourceCalls = 0
    private(set) var readSurroundingCalls = 0
    private(set) var restoreCalls: [WritingAppliedEdit] = []
    private(set) var copied: [String] = []
    private(set) var agentsMade = 0
    let agent = FakeWritingAgent()

    init(primary: TextTargetSnapshot? = nil) { self.primary = primary ?? FakeWritingWorld.field() }

    nonisolated static func field(kind: WritingTargetKind = .textField, selection: UTF16Range = .caret(5)!, revision: String = "r1",
                      pane: String? = nil, pid: Int32 = FakeWritingWorld.pid) -> TextTargetSnapshot {
        TextTargetSnapshot(kind: kind, applicationName: "Fixture", bundleIdentifier: "fixture.clicky", processIdentifier: pid,
                           windowIdentifier: 7, paneIdentity: pane ?? (kind == .terminal ? "tty1" : nil),
                           selection: selection, contentRevision: revision)
    }

    nonisolated static func range(_ location: Int, _ length: Int) -> UTF16Range { UTF16Range(location: location, length: length)! }

    /// When set, `.local` coordinators get the real `LocalMLXAgent` over this scripted client.
    var localModel: LocalInferenceClient?

    var environment: WritingEnvironment {
        WritingEnvironment(
            captureTargets: { [unowned self] _ in WritingTargets(primary: primary, alternate: alternate, ambiguous: ambiguous) },
            liveTarget: { [unowned self] bound in live ?? bound },
            readSource: { [unowned self] target in
                readSourceCalls += 1
                // A paste-only destination copies a selection whose range it cannot read.
                let range = target.pasteOnly && target.selection.isEmpty ? UTF16Range(location: 0, length: sourceText.utf16.count)! : target.selection
                return try ExactSource(text: sourceText, range: range)
            },
            readSurrounding: { [unowned self] _ in readSurroundingCalls += 1; return surrounding },
            frontmostProcess: { [unowned self] in frontmost },
            restoreFocus: { [unowned self] _ in events.append("restoreFocus"); return focusRestorable },
            waitForSubmitKeyRelease: { [unowned self] in events.append("keyRelease"); return keyReleased },
            apply: { [unowned self] target, range, text, expected, authorized in
                beforeCommit?()
                guard authorized() else { canceledAtCommit += 1; return .notApplied(.canceled) }
                events.append("apply")
                applyCalls.append((target, range, text, expected))
                return applyResult ?? .applied(WritingAppliedEdit(targetToken: target.token, insertedRange: range.replaced(by: text),
                                                                  insertedText: text, replacedText: expected, postRevision: "r2"))
            },
            restore: { [unowned self] _, edit, authorized in
                beforeCommit?()
                guard authorized() else { canceledAtCommit += 1; return false }
                events.append("restore"); restoreCalls.append(edit); return restoreResult
            },
            copy: { [unowned self] text in copied.append(text) },
            makeAgent: { [unowned self] provider, _, _, _ in
                agentsMade += 1
                if let localModel, provider == .local { return LocalMLXAgent(contract: .writing, client: localModel) }
                return agent
            })
    }

    /// A coordinator over this world, bound to the primary/alternate targets as Quick Ask opening would.
    func makeCoordinator(provider: AgentProvider = .preview, executable: Bool = false) async -> WritingCoordinator {
        let coordinator = WritingCoordinator(environment: environment)
        coordinator.provider = provider
        coordinator.executable = executable ? URL(fileURLWithPath: "/nonexistent/scripted-writer") : nil
        coordinator.definitions = { [unowned self] in definitions }
        coordinator.closeComposer = { [unowned self] in events.append("closeComposer") }
        await coordinator.bind(processIdentifier: FakeWritingWorld.pid)
        return coordinator
    }

    static func draft(_ text: String, subject: String? = nil) -> GuidePresentation {
        GuidePresentation(kind: .writing_draft, text: text, subject: subject)
    }
}

/// Polls (yielding, then 1 ms sleeps) until the condition holds; fails the test after about two seconds.
@MainActor
func waitUntil(_ message: String = "condition not reached", file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { XCTFail(message, file: file, line: line); return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
