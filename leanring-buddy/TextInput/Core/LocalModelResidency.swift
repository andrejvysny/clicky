import Foundation

/// When a model group's weights may become resident. Manual is the default: nothing loads or warms up at
/// launch, when Quick Ask opens or when Record is pressed unless the user pressed Load.
nonisolated public enum LocalLoadPolicy: String, Codable, CaseIterable, Sendable {
    case manual, onDemand, preloadAtStartup

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .onDemand: return "Load when needed"
        case .preloadAtStartup: return "Load at startup"
        }
    }
}

nonisolated public struct LocalResidencyPolicy: Codable, Equatable, Sendable {
    public var load: LocalLoadPolicy
    /// Unload after this many idle minutes; nil keeps the model until Unload or quit.
    public var idleUnloadMinutes: Int?

    public init(load: LocalLoadPolicy = .manual, idleUnloadMinutes: Int? = nil) {
        self.load = load
        self.idleUnloadMinutes = idleUnloadMinutes.map { max(1, $0) }
    }
}

/// Per-group policies, so a voice session never implicitly loads the large vision model.
nonisolated public struct LocalResidencySettings: Codable, Equatable, Sendable {
    public var vision = LocalResidencyPolicy()
    public var cleanup = LocalResidencyPolicy()
    public var speech = LocalResidencyPolicy()

    public init() {}

    public subscript(group: LocalModelGroup) -> LocalResidencyPolicy {
        get {
            switch group {
            case .vision: return vision
            case .cleanup: return cleanup
            case .speech: return speech
            }
        }
        set {
            switch group {
            case .vision: vision = newValue
            case .cleanup: cleanup = newValue
            case .speech: speech = newValue
            }
        }
    }
}

nonisolated public enum LocalAdmission: Equatable, Sendable {
    case ready
    case loadAutomatically
    /// Manual policy and not loaded: show "Load …" instead of starting work that would wait silently.
    case needsExplicitLoad
    case overBudget(requiredBytes: UInt64, availableBytes: UInt64)
}

nonisolated public enum LocalResidencyPlanner {
    /// Fraction of physical memory Clicky's resident local models may occupy together; the rest stays for the
    /// foreground apps the user is working in.
    public static let defaultBudgetFraction = 0.45

    /// Whether everyday work in `group` may proceed. An explicit benchmark Run counts as an explicit Load.
    public static func admission(policy: LocalResidencyPolicy, isLoaded: Bool, explicitRun: Bool = false) -> LocalAdmission {
        if isLoaded { return .ready }
        if explicitRun { return .loadAutomatically }
        switch policy.load {
        case .manual: return .needsExplicitLoad
        case .onDemand, .preloadAtStartup: return .loadAutomatically
        }
    }

    public static func groupsToPreload(_ settings: LocalResidencySettings) -> [LocalModelGroup] {
        LocalModelGroup.allCases.filter { settings[$0].load == .preloadAtStartup }
    }

    /// Checks a load against the shared budget. `residentBytes` is the measured footprint of what is
    /// already loaded (not a sum of catalog sizes); `estimatedBytes` is the new model's expected footprint.
    public static func memoryAdmission(estimatedBytes: UInt64, residentBytes: UInt64, physicalMemory: UInt64,
                                       budgetFraction: Double = defaultBudgetFraction) -> LocalAdmission {
        let budget = UInt64(Double(physicalMemory) * min(max(budgetFraction, 0.1), 0.8))
        let available = budget > residentBytes ? budget - residentBytes : 0
        return estimatedBytes <= available ? .ready : .overBudget(requiredBytes: estimatedBytes, availableBytes: available)
    }

    /// Weights plus runtime overhead; a conservative planning number until a measured envelope replaces it.
    public static func estimatedFootprint(weightBytes: Int64) -> UInt64 {
        UInt64(max(0, weightBytes)) + UInt64(max(0, weightBytes)) / 4 + 256 * 1024 * 1024
    }
}

/// Tracks last use per group and reports which loaded groups passed their idle limit.
nonisolated public struct LocalIdleTracker: Equatable, Sendable {
    private var lastUse: [LocalModelGroup: TimeInterval] = [:]

    public init() {}

    public mutating func touch(_ group: LocalModelGroup, at time: TimeInterval) { lastUse[group] = time }
    public mutating func forget(_ group: LocalModelGroup) { lastUse[group] = nil }

    /// Busy groups are never due: a running job keeps its weights.
    public func due(at time: TimeInterval, settings: LocalResidencySettings, loaded: Set<LocalModelGroup>,
                    busy: Set<LocalModelGroup>) -> [LocalModelGroup] {
        loaded.subtracting(busy).sorted { $0.rawValue < $1.rawValue }.filter { group in
            guard let minutes = settings[group].idleUnloadMinutes, let last = lastUse[group] else { return false }
            return time - last >= Double(minutes) * 60
        }
    }
}
