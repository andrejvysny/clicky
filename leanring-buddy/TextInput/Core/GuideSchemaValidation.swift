import Foundation

nonisolated enum GuideSchemaValidation {
    static func validate(_ value: JSONValue, schema: JSONValue) -> Bool {
        if !schema["anyOf"].array.isEmpty {
            return schema["anyOf"].array.contains { validate(value, schema: $0) }
        }
        let types = schema["type"].string.map { [$0] } ?? schema["type"].array.compactMap(\.string)
        guard types.contains(where: { matches(value, type: $0) }) else { return false }
        if !schema["enum"].array.isEmpty, !schema["enum"].array.contains(value) { return false }
        if case .object(let object) = value, case .object(let properties) = schema["properties"] {
            let required = Set(schema["required"].array.compactMap(\.string))
            guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: Set(properties.keys)) else { return false }
            return object.allSatisfy { key, child in
                properties[key].map { validate(child, schema: $0) } ?? false
            }
        }
        return true
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
