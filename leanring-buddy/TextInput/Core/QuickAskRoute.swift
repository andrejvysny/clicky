import Foundation

/// Where one explicit Quick Ask submission goes. Slash commands and natural language normalize to the
/// same host routes; command text is never forwarded to a provider as a native slash command.
nonisolated public enum QuickAskRoute: Equatable, Sendable {
    /// The existing conversation/guide path.
    case chat(String)
    case write(instruction: String, skill: CustomSkill?)
    case rewrite(instruction: String, skill: CustomSkill?)
    /// Exact saved text; resolved locally, never through a provider.
    case snippet(SavedSnippet)
    /// Handled locally with an explanation; nothing is sent.
    case localError(String)

    public static func route(draft: String, definitions: WritingDefinitions, hasSelection: Bool,
                             hasEditableTarget: Bool) -> QuickAskRoute {
        switch SlashParser.parse(draft) {
        case .literal(let text): return .chat(text)
        case .text(let text):
            switch WritingIntentClassifier.classify(text, hasSelection: hasSelection, hasEditableTarget: hasEditableTarget) {
            case .draft?: return .write(instruction: text, skill: nil)
            case .rewrite?: return .rewrite(instruction: text, skill: nil)
            default: return .chat(text)
            }
        case .command(let alias, let argument):
            let registry = SlashCommandRegistry(definitions: definitions, hasSelection: hasSelection)
            switch registry.lookup(alias) {
            case .unknown: return .localError("Unknown command /\(alias). Start with // to send it as text.")
            case .disabled(let name): return .localError("\(name) is disabled. Enable it in Settings › Writing.")
            case .command(let command):
                guard command.available else { return .localError(command.unavailableReason ?? "/\(alias) is unavailable here.") }
                return route(command, argument: argument, definitions: definitions)
            }
        }
    }

    private static func route(_ command: SlashCommand, argument: String, definitions: WritingDefinitions) -> QuickAskRoute {
        let detail = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.requiresArgument, detail.isEmpty {
            return .localError("Add \(command.argumentHint ?? "details") after /\(command.alias).")
        }
        switch command.kind {
        case .snippet:
            guard let snippet = definitions.snippets.first(where: { $0.id == command.snippetID }),
                  snippet.revision == command.snippetRevision else { return .localError(WritingNotAppliedReason.definitionChanged.message) }
            return .snippet(snippet)
        case .skill:
            guard let skill = (SlashCommandRegistry.builtInSkills + definitions.skills).first(where: { $0.id == command.skillID }) else {
                return .localError(WritingNotAppliedReason.definitionChanged.message)
            }
            let instruction = detail.isEmpty ? "Apply the skill." : argument
            return skill.operation == .rewrite ? .rewrite(instruction: instruction, skill: skill) : .write(instruction: instruction, skill: skill)
        case .action:
            switch command.action {
            case .write?: return .write(instruction: argument, skill: nil)
            case .rewrite?: return .rewrite(instruction: argument, skill: nil)
            case .fix?, .shorten?, .translate?:
                guard let instruction = WritingActionInstruction.instruction(for: command.alias, argument: argument) else {
                    return .localError("Add \(command.argumentHint ?? "details") after /\(command.alias).")
                }
                return .rewrite(instruction: instruction, skill: nil)
            case .explain?, .guide?: return .chat(argument)
            case nil: return .localError("/\(command.alias) is unavailable here.")
            }
        }
    }
}

/// Recognizes plainly worded writing requests. Only a leading imperative counts, and only with an editable
/// destination (and a selection for rewrites); everything else stays an ordinary question.
nonisolated public enum WritingIntentClassifier {
    static let draftVerbs: Set<String> = ["write", "draft", "compose", "napíš", "napis", "napíšte"]
    static let rewriteVerbs: Set<String> = ["rewrite", "rephrase", "reword", "shorten", "fix", "correct", "proofread", "translate",
                                            "improve", "polish", "simplify", "summarize", "prepíš", "prepis", "skráť", "oprav", "prelož", "uprav"]

    public static func classify(_ text: String, hasSelection: Bool, hasEditableTarget: Bool) -> WritingIntent? {
        guard hasEditableTarget else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" }).prefix(3).map { $0.lowercased() }
        guard let first = words.first else { return nil }
        if hasSelection, rewriteVerbs.contains(first) || (first == "make" && words.dropFirst().first.map { ["this", "it"].contains($0) } == true) {
            return .rewrite
        }
        if draftVerbs.contains(first) { return hasSelection && words.dropFirst().first.map { ["this", "it"].contains($0) } == true ? .rewrite : .draft }
        return nil
    }
}
