import Foundation

public struct ClickyCapabilities: Sendable {
    public let typedAsk = true
    public let managedSessions = true
    public let liveTerminalAttachment = false
    public let localTranscription = false
    public let dictationInsertion = false
    public let screenAttachments = false
    public let visualMCP = false
    public let verifiedGuidance = false
    public init() {}
}

public enum InputMode: String, Codable, Sendable { case ask, dictate }
public enum TranscriptionCleanup: String, Codable, Sendable { case smart, verbatim }

public protocol LocalTranscriptionProvider: Sendable {
    func transcribe(audioURL: URL, cleanup: TranscriptionCleanup) async throws -> String
}

public struct ScreenContextIdentity: Codable, Equatable, Sendable {
    public let applicationIdentifier: String
    public let windowIdentifier: UInt32
    public let displayIdentifier: UInt32
    public let capturedAt: Date

    public init(applicationIdentifier: String, windowIdentifier: UInt32, displayIdentifier: UInt32, capturedAt: Date) {
        self.applicationIdentifier = applicationIdentifier
        self.windowIdentifier = windowIdentifier
        self.displayIdentifier = displayIdentifier
        self.capturedAt = capturedAt
    }
}

public enum GuidancePhase: String, Codable, Sendable {
    case created, locating, showing, waiting, verifying, completed, uncertain, canceled
}

public struct GuidedStep: Codable, Equatable, Sendable {
    public let identifier: UUID
    public let instruction: String
    public let expectedAction: String
    public let context: ScreenContextIdentity
}
