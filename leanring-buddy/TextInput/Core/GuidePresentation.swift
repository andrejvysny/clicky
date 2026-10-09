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
    /// Image-pixel bounds of all visible evidence supporting a verification or completion verdict.
    public let evidenceTarget: GuideRect?
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
    /// Semantic milestone this step serves (intent, not coordinates), e.g. "Open Settings".
    public let milestone: String?
    /// Remaining semantic milestones in order, starting with this step's. Advisory; the host owns progress.
    public let plan: [String]?
    /// Independently checkable final-goal conditions. The host freezes the first nonempty set for the task.
    public let goalChecks: [String]?
    /// Verification only: confirmed, contradicted, still processing, or unknown.
    public let outcomeState: OutcomeState?
    /// Step only: short consequence of a destructive or externally committing action, shown beside the target.
    /// It grants nothing; the user's own click in the application is the confirmation.
    public let warning: String?

    public init(kind: Kind, text: String, captureID: UUID? = nil, target: GuideRect? = nil,
                action: GuideAction? = nil, outcome: GuideOutcome? = nil, matches: Bool? = nil,
                evidence: String? = nil, evidenceTarget: GuideRect? = nil, proposedGoal: String? = nil, crop: GuideRect? = nil,
                mark: Mark? = nil, label: String? = nil, detail: String? = nil, value: String? = nil,
                ghost: GuideRect? = nil, milestone: String? = nil, plan: [String]? = nil, goalChecks: [String]? = nil,
                outcomeState: OutcomeState? = nil, warning: String? = nil) {
        self.kind = kind; self.text = text; self.captureID = captureID; self.target = target
        self.action = action; self.outcome = outcome; self.matches = matches
        self.evidence = evidence; self.evidenceTarget = evidenceTarget; self.proposedGoal = proposedGoal; self.crop = crop
        self.mark = mark; self.label = label; self.detail = detail; self.value = value
        self.ghost = ghost; self.milestone = milestone; self.plan = plan; self.goalChecks = goalChecks
        self.outcomeState = outcomeState; self.warning = warning
    }

    public enum Mark: String, Codable, Sendable, CaseIterable {
        case circle, underline, highlight, arrow, value
    }

    /// A verdict's outcome classification. Only `confirmed` with `matches == true` can advance.
    public enum OutcomeState: String, Codable, Sendable, CaseIterable {
        case confirmed, contradicted, pending, unknown
    }

    /// Bounds shared by the schema, validation and normalization.
    public static let milestoneBytes = 80, planLimit = 8, goalCheckLimit = 6, goalCheckBytes = 200, warningBytes = 120

    /// The same step re-bound to a fresh capture after local revalidation; nothing else changes.
    public func rebound(captureID: UUID) -> Self {
        Self(kind: kind, text: text, captureID: captureID, target: target, action: action, outcome: outcome, matches: matches,
             evidence: evidence, evidenceTarget: evidenceTarget, proposedGoal: proposedGoal, crop: crop, mark: mark, label: label,
             detail: detail, value: value, ghost: ghost, milestone: milestone, plan: plan, goalChecks: goalChecks, outcomeState: outcomeState,
             warning: warning)
    }

    /// Label drawn at the mark: the model's label, else the first words of the text.
    public var markLabel: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return text.split(whereSeparator: \.isWhitespace).count > 6 ? words + "…" : words
    }

    static func parseResponse(_ data: Data, purpose: GuideRequestPurpose) throws -> Self {
        guard data.count <= 262_144 else { throw GuideValidationIssue(code: .outputTooLarge, path: "$").error() }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw GuideValidationIssue(code: .invalidJSON, path: "$").error()
        }
        guard case .object(let wrapper) = root else { throw GuideValidationIssue(code: .wrongType, path: "$").error() }
        guard let presentation = wrapper["presentation"] else {
            throw GuideValidationIssue(code: .missingField, path: "$.presentation").error()
        }
        guard wrapper.count == 1 else { throw GuideValidationIssue(code: .unexpectedField, path: "$").error() }
        guard case .object(let fields) = presentation else {
            throw GuideValidationIssue(code: .wrongType, path: "$.presentation").error()
        }
        guard let rawKind = fields["kind"]?.string, let kind = Kind(rawValue: rawKind) else {
            throw GuideValidationIssue(code: fields["kind"] == nil ? .missingField : .unknownEnum, path: "$.kind").error()
        }
        guard purpose.permits(kind) else {
            throw GuideWrongPurpose(kind: kind, purpose: purpose)
        }
        if let issue = GuideSchemaValidation.issue(presentation, schema: GuideContract.variantSchema(for: kind)) {
            throw issue.error(kind: kind)
        }
        guard case .object(let base) = GuideContract.schema["properties"] else { throw AskError.incompleteTurn }
        // Only unused fields become null; mandatory fields already passed the exact variant schema.
        let expanded = base.mapValues { _ in JSONValue.null }.merging(fields) { _, supplied in supplied }
        return try parse(JSONEncoder().encode(JSONValue.object(expanded)), purpose: purpose)
    }

    public static func parse(_ data: Data, purpose: GuideRequestPurpose? = nil) throws -> Self {
        guard data.count <= 262_144 else { throw GuideValidationIssue(code: .outputTooLarge, path: "$").error() }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw GuideValidationIssue(code: .invalidJSON, path: "$").error()
        }
        if let purpose, let rawKind = object["kind"].string, let kind = Kind(rawValue: rawKind), !purpose.permits(kind) {
            throw GuideWrongPurpose(kind: kind, purpose: purpose)
        }
        let schema = purpose.map(GuideContract.schema(for:)) ?? GuideContract.schema
        if let issue = GuideSchemaValidation.issue(object, schema: schema) { throw issue.error() }
        if let identifier = object["captureID"].string, UUID(uuidString: identifier) == nil {
            throw GuideValidationIssue(code: .invalidUUID, path: "$.captureID").error()
        }
        try validateNumbers(object)
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch {
            // Schema validation has already ruled out unknown keys; decoding failures here are bounded numbers.
            let path: String
            switch error {
            case DecodingError.dataCorrupted(let context), DecodingError.typeMismatch(_, let context),
                 DecodingError.valueNotFound(_, let context):
                path = "$" + context.codingPath.map { "." + $0.stringValue }.joined()
            default: path = "$"
            }
            throw GuideValidationIssue(code: .invalidNumber, path: path).error()
        }
        if result.evidenceTarget != nil, result.kind != .verification_result && result.kind != .task_completed {
            throw GuideValidationIssue(code: .forbiddenField, path: "$.evidenceTarget").error(kind: result.kind)
        }
        let normalized = result.normalized()
        try normalized.validate()
        return normalized
    }

    private static func validateNumbers(_ object: JSONValue) throws {
        let fields: [(JSONValue, Double, Double, String)] = [
            (object["action"]["keyCode"], 0, 65_536, "$.action.keyCode"),
            (object["action"]["modifiers"], 0, 18_446_744_073_709_551_616, "$.action.modifiers"),
        ]
        for (value, minimum, maximum, path) in fields {
            if case .number(let number) = value, number < minimum || number >= maximum {
                throw GuideValidationIssue(code: .invalidNumber, path: path).error()
            }
        }
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
                        ghost: ghost?.isValid == true ? ghost : nil, milestone: milestone.map { Self.trimmed($0, bytes: Self.milestoneBytes) },
                        plan: Self.cleanList(plan, limit: Self.planLimit, bytes: Self.milestoneBytes),
                        goalChecks: Self.cleanList(goalChecks, limit: Self.goalCheckLimit, bytes: Self.goalCheckBytes),
                        warning: warning.map { Self.trimmed($0, bytes: Self.warningBytes) }.flatMap { $0.isEmpty ? nil : $0 })
        case .verification_result:
            return Self(kind: kind, text: text, captureID: captureID, matches: matches, evidence: evidence,
                        evidenceTarget: evidenceTarget, outcomeState: outcomeState)
        case .task_completed:
            return Self(kind: kind, text: text, captureID: captureID, matches: matches, evidence: evidence,
                        evidenceTarget: evidenceTarget)
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
    /// Bounded, trimmed, nonempty entries; the schema already capped the count.
    private static func cleanList(_ list: [String]?, limit: Int, bytes: Int) -> [String]? {
        list.map { $0.prefix(limit).map { trimmed($0, bytes: bytes) }.filter { !$0.isEmpty } }
    }
    private static func trimmed(_ text: String, bytes: Int) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.utf8.count > bytes { result.removeLast() }
        return result
    }

}

/// The provider answered with a kind this turn's purpose does not allow. The session stays usable, so the host
/// may ask once more for an allowed kind; the presentation itself is never used.
nonisolated public struct GuideWrongPurpose: LocalizedError, Equatable, Sendable {
    public let kind: GuidePresentation.Kind
    public let purpose: GuideRequestPurpose
    public var errorDescription: String? {
        "The agent returned an invalid presentation (wrong_purpose at $.kind; kind=\(kind.rawValue), purpose=\(purpose.rawValue)). Retry explicitly with fresh context."
    }
}
