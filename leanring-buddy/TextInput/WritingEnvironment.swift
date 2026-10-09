import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// The destinations bound when Quick Ask opens. VS Code offers its document editor as primary and its
/// active integrated terminal as an explicit alternate, because the bridge cannot tell which had focus.
struct WritingTargets {
    var primary: TextTargetSnapshot?
    var alternate: TextTargetSnapshot?
}

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
    /// The single external write for one claimed proposal revision. Adapters never retry or switch strategy.
    var apply: (_ target: TextTargetSnapshot, _ range: UTF16Range, _ text: String, _ expectedSource: String) async -> WritingApplyOutcome
    /// Guarded inverse of one applied edit; refuses when the inserted text or revision changed since.
    var restore: (TextTargetSnapshot, WritingAppliedEdit) async -> Bool
    var copy: (String) -> Void
    var makeAgent: (_ provider: AgentProvider, _ executable: URL, _ root: URL, _ effort: AskEffort) throws -> any GuideAgentRunning
}
