import Foundation

/// Live consent to share a whole display when no originating window exists. It lives only in memory for one
/// running Clicky process: relaunch, crash or revocation clears it, and a stored preference is never a grant.
nonisolated public struct GuideDisplayConsent: Equatable, Sendable {
    public struct Grant: Equatable, Sendable {
        public let display: UInt32
        public let provider: AgentProvider
        public init(display: UInt32, provider: AgentProvider) { self.display = display; self.provider = provider }
    }
    public enum Decision: Equatable, Sendable { case granted, needsPrompt, declined, disallowed }

    public private(set) var grant: Grant?
    private var declinedRequest: UInt64?

    public init() {}

    /// A new display or a different provider endpoint is a new scope and needs its own approval.
    public func decision(display: UInt32, provider: AgentProvider, request: UInt64, preferenceAllows: Bool) -> Decision {
        guard preferenceAllows else { return .disallowed }
        if grant == Grant(display: display, provider: provider) { return .granted }
        return declinedRequest == request ? .declined : .needsPrompt
    }
    public mutating func approve(display: UInt32, provider: AgentProvider) { grant = Grant(display: display, provider: provider) }
    /// Text only declines this request; the next question may ask again rather than looping now.
    public mutating func decline(request: UInt64) { declinedRequest = request }
    public mutating func revoke() { grant = nil; declinedRequest = nil }

    public static let preferenceKey = "displayFallbackAllowed"
    static let legacyApprovalKey = "displaySharingApproved"

    /// Moves the legacy persisted approval into the preference without treating it as a live grant.
    public static func migrate(_ defaults: UserDefaults) {
        guard defaults.object(forKey: legacyApprovalKey) != nil else { return }
        if defaults.object(forKey: preferenceKey) == nil { defaults.set(defaults.bool(forKey: legacyApprovalKey), forKey: preferenceKey) }
        defaults.removeObject(forKey: legacyApprovalKey)
    }
}
