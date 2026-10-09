import Foundation

nonisolated enum GuideSchemaValidation {
    static func validate(_ value: JSONValue, schema: JSONValue) -> Bool {
        issue(value, schema: schema) == nil
    }

    /// Paths come only from schema keys; rejected values and unknown keys never enter diagnostics.
    static func issue(_ value: JSONValue, schema: JSONValue, path: String = "$") -> GuideValidationIssue? {
        if !schema["anyOf"].array.isEmpty {
            let branches = schema["anyOf"].array
            if branches.contains(where: { validate(value, schema: $0) }) { return nil }
            let matching = branches.first { branch in
                value["kind"].string != nil && branch["properties"]["kind"]["enum"].array.contains(value["kind"])
            } ?? branches.first { types($0).contains(where: { matches(value, type: $0) }) }
            return matching.flatMap { issue(value, schema: $0, path: path) }
                ?? GuideValidationIssue(code: .wrongType, path: path)
        }
        guard types(schema).contains(where: { matches(value, type: $0) }) else {
            return GuideValidationIssue(code: .wrongType, path: path)
        }
        if !schema["enum"].array.isEmpty, !schema["enum"].array.contains(value) {
            return GuideValidationIssue(code: .unknownEnum, path: path)
        }
        if let string = value.string {
            if schema["format"].string == "uuid", UUID(uuidString: string) == nil {
                return GuideValidationIssue(code: .invalidUUID, path: path)
            }
            if let pattern = schema["pattern"].string, string.range(of: pattern, options: .regularExpression) == nil {
                return GuideValidationIssue(code: .emptyText, path: path)
            }
        }
        if case .object(let object) = value, case .object(let properties) = schema["properties"] {
            let required = Set(schema["required"].array.compactMap(\.string))
            if let missing = required.subtracting(object.keys).sorted().first {
                return GuideValidationIssue(code: .missingField, path: path + "." + missing)
            }
            guard Set(object.keys).isSubset(of: Set(properties.keys)) else {
                return GuideValidationIssue(code: .unexpectedField, path: path)
            }
            for key in properties.keys.sorted() {
                if let child = object[key], let fieldSchema = properties[key],
                   let issue = issue(child, schema: fieldSchema, path: path + "." + key) { return issue }
            }
        }
        return nil
    }
    private static func types(_ schema: JSONValue) -> [String] {
        schema["type"].string.map { [$0] } ?? schema["type"].array.compactMap(\.string)
    }
    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("string", .string), ("boolean", .bool), ("object", .object): return true
        case ("number", .number(let number)): return number.isFinite
        case ("integer", .number(let number)): return number.isFinite && number.rounded() == number
        default: return false
        }
    }
}

nonisolated struct GuideValidationIssue: Equatable, Sendable {
    enum Code: String, Sendable {
        case outputTooLarge = "output_too_large", invalidJSON = "invalid_json"
        case wrongType = "wrong_type", missingField = "missing_field", unexpectedField = "unexpected_field"
        case unknownEnum = "unknown_enum", invalidUUID = "invalid_uuid", invalidNumber = "invalid_number"
        case emptyText = "empty_text", textTooLong = "text_too_long", invalidRect = "invalid_rect"
        case forbiddenField = "forbidden_field", invalidAction = "invalid_action", missingEvidence = "missing_evidence"
    }
    let code: Code
    let path: String
    func error(kind: GuidePresentation.Kind? = nil) -> AskError {
        .protocolFailure("The agent returned an invalid \(kind?.rawValue ?? "presentation") (\(code.rawValue) at \(path)). Retry with fresh context.")
    }
}
