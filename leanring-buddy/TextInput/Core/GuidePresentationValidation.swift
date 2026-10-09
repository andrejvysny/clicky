import Foundation

nonisolated extension GuidePresentation {
    public func validate() throws {
        try requireText(text, field: "text", limit: kind == .writing_draft ? WritingPrompt.maximumDraftBytes : 16_384)
        for (field, rectangle) in [("target", target), ("crop", crop), ("ghost", ghost), ("evidenceTarget", evidenceTarget)] {
            if rectangle?.isValid == false { throw failure(.invalidRect, field) }
        }
        for (field, content, limit) in [("label", label, 60), ("value", value, 200), ("detail", detail, 600)] {
            if let content, content.utf8.count > limit { throw failure(.textTooLong, field) }
        }
        if mark == .value, value?.isEmpty != false { throw failure(.missingField, "value") }
        if let milestone, milestone.utf8.count > Self.milestoneBytes { throw failure(.textTooLong, "milestone") }
        if let warning, warning.utf8.count > Self.warningBytes { throw failure(.textTooLong, "warning") }
        if let plan, plan.count > Self.planLimit { throw failure(.textTooLong, "plan") }
        if let goalChecks, goalChecks.count > Self.goalCheckLimit { throw failure(.textTooLong, "goalChecks") }
        try validateFields()
        switch kind {
        case .guide_step: try validateStep()
        case .annotation:
            guard target != nil else { throw failure(.missingField, "target") }
            try requireText(text, field: "text", limit: 600)
        case .verification_result, .task_completed: try validateVerdict()
        case .task_proposal:
            guard let proposedGoal else { throw failure(.missingField, "proposedGoal") }
            try requireText(proposedGoal, field: "proposedGoal", limit: 16_384)
        default: break
        }
        if crop != nil, captureID == nil { throw failure(.missingField, "captureID") }
    }

    private func validateFields() throws {
        let fields: [(String, Bool, Bool)] = [
            ("target", target != nil, kind == .guide_step || kind == .annotation),
            ("action", action != nil, kind == .guide_step),
            ("outcome", outcome != nil, kind == .guide_step),
            ("crop", crop != nil, kind == .context_request),
            ("matches", matches != nil, kind == .verification_result || kind == .task_completed),
            ("evidence", evidence != nil, kind == .verification_result || kind == .task_completed),
            ("evidenceTarget", evidenceTarget != nil, kind == .verification_result || kind == .task_completed),
            ("proposedGoal", proposedGoal != nil, kind == .task_proposal),
            ("mark", mark != nil, kind == .guide_step || kind == .annotation),
            ("label", label != nil, kind == .guide_step || kind == .annotation),
            ("value", value != nil, kind == .guide_step || kind == .annotation),
            ("detail", detail != nil, kind == .guide_step),
            ("ghost", ghost != nil, kind == .guide_step),
            ("milestone", milestone != nil, kind == .guide_step),
            ("plan", plan != nil, kind == .guide_step),
            ("goalChecks", goalChecks != nil, kind == .guide_step),
            ("outcomeState", outcomeState != nil, kind == .verification_result),
            ("warning", warning != nil, kind == .guide_step),
            ("subject", subject != nil, kind == .writing_draft),
        ]
        if let invalid = fields.first(where: { $0.1 && !$0.2 }) { throw failure(.forbiddenField, invalid.0) }
    }

    private func validateStep() throws {
        try requireText(text, field: "text", limit: 600)
        guard captureID != nil else { throw failure(.missingField, "captureID") }
        guard target != nil else { throw failure(.missingField, "target") }
        guard let action else { throw failure(.missingField, "action") }
        guard let outcome else { throw failure(.missingField, "outcome") }
        try requireText(outcome.description, field: "outcome.description", limit: 16_384)
        if action.kind == .key || action.kind == .field_commit {
            guard let code = action.keyCode else { throw failure(.missingField, "action.keyCode") }
            guard let modifiers = action.modifiers else { throw failure(.missingField, "action.modifiers") }
            guard code < 128 else { throw failure(.invalidAction, "action.keyCode") }
            guard modifiers & ~UInt64(1_966_080) == 0 else { throw failure(.invalidAction, "action.modifiers") }
        } else {
            if action.keyCode != nil { throw failure(.forbiddenField, "action.keyCode") }
            if action.modifiers != nil { throw failure(.forbiddenField, "action.modifiers") }
        }
    }

    private func validateVerdict() throws {
        guard captureID != nil else { throw failure(.missingField, "captureID") }
        guard matches != nil else { throw failure(.missingField, "matches") }
        guard let evidence, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(.missingEvidence, "evidence")
        }
        try requireText(evidence, field: "evidence", limit: 16_384)
        guard evidenceTarget != nil else { throw failure(.missingField, "evidenceTarget") }
        // A positive verdict must be classified confirmed; an unclassified legacy verdict is never success.
        if kind == .verification_result, matches == true, outcomeState != .confirmed { throw failure(.invalidVerdict, "outcomeState") }
        if kind == .verification_result, matches == false, outcomeState == .confirmed { throw failure(.invalidVerdict, "outcomeState") }
    }

    private func requireText(_ value: String, field: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure(.emptyText, field) }
        guard value.utf8.count <= limit else { throw failure(.textTooLong, field) }
    }

    private func failure(_ code: GuideValidationIssue.Code, _ field: String) -> AskError {
        GuideValidationIssue(code: code, path: "$." + field).error(kind: kind)
    }
}
