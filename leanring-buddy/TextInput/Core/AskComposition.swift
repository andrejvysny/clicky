import Foundation

/// Per-prompt reasoning effort. The composer resets to `.low` after every submission.
nonisolated public enum AskEffort: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    public var next: AskEffort {
        switch self {
        case .low: return .medium
        case .medium: return .high
        case .high: return .low
        }
    }
    public var displayName: String { rawValue.capitalized }
    /// Filled pips out of three.
    public var pipCount: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

/// Text that was selected in the frontmost app when Quick Ask opened, attached as a removable quote.
nonisolated public struct SelectionQuote: Equatable, Sendable {
    public static let maximumBytes = 16_384
    public let text: String
    public let applicationName: String
    public let truncated: Bool

    public init?(text raw: String, applicationName: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var kept = ""
        var bytes = 0
        for character in trimmed {
            let size = String(character).utf8.count
            if bytes + size > Self.maximumBytes { break }
            kept.append(character); bytes += size
        }
        text = kept
        truncated = kept.count < trimmed.count
        self.applicationName = applicationName
    }

    public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
}

/// A multi-line paste collapsed into a chip; the text is kept verbatim, including indentation.
nonisolated public struct PastedSnippet: Equatable, Identifiable, Sendable {
    public static let collapseLineCount = 6
    public static let collapseBytes = 600
    public let id = UUID()
    public let text: String

    public init(text: String) { self.text = text }

    public static func shouldCollapse(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines >= collapseLineCount || text.utf8.count >= collapseBytes
    }

    public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
    public var firstLine: String {
        text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

nonisolated public enum AskComposition {
    public static let explainSelectionPrompt = "Explain this selection."

    /// Builds the submitted message. Typed text comes first; quoted material follows in fences that cannot be closed by its content.
    public static func message(draft: String, selection: SelectionQuote?, snippets: [PastedSnippet]) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !typed.isEmpty { parts.append(draft) }
        else if selection != nil { parts.append(explainSelectionPrompt) }
        else if !snippets.isEmpty { parts.append("See the pasted text.") }
        if let selection {
            let note = selection.truncated ? " (truncated)" : ""
            parts.append("Selected text from " + selection.applicationName + note + ":\n" + fenced(selection.text))
        }
        for snippet in snippets { parts.append("Pasted text:\n" + fenced(snippet.text)) }
        return parts.joined(separator: "\n\n")
    }

    public static func hasContent(draft: String, selection: SelectionQuote?, snippets: [PastedSnippet]) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selection != nil || !snippets.isEmpty
    }

    static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + "\n" + fence
    }
}
