import Foundation

nonisolated public enum GuideRequestPurpose: String, Codable, Sendable {
    case planning, sideQuestion, verification, continuation, recovery, oneOffContext
    /// A clean writing process: drafts and clarifications only, never guide output.
    case writing

    public func permits(_ kind: GuidePresentation.Kind) -> Bool {
        switch self {
        case .verification: return kind == .verification_result
        case .sideQuestion: return [.context_request, .annotation, .explanation, .clarification, .task_proposal].contains(kind)
        case .writing: return kind == .writing_draft || kind == .clarification
        default: return kind != .verification_result && kind != .writing_draft
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
    public let protocolVersion: String
    public let purpose: GuideRequestPurpose
    public let allowedKinds: [String]
    public let responseContract: String
    public let text: String
    public let task: GuideHostTaskContext?
    public let capture: GuideCaptureContext?
    /// Writing purpose only; absent from guide requests.
    public let writing: WritingHostPayload?

    public init(purpose: GuideRequestPurpose, text: String, task: GuideHostTaskContext?, capture: GuideCaptureContext?,
                writing: WritingHostPayload? = nil) {
        self.purpose = purpose; self.text = text; self.task = task; self.capture = capture; self.writing = writing
        protocolVersion = purpose == .writing ? WritingPrompt.promptVersion : GuideContract.promptVersion
        allowedKinds = GuideContract.allowedKinds(for: purpose).map(\.rawValue)
        responseContract = GuideContract.responseContract(for: purpose)
    }
}
