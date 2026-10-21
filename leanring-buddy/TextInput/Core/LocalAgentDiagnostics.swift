import Foundation

/// Content-free summaries of on-device guide turns for DEBUG logging: kinds, field presence, counts, sizes and
/// box comparisons only. Never prompts, reply text, labels, coordinates or image data.
nonisolated public enum LocalAgentDiagnostics {
    public typealias Sink = @Sendable (String) -> Void

    static let knownActions = Set(["click", "right_click", "double_click", "key", "field_commit"])
        .union(LocalReply.actionSynonyms.keys)

    /// Boxes printed in the system prompt's examples; a reply reusing one did not ground on the image.
    static let exampleBoxes: [[Double]] = LocalPrompt.guide.split(separator: "\n").flatMap { line in
        LocalReply.firstObject(in: String(line)).flatMap(presentation).map(boxes) ?? []
    }

    public static func request(purpose: GuideRequestPurpose, historyMessages: Int, sentMessages: Int, promptBytes: Int,
                               imageAttached: Bool, imageDropped: Bool, imageSide: Int?) -> String {
        "request purpose=\(purpose.rawValue) history=\(historyMessages) sent=\(sentMessages) "
            + "trimmed=\(max(0, historyMessages + 1 - (sentMessages - 1))) promptBytes=\(promptBytes) "
            + "image=\(imageAttached) imageDropped=\(imageDropped) side=\(imageSide.map(String.init) ?? "-")"
    }

    /// Summarizes one raw reply against the earlier assistant replies the model was shown.
    public static func reply(_ output: String, history: [LocalChatMessage], milliseconds: Int) -> String {
        var line = "reply bytes=\(output.utf8.count) ms=\(milliseconds)"
        guard let json = LocalReply.firstObject(in: output) else { return line + " json=none" }
        guard let fields = presentation(json) else { return line + " json=unparsed" }
        line += " kind=\(fields["kind"]?.string ?? "-") textBytes=\(fields["text"]?.string?.utf8.count ?? 0)"
        for key in LocalReply.rectFields { line += " \(key)=\(boxState(fields[key]))" }
        if case .object(let action) = fields["action"] ?? .null, let kind = action["kind"]?.string {
            line += " action=" + (knownActions.contains(kind.lowercased()) ? kind.lowercased() : "other")
        } else if let kind = fields["action"]?.string {
            line += " action=" + (knownActions.contains(kind.lowercased()) ? kind.lowercased() : "other") + "(bare)"
        }
        if case .object(let outcome) = fields["outcome"] ?? .null {
            let ax = ["axRole", "axTitle", "axValue"].filter { outcome[$0]?.string?.isEmpty == false }
            line += " outcomeAX=" + (ax.isEmpty ? "none" : ax.joined(separator: ","))
        }
        if let matches = fields["matches"], case .bool(let value) = matches { line += " matches=\(value)" }
        if let state = fields["outcomeState"]?.string { line += " outcomeState=\(state)" }
        if case .array(let plan) = fields["plan"] ?? .null { line += " plan=\(plan.count)" }
        line += comparison(fields, history: history)
        return line
    }

    /// Whether this reply's target repeats an earlier reply's or a prompt example, and how much it overlaps the
    /// previous step: a stateless small model often re-emits the last step instead of grounding the next one.
    static func comparison(_ fields: [String: JSONValue], history: [LocalChatMessage]) -> String {
        let earlier = history.filter { $0.role == .assistant }.compactMap { presentation($0.text) }
        var line = ""
        if let target = grid(fields["target"]) {
            line += " targetFromHistory=\(earlier.contains { boxes($0).contains(target) })"
            line += " targetFromExample=\(exampleBoxes.contains(target))"
            if let previous = earlier.last(where: { $0["kind"]?.string == "guide_step" }), let old = grid(previous["target"]) {
                line += " iouPreviousStep=" + String(format: "%.2f", intersectionOverUnion(target, old))
            }
        }
        if let milestone = fields["milestone"]?.string,
           let previous = earlier.last(where: { $0["kind"]?.string == "guide_step" })?["milestone"]?.string {
            line += " sameMilestone=\(milestone == previous)"
        }
        return line
    }

    static func presentation(_ json: String) -> [String: JSONValue]? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return nil }
        if case .object(let wrapped) = root["presentation"] { return wrapped }
        if case .object(let bare) = root, bare["kind"] != nil { return bare }
        return nil
    }

    static func boxes(_ fields: [String: JSONValue]) -> [[Double]] { LocalReply.rectFields.compactMap { grid(fields[$0]) } }

    static func grid(_ value: JSONValue?) -> [Double]? {
        guard let value else { return nil }
        let raw = value.array.isEmpty ? value["bbox_2d"].array : value.array
        let numbers = raw.compactMap(\.number)
        return raw.count == 4 && numbers.count == 4 ? numbers : nil
    }

    static func boxState(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "none" }
        guard let box = grid(value) else { return "object" == kindName(value) ? "pixels?" : "bad" }
        let inRange = box.allSatisfy { $0 >= 0 && $0 <= LocalGrounding.gridSize * 1.02 } && box[0] < box[2] && box[1] < box[3]
        return inRange ? "grid(\(Int(box[2] - box[0]))x\(Int(box[3] - box[1])))" : "outOfGrid"
    }

    private static func kindName(_ value: JSONValue) -> String {
        if case .object = value { return "object" }
        return "other"
    }

    static func intersectionOverUnion(_ a: [Double], _ b: [Double]) -> Double {
        let width = max(0, min(a[2], b[2]) - max(a[0], b[0])), height = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        let overlap = width * height
        let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - overlap
        return union > 0 ? overlap / union : 0
    }
}
