import Foundation

/// The host intents a writing request normalizes to. Natural language and slash commands share them;
/// providers only ever produce text for `draft` and `rewrite`, and `snippet` never reaches a provider.
nonisolated public enum WritingIntent: String, Codable, Sendable {
    case draft, rewrite, snippet
}

/// What kind of editable destination was bound before Quick Ask took focus.
nonisolated public enum WritingTargetKind: String, Codable, Sendable {
    /// A browser textarea/contenteditable or another AX text control, edited through controlled paste.
    case textField
    /// A VS Code document editor, edited through the opt-in bridge's versioned range edit.
    case vscodeEditor
    /// A shell prompt (macOS Terminal or VS Code's integrated terminal): insert-only, never executed.
    case terminal
}

/// A range in UTF-16 code units, the unit AX (CFRange over NSString) and VS Code offsets use.
nonisolated public struct UTF16Range: Codable, Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public var end: Int { location + length }
    public var isEmpty: Bool { length == 0 }

    public init?(location: Int, length: Int) {
        guard location >= 0, length >= 0, location <= Int.max - length else { return nil }
        self.location = location; self.length = length
    }

    public static func caret(_ location: Int) -> UTF16Range? { UTF16Range(location: location, length: 0) }

    /// The matching `String` range, or nil when out of bounds or when an edge splits a surrogate pair
    /// or would land inside a grapheme in a way Swift cannot represent.
    public func range(in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        guard end <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: location)
        let upper = utf16.index(lower, offsetBy: length)
        guard let start = lower.samePosition(in: text.unicodeScalars),
              let finish = upper.samePosition(in: text.unicodeScalars) else { return nil }
        return start..<finish
    }

    /// The range an insertion of `text` occupies when it replaces this range.
    public func replaced(by text: String) -> UTF16Range {
        UTF16Range(location: location, length: text.utf16.count)!
    }
}

/// An exact, untrimmed copy of the selected source, read only after an explicit editing request.
/// Distinct from `SelectionQuote`, which trims and truncates and therefore can never drive a replacement.
nonisolated public struct ExactSource: Equatable, Sendable {
    /// Larger selections must be narrowed before generation; replacing them from a truncated copy is forbidden.
    public static let maximumUTF16 = 32_768
    public let text: String
    public let range: UTF16Range

    public init(text: String, range: UTF16Range) throws {
        guard text.utf16.count == range.length else { throw WritingContractError.sourceMismatch }
        guard range.length <= Self.maximumUTF16 else { throw WritingContractError.sourceTooLarge }
        self.text = text; self.range = range
    }
}

nonisolated public enum WritingContractError: LocalizedError, Equatable, Sendable {
    case sourceMismatch, sourceTooLarge, draftTooLarge, emptyDraft

    public var errorDescription: String? {
        switch self {
        case .sourceMismatch: return "The selection changed while Clicky read it. Select the text again."
        case .sourceTooLarge: return "The selection is longer than \(ExactSource.maximumUTF16) characters. Select a shorter passage."
        case .draftTooLarge: return "The generated text exceeds Clicky's limit and was not used."
        case .emptyDraft: return "The provider returned no text."
        }
    }
}

/// Minimum identity and caret metadata bound before Quick Ask takes focus. It carries no field content.
nonisolated public struct TextTargetSnapshot: Equatable, Sendable {
    public let token: UUID
    public let kind: WritingTargetKind
    public let applicationName: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    /// Window Server number for AX targets, Terminal window id, or nil when the adapter has none.
    public let windowIdentifier: UInt32?
    /// Terminal tty / VS Code terminal process id, or the VS Code document URI. Opaque, memory-only.
    public let paneIdentity: String?
    /// The caret (empty) or selected range in the control.
    public let selection: UTF16Range
    /// Opaque content revision: character count plus an in-memory value fingerprint for AX fields, document
    /// version for VS Code, buffer length for macOS Terminal and the process id for VS Code terminals (which
    /// expose no input-buffer revision). Any change means the destination changed.
    public let contentRevision: String
    /// Nil when the destination accepts host edits; otherwise why it is preview-only.
    public let blockedReason: WritingBlockReason?
    /// Generic clipboard paste at the application's own cursor, like the user's ⌘V: no adapter can read the
    /// caret, selection or result back, so it never claims verified insertion and offers no Restore.
    public let pasteOnly: Bool

    public init(token: UUID = UUID(), kind: WritingTargetKind, applicationName: String, bundleIdentifier: String,
                processIdentifier: Int32, windowIdentifier: UInt32?, paneIdentity: String?, selection: UTF16Range,
                contentRevision: String, blockedReason: WritingBlockReason? = nil, pasteOnly: Bool = false) {
        self.token = token; self.kind = kind; self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier; self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier; self.paneIdentity = paneIdentity; self.selection = selection
        self.contentRevision = contentRevision; self.blockedReason = blockedReason; self.pasteOnly = pasteOnly
    }

    public var hasSelection: Bool { !selection.isEmpty }
    /// Whether a selection-based command may run: a known selection, or a paste-only app whose selection
    /// cannot be read in advance (Rewrite then copies it).
    public var mayHaveSelection: Bool { hasSelection || pasteOnly }

    /// Why a freshly read live snapshot no longer matches this binding, or nil when it is the same
    /// destination with the same caret/selection and content revision. Tokens are not compared.
    public func change(comparedWith live: TextTargetSnapshot?) -> WritingNotAppliedReason? {
        guard let live else { return .targetUnavailable }
        guard live.kind == kind, live.processIdentifier == processIdentifier, live.bundleIdentifier == bundleIdentifier,
              live.windowIdentifier == windowIdentifier, live.paneIdentity == paneIdentity else { return .targetChanged }
        guard live.selection == selection else { return .selectionChanged }
        guard live.contentRevision == contentRevision else { return .contentChanged }
        if let reason = live.blockedReason { return reason == .terminalNotReady ? .terminalNotReady : .targetUnavailable }
        return nil
    }
}

/// Why a result stays a preview instead of being applied.
nonisolated public enum WritingBlockReason: String, Codable, Equatable, Sendable {
    case noTarget, unsupportedTarget, readOnly, secureField, bridgeUnavailable, automationDenied
    case terminalNotReady, terminalMultiline, terminalControlCharacters
    case noSelection, previewBackend, emptyText
    case selectionInTerminalHistory
    case rewriteTargetChanged, snippetTerminalOnly, snippetEditorsOnly

    public var message: String {
        switch self {
        case .noTarget: return "No editable field was focused when Quick Ask opened. Copy the text instead."
        case .unsupportedTarget: return "Clicky cannot edit this application yet. Copy the text instead."
        case .readOnly: return "The focused text is read-only."
        case .secureField: return "Password fields are never edited."
        case .bridgeUnavailable: return "Install and enable the Clicky VS Code bridge to insert into VS Code."
        case .automationDenied: return "Allow Clicky to read Terminal's state in System Settings › Privacy & Security › Automation."
        case .terminalNotReady: return "The terminal is not at a ready shell prompt."
        case .terminalMultiline: return "Multiline text is not inserted into terminals. Review and copy it instead."
        case .terminalControlCharacters: return "The text contains tabs or control characters that a terminal could interpret."
        case .noSelection: return "Select the text to rewrite before opening Quick Ask."
        case .previewBackend: return "Local preview never edits other applications."
        case .emptyText: return "There is no text to insert."
        case .selectionInTerminalHistory: return "Terminal history is read-only; the rewrite stays a preview."
        case .rewriteTargetChanged: return "This rewrite belongs to the selection it was made from. Copy it, or select the text again."
        case .snippetTerminalOnly: return "This snippet inserts only into terminals."
        case .snippetEditorsOnly: return "This snippet inserts only into editors."
        }
    }
}

/// Where proposed text came from. Snippets never pass through a provider.
nonisolated public enum WritingProvenance: Equatable, Sendable {
    case generated(provider: AgentProvider, skillID: UUID?, skillRevision: UInt64?)
    case snippet(id: UUID, revision: UInt64)
    case preview
}

/// One immutable proposal revision. Editing the preview or refining creates a new revision.
nonisolated public struct WritingProposal: Equatable, Sendable {
    public let operationID: UUID
    public let revision: UInt64
    public let intent: WritingIntent
    public let text: String
    /// Optional email subject suggestion; shown separately and never inserted.
    public let subject: String?
    public let provenance: WritingProvenance
    /// The user changed the text in Clicky's preview after it was produced.
    public let edited: Bool

    public init(operationID: UUID, revision: UInt64, intent: WritingIntent, text: String, subject: String? = nil,
                provenance: WritingProvenance, edited: Bool = false) {
        self.operationID = operationID; self.revision = revision; self.intent = intent; self.text = text
        self.subject = subject; self.provenance = provenance; self.edited = edited
    }

    public func editing(_ newText: String) -> WritingProposal {
        WritingProposal(operationID: operationID, revision: revision + 1, intent: intent, text: newText,
                        subject: subject, provenance: provenance, edited: true)
    }
}

/// How the host may apply a proposal. Decided by the host from the bound target, never by a provider.
nonisolated public enum WritingApplyPlan: Equatable, Sendable {
    /// Insert at the unchanged original caret without another confirmation (Write and snippets).
    case automatic
    /// Show the preview; only an explicit Replace selection / Insert applies it.
    case review(replacesSelection: Bool)
    /// Show the preview with Copy; nothing is applied.
    case previewOnly(WritingBlockReason)

    public static func decide(intent: WritingIntent, target: TextTargetSnapshot?, text: String,
                              provenance: WritingProvenance) -> WritingApplyPlan {
        if provenance == .preview { return .previewOnly(.previewBackend) }
        guard let target else { return .previewOnly(.noTarget) }
        if let reason = target.blockedReason { return .previewOnly(reason) }
        if text.isEmpty { return .previewOnly(.emptyText) }
        if target.kind == .terminal {
            if intent == .rewrite { return .previewOnly(.selectionInTerminalHistory) }
            switch TerminalPayload.classify(text) {
            case .singleLine: break
            case .multiline: return .previewOnly(.terminalMultiline)
            case .unsafe: return .previewOnly(.terminalControlCharacters)
            }
            return .automatic
        }
        if target.pasteOnly {
            // Copy-and-paste semantics: a rewrite pastes over the selection it copied (undoable in the app with ⌘Z);
            // drafts and snippets paste at the cursor.
            return .automatic
        }
        switch intent {
        case .rewrite: return target.hasSelection ? .review(replacesSelection: true) : .previewOnly(.noSelection)
        case .draft, .snippet: return target.hasSelection ? .review(replacesSelection: true) : .automatic
        }
    }
}

/// A completed host edit, kept in memory so a guarded Restore original can undo exactly this edit.
nonisolated public struct WritingAppliedEdit: Equatable, Sendable {
    public let targetToken: UUID
    /// Where the inserted text now sits.
    public let insertedRange: UTF16Range
    public let insertedText: String
    /// The exact text that was replaced (empty for an insertion at a caret).
    public let replacedText: String
    /// Content revision the adapter observed right after the edit; restoring requires it unchanged.
    public let postRevision: String

    public init(targetToken: UUID, insertedRange: UTF16Range, insertedText: String, replacedText: String, postRevision: String) {
        self.targetToken = targetToken; self.insertedRange = insertedRange; self.insertedText = insertedText
        self.replacedText = replacedText; self.postRevision = postRevision
    }
}

nonisolated public enum WritingNotAppliedReason: String, Equatable, Sendable {
    case targetUnavailable, targetChanged, selectionChanged, contentChanged, sourceChanged, focusChanged
    case terminalNotReady, permissionDenied, clipboardUnavailable, keyStillHeld
    case canceled, superseded, alreadyApplied, definitionChanged, rejectedByTarget

    public var message: String {
        switch self {
        case .targetUnavailable: return "The original field is no longer available."
        case .targetChanged: return "You switched to a different window, tab or pane."
        case .selectionChanged: return "The caret or selection moved."
        case .contentChanged: return "The field's text changed."
        case .sourceChanged: return "The selected text changed."
        case .focusChanged: return "Focus moved away from the original field."
        case .terminalNotReady: return "The terminal is busy or not at a ready prompt."
        case .permissionDenied: return "Clicky lacks the permission needed to edit this field."
        case .clipboardUnavailable: return "The clipboard holds content Clicky cannot safely preserve."
        case .keyStillHeld: return "Return was still held down."
        case .canceled: return "Stopped."
        case .superseded: return "A newer request replaced this one."
        case .alreadyApplied: return "This text was already applied."
        case .definitionChanged: return "The snippet or skill changed after it was invoked."
        case .rejectedByTarget: return "The application refused the edit."
        }
    }
}

nonisolated public enum WritingApplyOutcome: Equatable, Sendable {
    /// The adapter read back the expected text at the expected range.
    case applied(WritingAppliedEdit)
    /// A documented insert-only API accepted the text but offers no read-back (VS Code integrated terminal).
    case acknowledged(WritingAppliedEdit)
    case notApplied(WritingNotAppliedReason)
    /// The write may or may not have happened. Never retried automatically and never followed by another strategy.
    case deliveryUnknown

    public var applied: WritingAppliedEdit? {
        switch self {
        case .applied(let edit), .acknowledged(let edit): return edit
        default: return nil
        }
    }
}

/// At-most-once host claims for applying a proposal revision. Duplicate buttons, Enter repeats and late
/// callbacks find the revision already claimed and do nothing.
nonisolated public struct WritingApplyClaims: Sendable {
    private var claimed: Set<String> = []
    public init() {}

    public mutating func claim(operationID: UUID, revision: UInt64) -> Bool {
        claimed.insert(operationID.uuidString + "#" + String(revision)).inserted
    }

    public func isClaimed(operationID: UUID, revision: UInt64) -> Bool {
        claimed.contains(operationID.uuidString + "#" + String(revision))
    }
}
