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
    /// How the target is marked on screen; nil draws a circle.
    public let mark: Mark?
    /// Short words drawn beside the mark; `text` is the reply or instruction.
    public let label: String?
    /// Optional second line under a step's instruction.
    public let detail: String?
    /// Exact text to type, shown in a monospaced callout beside the field.
    public let value: String?
    /// Dim next target for dense UIs; steps only, at most one.
    public let ghost: GuideRect?
    /// The model's current estimate of the walkthrough length; it may change between steps.
    public let estimatedSteps: Int?

    public init(kind: Kind, text: String, captureID: UUID? = nil, target: GuideRect? = nil,
                action: GuideAction? = nil, outcome: GuideOutcome? = nil, matches: Bool? = nil,
                evidence: String? = nil, proposedGoal: String? = nil, crop: GuideRect? = nil,
                mark: Mark? = nil, label: String? = nil, detail: String? = nil, value: String? = nil,
                ghost: GuideRect? = nil, estimatedSteps: Int? = nil) {
        self.kind = kind; self.text = text; self.captureID = captureID; self.target = target
        self.action = action; self.outcome = outcome; self.matches = matches
        self.evidence = evidence; self.proposedGoal = proposedGoal; self.crop = crop
        self.mark = mark; self.label = label; self.detail = detail; self.value = value
        self.ghost = ghost; self.estimatedSteps = estimatedSteps
    }

    public enum Mark: String, Codable, Sendable, CaseIterable {
        case circle, underline, highlight, arrow, value
    }

    /// Label drawn at the mark: the model's label, else the first words of the text.
    public var markLabel: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return text.split(whereSeparator: \.isWhitespace).count > 6 ? words + "…" : words
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
        let normalized = result.normalized()
        try normalized.validate()
        return normalized
    }

    /// Models fill every schema key and often echo evidence or a capture onto prose. Fields a kind never
    /// uses are dropped instead of failing the reply; dropping cannot grant a target, action or verdict.
    public func normalized() -> Self {
        switch kind {
        case .explanation where captureID != nil && target?.isValid == true:
            // "Where is X" answered as prose with a located target: draw it instead of dropping it.
            return Self(kind: .annotation, text: text, captureID: captureID, target: target,
                        mark: cleanMark, label: cleanLabel, value: cleanValue)
        case .explanation, .clarification, .task_proposal:
            return Self(kind: kind, text: text, captureID: captureID,
                        proposedGoal: kind == .task_proposal ? proposedGoal : nil)
        case .context_request:
            return Self(kind: kind, text: text, captureID: captureID, crop: crop)
        case .annotation:
            return Self(kind: kind, text: text, captureID: captureID, target: target,
                        mark: cleanMark, label: cleanLabel, value: cleanValue)
        case .guide_step:
            return Self(kind: kind, text: text, captureID: captureID, target: target, action: action, outcome: outcome,
                        mark: cleanMark, label: cleanLabel, detail: cleanDetail, value: cleanValue,
                        ghost: ghost?.isValid == true ? ghost : nil,
                        estimatedSteps: estimatedSteps.flatMap { (1...50).contains($0) ? $0 : nil })
        case .verification_result, .task_completed:
            return Self(kind: kind, text: text, captureID: captureID, matches: matches, evidence: evidence)
        }
    }

    // Presentation extras only decorate a mark; a malformed one is dropped or trimmed instead of failing the turn.
    private var cleanValue: String? {
        guard let value, !value.isEmpty, value.utf8.count <= 200 else { return nil }
        return value
    }
    private var cleanMark: Mark? { mark == .value && cleanValue == nil ? .circle : mark }
    private var cleanLabel: String? { label.map { Self.trimmed($0, bytes: 60) }.flatMap { $0.isEmpty ? nil : $0 } }
    private var cleanDetail: String? { detail.map { Self.trimmed($0, bytes: 600) }.flatMap { $0.isEmpty ? nil : $0 } }
    private static func trimmed(_ text: String, bytes: Int) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.utf8.count > bytes { result.removeLast() }
        return result
    }

    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
              target?.isValid != false, crop?.isValid != false else { throw invalid }
        let hasStepFields = target != nil || action != nil || outcome != nil
        let hasMarkFields = mark != nil || label != nil || value != nil
        guard (label?.utf8.count ?? 0) <= 60, (value?.utf8.count ?? 0) <= 200, (detail?.utf8.count ?? 0) <= 600,
              ghost?.isValid != false, mark != .value || value?.isEmpty == false else { throw invalid }
        if kind != .guide_step { guard detail == nil, ghost == nil, estimatedSteps == nil else { throw invalid } }
        if kind != .guide_step && kind != .annotation { guard !hasMarkFields else { throw invalid } }
        if let estimatedSteps { guard (1...50).contains(estimatedSteps) else { throw invalid } }
        let hasVerdictFields = matches != nil || evidence != nil
        switch kind {
        case .context_request:
            guard !hasStepFields, !hasVerdictFields, proposedGoal == nil else { throw invalid }
        case .guide_step:
            guard !hasVerdictFields, proposedGoal == nil, crop == nil, text.utf8.count <= 600 else { throw invalid }
        case .annotation:
            // captureID is optional: the host maps the target against its latest capture and rejects stale ones.
            guard target != nil, action == nil, outcome == nil, !hasVerdictFields,
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
        if target != nil, kind != .annotation { guard captureID != nil else { throw invalid } }
    }

    private var invalid: AskError { .protocolFailure("The agent returned an invalid \(kind.rawValue). Retry with fresh context.") }
}
