import Foundation

nonisolated public enum SlashCommandKind: String, Sendable {
    case action, skill, snippet
}

nonisolated public enum SlashAction: String, CaseIterable, Sendable {
    case write, rewrite, fix, shorten, translate, explain, guide
}

nonisolated public struct SlashCommand: Equatable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var title: String
    public var summary: String
    public var argumentHint: String?
    public var kind: SlashCommandKind
    public var action: SlashAction?
    public var skillID: UUID?
    public var skillRevision: UInt64?
    public var snippetID: UUID?
    public var snippetRevision: UInt64?
    public var requiresSelection: Bool
    public var requiresArgument: Bool
    public var available: Bool
    public var unavailableReason: String?

    public var badge: String {
        switch kind {
        case .action: return "Action"
        case .skill: return "AI skill"
        case .snippet: return "Snippet · No AI"
        }
    }
}

nonisolated public struct SlashCommandRegistry: Sendable {
    public static let needsSelectionReason = "Select text before opening Quick Ask"

    public static let builtInSkills: [CustomSkill] = [
        CustomSkill(id: UUID(uuidString: "7B1D5E10-0C4A-4F63-9A57-3E2C8D1A0001")!, revision: 1,
                    name: "Professional tone", alias: "professional", summary: "Rewrite in a professional tone",
                    instructions: "Rewrite the selected text in a clear, professional tone. Keep its meaning, facts, names, numbers and language.",
                    operation: .rewrite, enabled: true, builtIn: true),
        CustomSkill(id: UUID(uuidString: "7B1D5E10-0C4A-4F63-9A57-3E2C8D1A0002")!, revision: 1,
                    name: "Reply", alias: "reply", summary: "Draft a reply to the selected message",
                    instructions: "Draft a concise, friendly reply to the selected message. Do not invent commitments, dates or facts.",
                    operation: .draft, enabled: true, builtIn: true),
    ]

    public static let reservedAliases: Set<String> =
        Set(SlashAction.allCases.map(\.rawValue))
        .union(["skills", "snippets", "settings", "help", "clicky"])
        .union(builtInSkills.map(\.alias))

    private static let actionTable: [SlashAction: (title: String, summary: String, hint: String?, selection: Bool, argument: Bool)] = [
        .write: ("Write", "Draft new text at the caret", "what to write", false, true),
        .rewrite: ("Rewrite", "Rewrite the selected text", "how to change it", true, true),
        .fix: ("Fix", "Fix spelling and grammar in the selection", nil, true, false),
        .shorten: ("Shorten", "Make the selection shorter", nil, true, false),
        .translate: ("Translate", "Translate the selection", "language", true, true),
        .explain: ("Explain", "Ask about something", "question", false, true),
        .guide: ("Guide", "Walk me through a task", "goal", false, true),
    ]

    public let entries: [SlashCommand]
    private let disabledNames: [String: String]

    public init(definitions: WritingDefinitions, hasSelection: Bool) {
        var built: [SlashCommand] = []
        for action in SlashAction.allCases {
            let row = Self.actionTable[action]!
            built.append(Self.entry(alias: action.rawValue, title: row.title, summary: row.summary, hint: row.hint,
                                    kind: .action, requiresSelection: row.selection, requiresArgument: row.argument,
                                    hasSelection: hasSelection) { $0.action = action })
        }
        for skill in Self.builtInSkills + definitions.skills.filter(\.enabled) {
            built.append(Self.entry(alias: skill.alias, title: skill.name, summary: skill.summary, hint: "optional details",
                                    kind: .skill, requiresSelection: skill.operation == .rewrite, requiresArgument: false,
                                    hasSelection: hasSelection) { $0.skillID = skill.id; $0.skillRevision = skill.revision })
        }
        for snippet in definitions.snippets where snippet.enabled {
            let summary = snippet.summary.isEmpty ? Self.firstLine(of: snippet.body) : snippet.summary
            built.append(Self.entry(alias: snippet.alias, title: snippet.name, summary: summary, hint: nil,
                                    kind: .snippet, requiresSelection: false, requiresArgument: false,
                                    hasSelection: hasSelection) { $0.snippetID = snippet.id; $0.snippetRevision = snippet.revision })
        }
        entries = built
        var disabled: [String: String] = [:]
        for skill in definitions.skills where !skill.enabled { disabled[skill.alias] = skill.name }
        for snippet in definitions.snippets where !snippet.enabled { disabled[snippet.alias] = snippet.name }
        disabledNames = disabled
    }

    private static func entry(alias: String, title: String, summary: String, hint: String?, kind: SlashCommandKind,
                              requiresSelection: Bool, requiresArgument: Bool, hasSelection: Bool,
                              configure: (inout SlashCommand) -> Void) -> SlashCommand {
        let blocked = requiresSelection && !hasSelection
        var command = SlashCommand(alias: alias, title: title, summary: summary, argumentHint: hint, kind: kind,
                                   action: nil, skillID: nil, skillRevision: nil, snippetID: nil, snippetRevision: nil,
                                   requiresSelection: requiresSelection, requiresArgument: requiresArgument,
                                   available: !blocked, unavailableReason: blocked ? needsSelectionReason : nil)
        configure(&command)
        return command
    }

    private static func firstLine(of body: String) -> String {
        let line = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(60))
    }

    // MARK: Search

    public func suggestions(for query: String, limit: Int = 8) -> [SlashCommand] {
        guard limit > 0 else { return [] }
        let needle = query.lowercased()
        if needle.isEmpty { return Array(entries.prefix(limit)) }
        let folded = Self.fold(needle)
        var ranked: [(tier: Int, command: SlashCommand)] = []
        for command in entries {
            let tier: Int
            if command.alias == needle { tier = 0 }
            else if command.alias.hasPrefix(needle) { tier = 1 }
            else if command.alias.contains(needle) { tier = 2 }
            else if Self.fold(command.title).contains(folded) || Self.fold(command.summary).contains(folded) { tier = 3 }
            else { continue }
            ranked.append((tier, command))
        }
        ranked.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let lk = Self.kindOrder(lhs.command.kind), rk = Self.kindOrder(rhs.command.kind)
            if lk != rk { return lk < rk }
            return lhs.command.alias < rhs.command.alias
        }
        return ranked.prefix(limit).map(\.command)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func kindOrder(_ kind: SlashCommandKind) -> Int {
        switch kind {
        case .action: return 0
        case .skill: return 1
        case .snippet: return 2
        }
    }

    // MARK: Lookup

    public enum Lookup: Equatable, Sendable {
        case command(SlashCommand)
        case disabled(String)
        case unknown
    }

    public func lookup(_ alias: String) -> Lookup {
        if let command = entries.first(where: { $0.alias == alias }) { return .command(command) }
        if let name = disabledNames[alias] { return .disabled(name) }
        return .unknown
    }
}

nonisolated public enum SlashInput: Equatable, Sendable {
    case text(String)
    /// `//…` escape: the text to send, beginning with a single slash.
    case literal(String)
    case command(alias: String, argument: String)
}

nonisolated public enum SlashParser {
    /// Works on Unicode scalars so a combining mark after "/" cannot merge with it into one Character.
    public static func parse(_ draft: String) -> SlashInput {
        let scalars = Array(draft.unicodeScalars)
        guard scalars.first == "/" else { return .text(draft) }
        if scalars.count > 1, scalars[1] == "/" { return .literal(String(draft.unicodeScalars.dropFirst())) }
        var end = 1
        while end < scalars.count, !scalars[end].properties.isWhitespace { end += 1 }
        var token = String.UnicodeScalarView()
        token.append(contentsOf: scalars[1..<end])
        let alias = String(token)
        guard WritingDefinitions.isValidAlias(alias) else { return .text(draft) }
        guard end < scalars.count else { return .command(alias: alias, argument: "") }
        var restStart = end + 1
        if scalars[end] == "\r", restStart < scalars.count, scalars[restStart] == "\n" { restStart += 1 }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[restStart...])
        return .command(alias: alias, argument: String(rest))
    }
}

nonisolated public struct SlashPickerState: Equatable, Sendable {
    public enum PickerKey: Sendable { case up, down, tab, enter, escape }
    public enum KeyDecision: Equatable, Sendable {
        case complete(draft: String), submit, dismiss, moveHighlight, passThrough
    }

    public private(set) var highlighted: Int = 0
    private var lastQuery: String?
    private var dismissedQuery: String?

    public init() {}

    public static func query(draft: String, caretUTF16: Int, hasMarkedText: Bool) -> String? {
        guard !hasMarkedText, caretUTF16 == draft.utf16.count else { return nil }
        let scalars = draft.unicodeScalars
        guard scalars.first == "/", scalars.dropFirst().first != "/" else { return nil }
        let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
        let allowed = rest.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
        return allowed ? rest : nil
    }

    public mutating func update(query: String?, count: Int) {
        if query != lastQuery {
            highlighted = 0
            lastQuery = query
            if dismissedQuery != query { dismissedQuery = nil }
        }
        highlighted = count > 0 ? min(max(highlighted, 0), count - 1) : 0
    }

    public func isVisible(query: String?, count: Int) -> Bool {
        query != nil && count > 0 && dismissedQuery != query
    }

    public mutating func handle(_ key: PickerKey, query: String?, suggestions: [SlashCommand]) -> KeyDecision {
        guard isVisible(query: query, count: suggestions.count) else { return .passThrough }
        let count = suggestions.count
        highlighted = min(max(highlighted, 0), count - 1)
        let current = suggestions[highlighted]
        switch key {
        case .up:
            highlighted = (highlighted - 1 + count) % count
            return .moveHighlight
        case .down:
            highlighted = (highlighted + 1) % count
            return .moveHighlight
        case .tab:
            return .complete(draft: "/" + current.alias + " ")
        case .enter:
            return current.alias == query ? .submit : .complete(draft: "/" + current.alias + " ")
        case .escape:
            dismissedQuery = query
            return .dismiss
        }
    }
}
