import Foundation

/// One semantic milestone of the host-owned plan: intent only, never coordinates.
nonisolated public struct GuidePlanItem: Encodable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case upcoming, current, done, superseded }
    public let id: UUID
    public let intent: String
    public internal(set) var status: Status
}

/// The bounded semantic plan for one task. The provider proposes routes; the host keeps identities,
/// provenance and the original goal checks. A later route can reorder or replace pending milestones,
/// but it cannot erase completed ones or rewrite the stored final-goal criteria.
nonisolated public struct GuidePlan: Encodable, Equatable, Sendable {
    public private(set) var revision: UInt64 = 0
    /// Frozen at the first nonempty set; final completion is checked against these, not a newer easier goal.
    public private(set) var goalChecks: [String] = []
    public private(set) var items: [GuidePlanItem] = []

    public init() {}

    public var current: GuidePlanItem? { items.first { $0.status == .current } }
    public var completedCount: Int { items.filter { $0.status == .done }.count }
    public var upcoming: [GuidePlanItem] { items.filter { $0.status == .upcoming } }

    /// Adopts a step's milestone and advisory route. Returns true when the plan revision changed.
    @discardableResult
    public mutating func adopt(milestone: String?, route: [String]?, goalChecks proposed: [String]?) -> Bool {
        if goalChecks.isEmpty, let proposed, !proposed.isEmpty { goalChecks = Array(proposed.prefix(GuidePresentation.goalCheckLimit)) }
        var intents = (route ?? []).filter { !Self.key($0).isEmpty }
        if let milestone, !Self.key(milestone).isEmpty, intents.first.map(Self.key) != Self.key(milestone) {
            intents.removeAll { Self.key($0) == Self.key(milestone) }
            intents.insert(milestone, at: 0)
        }
        intents = Array(Self.unique(intents).prefix(GuidePresentation.planLimit))
        guard !intents.isEmpty else { return false }
        let done = items.filter { $0.status == .done }
        // A route never re-opens finished work: a completed intent named again is a new, separate milestone.
        let pending = items.filter { $0.status == .current || $0.status == .upcoming }
        var next: [GuidePlanItem] = []
        for (index, intent) in intents.enumerated() {
            let reused = pending.first { candidate in
                Self.key(candidate.intent) == Self.key(intent) && !next.contains { $0.id == candidate.id }
            }
            next.append(GuidePlanItem(id: reused?.id ?? UUID(), intent: intent, status: index == 0 ? .current : .upcoming))
        }
        let dropped = pending.filter { old in !next.contains { $0.id == old.id } }.map { item -> GuidePlanItem in
            var superseded = item; superseded.status = .superseded; return superseded
        }
        let updated = done + items.filter { $0.status == .superseded } + dropped + next
        guard updated != items else { return false }
        items = updated; revision &+= 1
        return true
    }

    /// Marks the current milestone done. Manual or catch-up provenance lives in the execution ledger, not here.
    public mutating func completeCurrent() {
        guard let index = items.firstIndex(where: { $0.status == .current }) else { return }
        items[index].status = .done; revision &+= 1
        if let next = items.firstIndex(where: { $0.status == .upcoming }) { items[next].status = .current }
    }

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private static func unique(_ intents: [String]) -> [String] {
        var seen = Set<String>()
        return intents.filter { seen.insert(key($0)).inserted }
    }
}

/// Why guidance is not currently waiting for the user. Temporary reasons resume automatically after
/// fresh validation; every other reason needs a deliberate user action, and a late focus event cannot clear it.
nonisolated public enum GuideInterruption: String, Codable, CaseIterable, Sendable {
    case composer, sideAnswer, appSwitch
    case explicitPause, sharingRevoked, permissionLost, lockedOrAsleep, targetClosed, providerFailure

    public var isTemporary: Bool { self == .composer || self == .sideAnswer || self == .appSwitch }
}
