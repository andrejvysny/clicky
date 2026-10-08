import Foundation
// Darwin Foundation does not re-export CGRect geometry members to this module.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Debug-only `clicky-debug://` request. Target is in global top-left Core Graphics points (CGWindow space).
nonisolated public enum GuidanceDebugRequest: Equatable {
    case show(target: CGRect, instruction: String, expected: GuidanceVerification.ExpectedAction)
    case cancel

    public static func parse(_ url: URL) throws -> GuidanceDebugRequest {
        guard url.scheme?.lowercased() == "clicky-debug" else { throw AskError.protocolFailure("Unsupported guidance request.") }
        switch url.host?.lowercased() {
        case "cancel": return .cancel
        case "guide": break
        default: throw AskError.protocolFailure("Unsupported guidance request.")
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AskError.protocolFailure("Missing guidance parameters.")
        }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        func number(_ name: String, _ range: ClosedRange<Double>) throws -> Double {
            guard let raw = value(name), let parsed = Double(raw), parsed.isFinite, range.contains(parsed) else {
                throw AskError.protocolFailure("Invalid or missing '\(name)'.")
            }
            return parsed
        }
        let rect = CGRect(x: try number("x", -20000...20000), y: try number("y", -20000...20000),
                          width: try number("w", 4...2000), height: try number("h", 4...2000))
        let text = (value("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(text.count) else { throw AskError.protocolFailure("'text' must be 1-200 characters.") }
        let expected: GuidanceVerification.ExpectedAction
        switch value("expect") {
        case "click": expected = .click(button: 0)
        case "rightclick": expected = .click(button: 1)
        case "key":
            guard let name = value("key"), let code = GuidanceKeyNames.keyCode(for: name) else {
                throw AskError.protocolFailure("Unknown or missing 'key'.")
            }
            var modifiers: UInt64 = 0
            for part in (value("mods") ?? "").split(separator: ",", omittingEmptySubsequences: true) {
                guard let bit = GuidanceKeyNames.modifierBits[part.trimmingCharacters(in: .whitespaces).lowercased()] else {
                    throw AskError.protocolFailure("Unknown modifier.")
                }
                modifiers |= bit
            }
            expected = .key(code: code, modifiers: modifiers)
        default: throw AskError.protocolFailure("'expect' must be click, rightclick or key.")
        }
        return .show(target: rect, instruction: text, expected: expected)
    }
}

nonisolated public enum GuidanceKeyNames {
    // Physical ANSI key positions (layout-independent): on QWERTZ the y/z labels differ from the position.
    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    public static func keyCode(for name: String) -> UInt16? { codes[name.lowercased()] }

    /// Literal NSEvent.ModifierFlags raw values; Core does not import AppKit.
    public static let modifierBits: [String: UInt64] = ["cmd": 1 << 20, "shift": 1 << 17, "opt": 1 << 19, "ctrl": 1 << 18]
}
