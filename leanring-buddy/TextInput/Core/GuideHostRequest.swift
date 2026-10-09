import Foundation

nonisolated public enum GuideRequestPurpose: String, Codable, Sendable {
    case planning, sideQuestion, verification, continuation, recovery, oneOffContext

    public func permits(_ kind: GuidePresentation.Kind) -> Bool {
        switch self {
        case .verification: return kind == .verification_result
        case .sideQuestion: return [.context_request, .annotation, .explanation, .clarification, .task_proposal].contains(kind)
        default: return kind != .verification_result
        }
    }
}

nonisolated public struct GuideHostTaskContext: Encodable, Sendable {
    public let taskID: UUID
    public let goal: String
    public let stepRevision: UInt64
    public let contextRevision: UInt64
    public let currentStep: GuidePresentation?
    public let milestones: [GuideMilestone]
    /// Stored final-goal conditions; completion is verified against these, never a newer goal.
    public let goalChecks: [String]
    public let planRevision: UInt64
    public let plan: [GuidePlanItem]
    public init(_ task: GuideTaskState) {
        taskID = task.identifier; goal = task.goal; stepRevision = task.stepRevision
        contextRevision = task.contextRevision; currentStep = task.step; milestones = task.milestones
        goalChecks = task.plan.goalChecks; planRevision = task.plan.revision; plan = task.plan.items
    }
}

nonisolated public struct GuideHostRequest: Encodable, Sendable {
    public let protocolVersion = GuideContract.promptVersion
    public let purpose: GuideRequestPurpose
    public let allowedKinds: [String]
    public let responseContract: String
    public let text: String
    public let task: GuideHostTaskContext?
    public let capture: GuideCaptureContext?

    public init(purpose: GuideRequestPurpose, text: String, task: GuideHostTaskContext?, capture: GuideCaptureContext?) {
        self.purpose = purpose; self.text = text; self.task = task; self.capture = capture
        allowedKinds = GuideContract.allowedKinds(for: purpose).map(\.rawValue)
        responseContract = GuideContract.responseContract(for: purpose)
    }
}
