import Foundation

nonisolated public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex, preview

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .preview: return "Local preview (no AI)"
        }
    }
}

nonisolated public struct AgentSession: Codable, Equatable, Sendable {
    public let provider: AgentProvider
    public let identifier: String
    public let workingDirectory: String

    public init(provider: AgentProvider, identifier: String, workingDirectory: String) {
        self.provider = provider
        self.identifier = identifier
        self.workingDirectory = workingDirectory
    }
}

nonisolated public struct AskRequest: Sendable {
    public let identifier: UUID
    public let text: String
    public let workingDirectory: String
    public let session: AgentSession?
    public let image: PNGImageAttachment?

    public init(text: String, workingDirectory: String, session: AgentSession? = nil, image: PNGImageAttachment? = nil, identifier: UUID = UUID()) {
        self.identifier = identifier
        self.text = text
        self.workingDirectory = workingDirectory
        self.session = session
        self.image = image
    }
}

nonisolated public enum AgentEvent: Equatable, Sendable {
    case session(AgentSession)
    case textDelta(String)
    case status(String)
    case completed
}

nonisolated public enum AskError: Error, LocalizedError, Equatable {
    case emptyPrompt, promptTooLarge, busy, missingExecutable(String), invalidDirectory
    case protocolFailure(String), authenticationRequired, processFailed(Int32), incompleteTurn

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Enter a question first."
        case .promptTooLarge: return "This prompt exceeds the 64 KiB limit. Shorten it and try again."
        case .busy: return "Wait for the current reply or stop it before sending another question."
        case .missingExecutable(let name): return "Choose your installed \(name) executable in Settings."
        case .invalidDirectory: return "Choose an existing project folder in Settings."
        case .authenticationRequired: return "Sign in using the official agent CLI, then retry."
        case .protocolFailure(let message): return message
        case .processFailed(let status): return "The agent exited with status \(status). Check its sign-in and configuration in your terminal."
        case .incompleteTurn: return "The agent disconnected before completing the reply. Your question is available to retry."
        }
    }
}

nonisolated public struct AskInputState: Sendable {
    public private(set) var activeRequest: UUID?
    public private(set) var response = ""
    public private(set) var recoveryDraft = ""
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func begin(text: String, identifier: UUID) throws -> UInt64 {
        guard activeRequest == nil else { throw AskError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.emptyPrompt }
        guard text.utf8.count <= 65_536 else { throw AskError.promptTooLarge }
        generation &+= 1
        activeRequest = identifier
        recoveryDraft = text
        response = ""
        return generation
    }

    @discardableResult
    public mutating func append(_ delta: String, identifier: UUID, generation expectedGeneration: UInt64) -> Bool {
        guard activeRequest == identifier, generation == expectedGeneration else { return false }
        response += delta
        return true
    }

    public mutating func finish(identifier: UUID, generation expectedGeneration: UInt64, succeeded: Bool) {
        guard activeRequest == identifier, generation == expectedGeneration else { return }
        activeRequest = nil
        if succeeded { recoveryDraft = "" }
    }

    public mutating func cancel() {
        generation &+= 1
        activeRequest = nil
    }
}

nonisolated public enum ScreenInclusionPreference: String, Codable, CaseIterable, Sendable {
    case off, askEachTime, always

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .askEachTime: return "Confirm per task"
        case .always: return "Task window"
        }
    }

    public var startsIncluded: Bool { self == .always }
    public var isAvailable: Bool { self != .off }
}

nonisolated public enum SpeechReplyPreference: String, Codable, CaseIterable, Sendable {
    case never, voiceOnly, always

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .voiceOnly: return "Voice requests only"
        case .always: return "Always"
        }
    }

    public func shouldSpeak(voiceInitiated: Bool, dictation: Bool) -> Bool {
        guard !dictation else { return false }
        return self == .always || (self == .voiceOnly && voiceInitiated)
    }
}
