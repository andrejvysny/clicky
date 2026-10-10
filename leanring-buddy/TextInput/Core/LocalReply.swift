import Foundation

/// Turns a local model's free-form output into the strict `{"presentation": …}` reply the shared parser accepts.
/// Local models have no schema-constrained decoding, so the host does the deterministic bookkeeping a schema
/// would: it extracts the JSON object, converts model-native 0–1000 boxes to pixels of the image it sent,
/// supplies the captureID of that image, nulls unused optional fields and drops fields the kind never uses.
/// None of this can grant a target, action or verdict: a missing mandatory field still fails validation.
nonisolated public enum LocalReply {
    static let rectFields = ["target", "crop", "ghost", "evidenceTarget"]

    /// The image the model saw this request, so boxes and the captureID refer to exactly that capture.
    public struct ImageFrame: Equatable, Sendable {
        public let captureID: UUID?
        public let pixelWidth: Int
        public let pixelHeight: Int
        public init(captureID: UUID?, pixelWidth: Int, pixelHeight: Int) {
            self.captureID = captureID; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        }
    }

    public static func presentation(from output: String, purpose: GuideRequestPurpose, frame: ImageFrame?) throws -> GuidePresentation {
        try GuidePresentation.parseResponse(normalizedData(from: output, frame: frame, purpose: purpose), purpose: purpose)
    }

    /// Kinds that only make sense against a capture the model has seen.
    static let screenKinds: Set<GuidePresentation.Kind> = [.annotation, .guide_step, .verification_result, .task_completed]

    static func normalizedData(from output: String, frame: ImageFrame?, purpose: GuideRequestPurpose? = nil) throws -> Data {
        guard let json = firstObject(in: output), let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            throw GuideValidationIssue(code: .invalidJSON, path: "$").error()
        }
        var fields: [String: JSONValue]
        if case .object(let wrapper) = root["presentation"] { fields = wrapper }
        else if case .object(let bare) = root, bare["kind"] != nil { fields = bare }
        else { throw GuideValidationIssue(code: .missingField, path: "$.presentation").error() }
        if let kindName = fields["kind"]?.string, let kind = GuidePresentation.Kind(rawValue: kindName) {
            if frame?.captureID == nil, screenKinds.contains(kind), purpose?.permits(.context_request) == true {
                // Small models answer "where is"/"help me" blind, copying example boxes. Without a capture that
                // reply can only be a guess, so it becomes the request for the screen the model should have made.
                fields = ["kind": .string("context_request"), "text": .string("I need to see the screen.")]
                fields = normalize(fields, kind: .context_request, frame: nil)
            } else {
                fields = normalize(fields, kind: kind, frame: frame)
            }
        }
        return try JSONEncoder().encode(JSONValue.object(["presentation": .object(fields)]))
    }

    static func normalize(_ input: [String: JSONValue], kind: GuidePresentation.Kind, frame: ImageFrame?) -> [String: JSONValue] {
        guard case .object(let properties) = GuideContract.variantSchema(for: kind)["properties"] else { return input }
        let allowed = Set(properties.keys)
        var fields = input.filter { allowed.contains($0.key) }
        for key in rectFields where fields[key] != nil {
            if let frame, let rect = pixelRect(fields[key]!, frame: frame) { fields[key] = rect }
        }
        if allowed.contains("captureID") {
            // The model only ever sees the latest capture, so the only captureID it can mean is that image's.
            fields["captureID"] = frame?.captureID.map { .string($0.uuidString) } ?? fields["captureID"] ?? .null
        }
        if kind == .annotation {
            if fields["mark"] == nil || fields["mark"] == .null { fields["mark"] = .string("circle") }
            // A pointing reply's label is already user-facing text; reuse it rather than fail the whole reply.
            if fields["text"]?.string?.isEmpty ?? true, let label = fields["label"]?.string, !label.isEmpty { fields["text"] = .string(label) }
            if fields["label"]?.string?.isEmpty ?? true, let text = fields["text"]?.string {
                fields["label"] = .string(text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
            }
        }
        if kind == .guide_step {
            fields["action"] = fields["action"].map(normalizeAction)
            fields["outcome"] = fields["outcome"].map(normalizeOutcome)
            if fields["plan"] == nil || fields["plan"] == .null, let milestone = fields["milestone"], milestone.string != nil {
                fields["plan"] = .array([milestone])
            }
        }
        for key in allowed where fields[key] == nil { fields[key] = .null }
        return fields
    }

    /// `[x1, y1, x2, y2]` on the 0–1000 grid becomes `{x, y, width, height}` in pixels of the sent image.
    /// Anything else is left as is, so a malformed box still fails validation instead of being guessed.
    static func pixelRect(_ value: JSONValue, frame: ImageFrame) -> JSONValue? {
        let raw: [JSONValue]
        if case .array(let values) = value { raw = values }
        else if case .array(let values) = value["bbox_2d"] { raw = values }
        else { return nil }
        let numbers = raw.compactMap(\.number)
        let grid = LocalGrounding.gridSize
        guard raw.count == 4, numbers.count == 4, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= grid * 1.02 }),
              numbers[0] < numbers[2], numbers[1] < numbers[3], frame.pixelWidth > 0, frame.pixelHeight > 0 else { return nil }
        let scaleX = Double(frame.pixelWidth) / grid, scaleY = Double(frame.pixelHeight) / grid
        let x1 = min(numbers[0], grid) * scaleX, y1 = min(numbers[1], grid) * scaleY
        let x2 = min(numbers[2], grid) * scaleX, y2 = min(numbers[3], grid) * scaleY
        guard x2 > x1, y2 > y1 else { return nil }
        return .object(["x": .number(x1), "y": .number(y1), "width": .number(x2 - x1), "height": .number(y2 - y1)])
    }

    /// Spellings small models use for the same gesture; anything else stays as is and fails validation.
    static let actionSynonyms = ["left_click": "click", "tap": "click", "press": "click", "single_click": "click",
                                 "rightclick": "right_click", "secondary_click": "right_click",
                                 "doubleclick": "double_click", "double-click": "double_click", "keypress": "key", "key_press": "key"]

    private static func normalizeAction(_ value: JSONValue) -> JSONValue {
        if let kind = value.string { return normalizeAction(.object(["kind": .string(kind)])) }
        guard case .object(var action) = value else { return value }
        if let kind = action["kind"]?.string, let canonical = actionSynonyms[kind.lowercased()] { action["kind"] = .string(canonical) }
        let isKey = ["key", "field_commit"].contains(action["kind"]?.string ?? "")
        if isKey {
            if action["modifiers"] == nil || action["modifiers"] == .null, action["keyCode"]?.integer != nil { action["modifiers"] = .number(0) }
        } else {
            for key in ["keyCode", "modifiers"] where action[key] == nil { action[key] = .null }
        }
        return .object(action)
    }

    private static func normalizeOutcome(_ value: JSONValue) -> JSONValue {
        if let description = value.string { return .object(["description": .string(description), "axRole": .null, "axTitle": .null, "axValue": .null]) }
        guard case .object(var outcome) = value else { return value }
        for key in ["axRole", "axTitle", "axValue"] where outcome[key] == nil { outcome[key] = .null }
        return .object(outcome)
    }

    /// The first balanced JSON object in `text`, skipping prose and Markdown fences around it.
    static func firstObject(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<scalars.count {
            let scalar = scalars[index]
            if inString {
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(String.UnicodeScalarView(scalars[start...index])) }
            default: break
            }
        }
        return nil
    }
}
