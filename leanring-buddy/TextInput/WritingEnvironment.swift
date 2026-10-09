import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// The destinations bound when Quick Ask opens. VS Code offers its document editor as primary and its
/// active integrated terminal as an alternate. The bridge cannot tell which had keyboard focus, so with both
/// present the binding is `ambiguous` and nothing is applied without an explicit Insert/Replace.
struct WritingTargets {
    var primary: TextTargetSnapshot?
    var alternate: TextTargetSnapshot?
    var ambiguous = false
}

/// Operation-scoped write authority. Adapters check it at their last synchronous point before the external
/// side effect (paste keystroke, bridge request); Stop, revocation or a newer operation make it false.
typealias WritingAuthorization = @MainActor () -> Bool

/// Native effects the writing coordinator depends on. The app uses `.live` (`WritingNativeTargets`);
/// coordinator tests inject fakes while exercising the same `WritingCoordinator` code.
struct WritingEnvironment {
    /// Binds the focused editable destination of the given process before Quick Ask takes focus. Reads no content.
    var captureTargets: (_ processIdentifier: Int32?) async -> WritingTargets
    /// Re-reads the bound destination's identity, caret and revision now. Reads no content.
    var liveTarget: (TextTargetSnapshot) async -> TextTargetSnapshot?
    /// Reads the exact selected text of the bound destination; only after an explicit editing request.
    var readSource: (TextTargetSnapshot) async throws -> ExactSource
    /// Bounded text around the selection; only after the visible per-request opt-in.
    var readSurrounding: (TextTargetSnapshot) async -> WritingHostPayload.Surrounding?
    var frontmostProcess: () -> Int32?
    /// Returns keyboard focus to the bound control after Quick Ask closes; false when it cannot be re-established.
    var restoreFocus: (TextTargetSnapshot) async -> Bool
    /// Waits until Return and keypad Enter are released so the submit key never reaches the destination.
    var waitForSubmitKeyRelease: () async -> Bool
    /// The single external write for one claimed proposal revision. Adapters never retry or switch strategy,
    /// and return `.notApplied(.canceled)` when `authorized` turned false before they committed.
    var apply: (_ target: TextTargetSnapshot, _ range: UTF16Range, _ text: String, _ expectedSource: String,
                _ authorized: @escaping WritingAuthorization) async -> WritingApplyOutcome
    /// Guarded inverse of one applied edit; refuses when the inserted text or revision changed since.
    var restore: (TextTargetSnapshot, WritingAppliedEdit, _ authorized: @escaping WritingAuthorization) async -> Bool
    var copy: (String) -> Void
    var makeAgent: (_ provider: AgentProvider, _ executable: URL, _ root: URL, _ effort: AskEffort) throws -> any GuideAgentRunning
}

enum WritingRequestError: LocalizedError {
    case noSelection
    var errorDescription: String? { WritingBlockReason.noSelection.message }
}
