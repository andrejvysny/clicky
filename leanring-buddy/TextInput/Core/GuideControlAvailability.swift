import Foundation

/// Which walkthrough controls are enabled. End, Pause and sharing revocation never wait for a busy turn;
/// only actions that would start a conflicting turn are disabled while one runs.
nonisolated public struct GuideControlAvailability: Equatable, Sendable {
    public let end: Bool
    public let pause: Bool
    public let next: Bool
    public let retry: Bool
    public let recheck: Bool
    public let resume: Bool
    public let changeTarget: Bool

    public init(phase: GuideTaskState.Phase?, isBusy: Bool, hasStep: Bool, demo: Bool = false) {
        let live = phase.map { $0 != .completed && $0 != .canceled } ?? false
        end = live || isBusy || demo
        pause = (live && phase != .paused) || (isBusy && phase != .paused)
        next = !isBusy && (hasStep || demo)
        retry = !isBusy && !demo && live
        recheck = !isBusy && hasStep && (phase == .waiting || phase == .uncertain)
        resume = !isBusy && phase == .paused
        changeTarget = !isBusy && live
    }
}
