import Foundation

/// Classifies text before it is inserted at a shell prompt. The stored snippet or proposal is never trimmed,
/// flattened or rewritten here; anything that is not a single printable line stays a preview.
nonisolated public enum TerminalPayload {
    public enum Hazard: String, Equatable, Hashable, Sendable {
        /// CR, LF, NEL, U+2028/U+2029 or a trailing newline: the shell would run what precedes it.
        case lineBreak
        /// Tab becomes completion input at an unprotected prompt.
        case tab
        /// ESC, NUL, DEL or another C0/C1 control; includes embedded bracketed-paste terminators.
        case controlCharacter
        case bracketedPasteTerminator
        case empty
    }

    public enum Classification: Equatable, Sendable {
        case singleLine
        /// More than one line; insertion needs a demonstrated protected paste path, which v1 does not have.
        case multiline
        case unsafe(Set<Hazard>)
    }

    public static func hazards(in text: String) -> Set<Hazard> {
        var found: Set<Hazard> = []
        if text.isEmpty { found.insert(.empty) }
        if text.contains("\u{1B}[201~") || text.contains("\u{1B}[200~") { found.insert(.bracketedPasteTerminator) }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: found.insert(.lineBreak)
            case 0x09: found.insert(.tab)
            case 0x00...0x1F, 0x7F, 0x80...0x9F: found.insert(.controlCharacter)
            default: break
            }
        }
        return found
    }

    /// Single-line printable text inserts; line breaks alone mean multiline; any other hazard is unsafe.
    public static func classify(_ text: String) -> Classification {
        let found = hazards(in: text)
        if found.isEmpty { return .singleLine }
        if found == [.lineBreak] { return .multiline }
        return .unsafe(found)
    }

    /// Short, content-free explanation for Settings and the preview.
    public static func summary(_ hazards: Set<Hazard>) -> String {
        var parts: [String] = []
        if hazards.contains(.lineBreak) { parts.append("line breaks") }
        if hazards.contains(.tab) { parts.append("tabs") }
        if hazards.contains(.controlCharacter) || hazards.contains(.bracketedPasteTerminator) { parts.append("control characters") }
        if hazards.contains(.empty) { parts.append("no text") }
        return parts.isEmpty ? "Inserts at a ready terminal prompt" : "Terminal: preview only (" + parts.joined(separator: ", ") + ")"
    }
}

/// Marks Clicky's own synthetic paste/delete keystrokes so walkthrough observation never counts them as user input.
nonisolated public enum WritingSyntheticInput {
    public static let eventTag: Int64 = 0x434C_4B59
}
