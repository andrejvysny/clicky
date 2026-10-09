import Foundation

nonisolated extension GuideContract {
    public static var responseSchema: JSONValue {
        responseSchema(kinds: [.context_request, .guide_step, .annotation, .explanation,
                              .clarification, .verification_result, .task_completed, .task_proposal])
    }

    public static func responseSchema(for purpose: GuideRequestPurpose) -> JSONValue {
        responseSchema(kinds: allowedKinds(for: purpose))
    }

    private static func responseSchema(kinds: [GuidePresentation.Kind]) -> JSONValue {
        // OpenAI disallows root anyOf. Compact variants also stay below Claude's 16 union-parameter limit.
        object(["presentation": .object(["anyOf": .array(kinds.map(variantSchema(for:)))])])
    }

    static func variantSchema(for kind: GuidePresentation.Kind) -> JSONValue {
        let source = schema["properties"]
        var properties: [String: JSONValue] = [
            "kind": .object(["type": .string("string"), "enum": .array([.string(kind.rawValue)])]),
            "text": nonempty(source["text"]),
        ]
        for field in variantFields(kind) { properties[field] = source[field] }
        switch kind {
        case .guide_step:
            properties["captureID"] = uuid
            properties["target"] = nonnullable(source["target"])
            properties["action"] = actionSchema
            var outcome = nonnullable(source["outcome"])
            if case .object(var fields) = outcome, case .object(var children) = fields["properties"] {
                children["description"] = nonempty(children["description"]!)
                fields["properties"] = .object(children); outcome = .object(fields)
            }
            properties["outcome"] = outcome
            properties["milestone"] = nonempty(nonnullable(source["milestone"]))
            properties["plan"] = .object(["type": .string("array"), "items": nonempty(.object(["type": .string("string")])),
                                          "description": source["plan"]["description"]])
            properties["goalChecks"] = .object(["type": .string("array"), "items": nonempty(.object(["type": .string("string")])),
                                                "description": source["goalChecks"]["description"]])
        case .annotation:
            properties["captureID"] = uuid
            properties["target"] = nonnullable(source["target"])
            properties["mark"] = nonnullable(source["mark"])
            properties["label"] = nonempty(nonnullable(source["label"]))
        case .verification_result, .task_completed:
            if kind == .verification_result { properties["outcomeState"] = nonnullable(source["outcomeState"]) }
            properties["captureID"] = uuid
            properties["matches"] = .object(["type": .string("boolean")])
            properties["evidence"] = nonempty(nonnullable(source["evidence"]))
            properties["evidenceTarget"] = nonnullable(source["evidenceTarget"])
        case .task_proposal: properties["proposedGoal"] = nonempty(nonnullable(source["proposedGoal"]))
        default: break
        }
        return object(properties)
    }

    private static func variantFields(_ kind: GuidePresentation.Kind) -> [String] {
        switch kind {
        case .context_request: return ["captureID", "crop"]
        case .guide_step: return ["captureID", "target", "action", "outcome", "mark", "label", "detail", "value", "ghost",
                                  "milestone", "plan", "goalChecks", "warning"]
        case .annotation: return ["captureID", "target", "mark", "label", "value"]
        case .verification_result, .task_completed: return ["captureID", "matches", "evidence", "evidenceTarget"]
        case .task_proposal: return ["proposedGoal"]
        case .writing_draft: return ["subject"]
        case .explanation, .clarification: return []
        }
    }

    private static var actionSchema: JSONValue {
        let mouse = object([
            "kind": .object(["type": .string("string"), "enum": .array(["click", "right_click", "double_click"].map(JSONValue.string))]),
            "keyCode": .object(["type": .string("null")]), "modifiers": .object(["type": .string("null")]),
        ])
        let key = object([
            "kind": .object(["type": .string("string"), "enum": .array(["key", "field_commit"].map(JSONValue.string))]),
            "keyCode": .object(["type": .string("integer")]), "modifiers": .object(["type": .string("integer")]),
        ])
        return .object(["anyOf": .array([mouse, key])])
    }

    private static var uuid: JSONValue {
        .object(["type": .string("string"), "format": .string("uuid"),
                 "description": .string("Exact capture.captureID supplied by the host; never fabricate.")])
    }

    private static func nonnullable(_ value: JSONValue) -> JSONValue {
        if let branch = value["anyOf"].array.first, case .object(var fields) = branch {
            if let description = value["description"].string { fields["description"] = .string(description) }
            return .object(fields)
        }
        guard case .object(var fields) = value else { return value }
        if !value["type"].array.isEmpty { fields["type"] = value["type"].array.first { $0 != .string("null") } }
        if !value["enum"].array.isEmpty { fields["enum"] = .array(value["enum"].array.filter { $0 != .null }) }
        return .object(fields)
    }

    private static func nonempty(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        fields["pattern"] = .string("[^\\s]")
        return .object(fields)
    }
}
