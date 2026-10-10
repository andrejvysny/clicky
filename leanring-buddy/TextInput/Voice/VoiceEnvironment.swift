import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Whether speech models may be used for a new recording right now.
enum VoiceSpeechAdmission: Equatable {
    case ready
    /// Policy is Load when needed: record now, load while recording (audio is buffered locally from the first sample).
    case loadAutomatically
    /// Manual policy and not loaded: show a Load button instead of recording into a pipeline that cannot run.
    case needsExplicitLoad
    case unavailable(String)
}

/// Recognition and optional cleanup, bound to the models loaded at the moment a recording stops.
struct VoiceStages: Sendable {
    var transcribe: @Sendable ([Int16]) async throws -> String
    /// nil when cleanup is not possible (no cleanup model loaded); the controller treats that as a failed cleanup.
    var cleanup: @Sendable (String) async throws -> String?
}

/// The recorder as the controller sees it; `VoiceAudioRecorder` is adapted to it in the app.
@MainActor
protocol VoiceRecording: AnyObject {
    var onInterrupted: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onLimitReached: (() -> Void)? { get set }
    var deviceName: String { get }
    func start(deviceUID: String?, maximumSamples: Int) throws
    /// Ends capture now (main actor); the returned value collects the audio off the main actor.
    func stop() -> StoppedRecording
    func cancel()
}

/// Native effects voice input depends on. The app uses `.live(runtime:)`; tests inject fakes and drive the same controller.
struct VoiceEnvironment {
    var microphonePermission: () -> MicrophonePermission
    /// Only ever called from an explicit shortcut press.
    var requestMicrophone: () async -> Bool
    var inputDevices: () -> [VoiceInputDevice]
    var makeRecorder: () -> any VoiceRecording
    var keyIsDown: (_ keyCode: UInt32) -> Bool
    /// No command, option, shift or control key is held.
    var modifiersReleased: () -> Bool
    var frontmostProcess: () -> Int32?
    var speechAdmission: (_ withCleanup: Bool) -> VoiceSpeechAdmission
    var loadSpeech: (_ withCleanup: Bool) async throws -> Void
    var makeStages: (_ withCleanup: Bool) throws -> VoiceStages
    /// Monotonic seconds.
    var now: () -> TimeInterval
    /// Repeating main-actor callback; the returned closure cancels it.
    var repeatEvery: (_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
    var sleep: (_ seconds: TimeInterval) async -> Void
}

/// What the Quick Ask card shows about a voice session started from it: one line, never any transcript.
struct VoiceAskStatus: Equatable {
    var line: String
    var canStop: Bool
}

/// Quick Ask as the voice controller needs it.
@MainActor
protocol VoiceAskHost: AnyObject {
    func insertVoiceDraft(_ text: String, raw: String, concerns: [CleanupConcern], cleanupFailed: Bool)
    func setVoiceStatus(_ status: VoiceAskStatus?)
    var onVoiceStop: (() -> Void)? { get set }
    var onVoiceCancel: (() -> Void)? { get set }
}

@MainActor
protocol VoiceQuickAskPresenting: AnyObject {
    var isShowing: Bool { get }
    func showQuickAsk()
}
