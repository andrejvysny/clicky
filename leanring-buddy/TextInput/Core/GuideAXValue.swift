import Foundation

/// Typed comparison for a scoped AX outcome value. Strings compare exactly; numeric and Boolean controls
/// (checkbox, switch, slider, stepper) compare numerically, with on/off, true/false and checked/unchecked
/// naming 1/0. Anything else is undecidable, so verification falls back to fresh vision instead of guessing.
nonisolated public enum GuideAXValue {
    public static func matches(expected: String, string: String?, number: Double?) -> Bool? {
        guard expected.utf8.count <= 4096 else { return nil }
        if let string { return string.utf8.count <= 4096 ? string == expected : nil }
        guard let number, number.isFinite else { return nil }
        let wanted = expected.trimmingCharacters(in: .whitespaces).lowercased()
        switch wanted {
        case "on", "true", "checked", "yes", "selected": return number == 1
        case "off", "false", "unchecked", "no", "deselected": return number == 0
        default:
            guard let value = Double(wanted), value.isFinite else { return nil }
            return abs(value - number) < 1e-9
        }
    }
}
