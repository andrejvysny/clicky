import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public struct GuideRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }
}

nonisolated public struct GuideAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case click, right_click, double_click, key, field_commit }
    public let kind: Kind
    public let keyCode: UInt16?
    public let modifiers: UInt64?
    public init(kind: Kind, keyCode: UInt16? = nil, modifiers: UInt64? = nil) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers
    }
}

nonisolated public struct GuideOutcome: Codable, Equatable, Sendable {
    public let description: String
    public let axRole: String?
    public let axTitle: String?
    public let axValue: String?
    public init(description: String, axRole: String? = nil, axTitle: String? = nil, axValue: String? = nil) {
        self.description = description; self.axRole = axRole; self.axTitle = axTitle; self.axValue = axValue
    }
}

nonisolated public struct GuidePresentation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case context_request, guide_step, annotation, explanation, clarification, verification_result, task_completed, task_proposal
    }
    public let kind: Kind
    public let text: String
    public let captureID: UUID?
    public let target: GuideRect?
    public let action: GuideAction?
    public let outcome: GuideOutcome?
    public let matches: Bool?
    public let evidence: String?
    public let proposedGoal: String?
    public let crop: GuideRect?

    public init(kind: Kind, text: String, captureID: UUID? = nil, target: GuideRect? = nil,
                action: GuideAction? = nil, outcome: GuideOutcome? = nil, matches: Bool? = nil,
                evidence: String? = nil, proposedGoal: String? = nil, crop: GuideRect? = nil) {
        self.kind = kind; self.text = text; self.captureID = captureID; self.target = target
        self.action = action; self.outcome = outcome; self.matches = matches
        self.evidence = evidence; self.proposedGoal = proposedGoal; self.crop = crop
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144,
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              GuideSchemaValidation.validate(object, schema: GuideContract.schema) else {
            throw AskError.protocolFailure("The agent returned an invalid presentation.")
        }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw AskError.protocolFailure("The agent returned an invalid presentation.") }
        try result.validate()
        return result
    }

    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
              target?.isValid != false, crop?.isValid != false else { throw invalid }
        let hasStepFields = target != nil || action != nil || outcome != nil
        let hasVerdictFields = matches != nil || evidence != nil
        switch kind {
        case .context_request:
            guard !hasStepFields, !hasVerdictFields, proposedGoal == nil else { throw invalid }
        case .guide_step:
            guard !hasVerdictFields, proposedGoal == nil, crop == nil, text.utf8.count <= 600 else { throw invalid }
        case .annotation:
            guard target != nil, captureID != nil, action == nil, outcome == nil, !hasVerdictFields,
                  proposedGoal == nil, crop == nil, text.utf8.count <= 600 else { throw invalid }
        case .verification_result, .task_completed:
            guard !hasStepFields, proposedGoal == nil, crop == nil else { throw invalid }
        case .explanation, .clarification, .task_proposal:
            // A captureID echoed on prose is harmless: these kinds never target or verify anything.
            guard !hasStepFields, !hasVerdictFields, crop == nil,
                  kind == .task_proposal || proposedGoal == nil else { throw invalid }
        }
        if target != nil { guard kind == .guide_step || kind == .annotation else { throw invalid } }
        if crop != nil { guard kind == .context_request, captureID != nil else { throw invalid } }
        if kind == .guide_step {
            guard captureID != nil, target != nil, let action, let outcome,
                  !outcome.description.isEmpty else { throw invalid }
            if action.kind == .key || action.kind == .field_commit {
                guard action.keyCode != nil, action.modifiers != nil else { throw invalid }
                guard action.keyCode! < 128, action.modifiers! & ~UInt64(1_966_080) == 0 else { throw invalid }
            } else if action.keyCode != nil || action.modifiers != nil { throw invalid }
        }
        if kind == .verification_result || kind == .task_completed {
            guard captureID != nil, matches != nil, let evidence, !evidence.isEmpty else { throw invalid }
        }
        if kind == .task_proposal { guard let proposedGoal, !proposedGoal.isEmpty else { throw invalid } }
        if target != nil { guard captureID != nil else { throw invalid } }
    }

    private var invalid: AskError { .protocolFailure("The agent returned an invalid presentation. Retry with fresh context.") }
}
