import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// What the Dictate review surface shows besides the editable text (which lives in the writing coordinator).
/// Holds the transcript only after recording ended.
struct DictationReview: Equatable {
    var raw: String
    var cleaned: String?
    var preferRaw: Bool
    var concerns: [String]
    var cleanupFailed: Bool
    var interrupted: Bool
    /// Automatic insertion was tried and the destination refused it.
    var attemptedAutomatically = false
    /// Latest message from the writing coordinator (why it was not inserted, or "Copied").
    var note: String?
    var canInsert = false

    /// One plain sentence on why nothing was inserted automatically.
    var headline: String {
        if attemptedAutomatically { return "Could not insert automatically — insert it yourself or copy it." }
        if interrupted { return "Recording was interrupted — check the text before inserting." }
        if cleanupFailed { return "Cleanup failed — the original transcript is shown." }
        if preferRaw { return "Cleanup changed the meaning — the original transcript is shown." }
        if !concerns.isEmpty { return "Cleanup changed something — check it before inserting." }
        return "Check the text before inserting."
    }

    var offersOriginal: Bool { cleaned != nil && cleaned != raw }
}

/// A dictation that reached its destination. Undo is offered only for a read-back-verified edit.
struct VoiceInsertedOutcome: Equatable {
    var message: String
    var canUndo: Bool
    var offersOriginal: Bool
}

/// The last dictation's transcript, in memory only, replaced by the next dictation.
struct VoiceDictationRecord: Equatable {
    var session: UUID
    var raw: String
    var cleaned: String?
}

enum VoicePhase: Equatable {
    case idle
    case needsSpeechModels(InputMode)
    case requestingPermission
    /// `level` is 0...1 input loudness; no audio or text is carried here.
    case recording(mode: InputMode, elapsed: Double, limit: Double, deviceName: String, level: Float)
    case transcribing(InputMode)
    case cleaning(InputMode)
    case inserting
    case inserted(VoiceInsertedOutcome)
    case review(DictationReview)
    case result(String)
    case failed(String)
}

extension CleanupConcern {
    var plainEnglish: String {
        switch self {
        case .emptyCleanup: return "Cleanup returned nothing."
        case .addedContent: return "Cleanup added words you did not say."
        case .unexplainedDeletion: return "Cleanup removed words without a clear reason."
        case .negationChanged: return "A \"not\", \"no\" or \"never\" changed."
        case .numberChanged: return "A number changed."
        case .nameRemoved: return "A name was removed."
        case .tooShort: return "Cleanup made the text much shorter."
        case .lowRecall: return "Cleanup rewrote most of the words."
        case .numberInCorrection: return "A number was part of a self-correction."
        case .nameInCorrection: return "A name was part of a self-correction."
        case .inputTooLong: return "The text is too long to check automatically."
        case .protectedRepetition: return "A repeated number or \"not\" was removed — it may have been intended."
        case .numberFormatChanged: return "A minus sign or decimal point changed."
        }
    }
}

enum VoiceText {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let deniedMessage = "Microphone access is off. Allow Clicky in System Settings › Privacy & Security › Microphone."
    static let allowedMessage = "Microphone allowed — press the shortcut again."
    static let noSpeechMessage = "No speech detected — nothing inserted"

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
