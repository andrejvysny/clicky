import Carbon
import Combine
import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

struct VoiceShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Error carrying text that is already fit for the user.
struct VoiceMessageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Voice input: two explicit modes with separate hybrid tap/hold shortcuts. Dictate Anywhere hands finalized text to the
/// writing coordinator (guarded insertion or review); Ask Clicky by voice places text into the Quick Ask draft and never
/// submits. Nothing listens or loads at launch: a microphone session exists only between a shortcut press and Stop/Cancel,
/// audio lives in memory, and there is no live transcript or incremental insertion.
///
/// Stored properties are internal (not private) only so the session/delivery extensions in sibling files can use them.
@MainActor
final class VoiceController: ObservableObject {
    /// Set by the app delegate so Settings can reach the one controller.
    static var shared: VoiceController?

    static let askIdentifier: UInt32 = 21
    static let dictateIdentifier: UInt32 = 22
    static let cancelIdentifier: UInt32 = 23
    static let defaultAsk = VoiceShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
    static let defaultDictate = VoiceShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey))
    static let limitChoices: [Double] = [60, 120, 180, 300]

    // MARK: Published UI state (never carries transcript text while recording)

    @Published var phase = VoicePhase.idle
    /// Short context line (for example the recording limit notice) shown beside the stage.
    @Published var statusNote: String?
    @Published var offersMicrophoneSettings = false
    @Published var isLoadingModels = false
    /// The selected microphone is a Bluetooth headset, which often drops to a low-quality profile while recording.
    @Published var bluetoothMicrophone = false
    @Published var microphone: MicrophonePermission
    @Published private(set) var devices: [VoiceInputDevice] = []
    @Published var askWarning: String?
    @Published var dictateWarning: String?

    // MARK: Persisted settings

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "voiceEnabled")
            if enabled { registerShortcuts() } else { cancel(); unregisterShortcuts() }
        }
    }
    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "voiceCleanup") } }
    @Published var tapThreshold: Double {
        didSet {
            tapThreshold = min(max(tapThreshold, 0.15), 0.6)
            defaults.set(tapThreshold, forKey: "voiceTapThreshold")
            if state.isActive || gesture.phase != .idle { return }
            gesture = HybridRecordingGesture(tapThreshold: tapThreshold)
        }
    }
    /// nil records from the system default microphone.
    @Published var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: "voiceInputDevice") }
    }
    @Published var limitSeconds: Double {
        didSet { defaults.set(limitSeconds, forKey: "voiceLimitSeconds") }
    }
    @Published private(set) var askShortcut: VoiceShortcut
    @Published private(set) var dictateShortcut: VoiceShortcut

    // MARK: Collaborators

    let env: VoiceEnvironment
    let defaults: UserDefaults
    let host: any VoiceAskHost
    let quickAsk: any VoiceQuickAskPresenting
    /// Dedicated writing coordinator for dictation; independent of Quick Ask's own.
    let writer: WritingCoordinator
    let askHotkey = QuickAskHotkey(identifier: VoiceController.askIdentifier)
    let dictateHotkey = QuickAskHotkey(identifier: VoiceController.dictateIdentifier)
    let cancelHotkey = QuickAskHotkey(identifier: VoiceController.cancelIdentifier)
    private let dictateKeyBox: KeyCodeBox
    /// Keeps app-only collaborators (for example the native writing targets whose closures hold them weakly) alive.
    var retained: [AnyObject] = []

    // MARK: Session state

    var state = VoiceSessionState()
    var gesture: HybridRecordingGesture
    var recorder: (any VoiceRecording)?
    var processing: Task<Void, Never>?
    var loadTask: Task<Void, Error>?
    var cancelTimer: (() -> Void)?
    var cancelWatchdog: (() -> Void)?
    var cancelHide: (() -> Void)?
    var recordingStartedAt: TimeInterval = 0
    var level: Float = 0
    var deviceName = "Microphone"
    var releaseReadings = 0
    var lastKeyEvent: [InputMode: TimeInterval] = [:]
    var loadToken = UUID()
    var permissionToken = UUID()
    /// Review context for the dictation currently handed to the writing coordinator.
    var pendingReview: DictationReview?
    var awaitingWriter = false
    /// Cancel was pressed while the writer was still deciding or applying; the outcome is reported honestly.
    var insertionCanceled = false
    @Published var undoing = false
    var lastDictation: VoiceDictationRecord?
    var reconcileScheduled = false
    var writerObserver: AnyCancellable?

    var limits: VoiceRecordingLimits { VoiceRecordingLimits(maximumSeconds: limitSeconds) }

    private final class KeyCodeBox { var code: UInt32 = 0 }

    init(host: any VoiceAskHost, quickAsk: any VoiceQuickAskPresenting, environment: VoiceEnvironment,
         writingEnvironment: WritingEnvironment, defaults: UserDefaults = .standard) {
        self.host = host
        self.quickAsk = quickAsk
        env = environment
        self.defaults = defaults
        enabled = defaults.object(forKey: "voiceEnabled") as? Bool ?? true
        cleanupEnabled = defaults.object(forKey: "voiceCleanup") as? Bool ?? true
        let threshold = defaults.object(forKey: "voiceTapThreshold") as? Double ?? 0.25
        tapThreshold = min(max(threshold, 0.15), 0.6)
        inputDeviceUID = defaults.string(forKey: "voiceInputDevice")
        let limit = defaults.object(forKey: "voiceLimitSeconds") as? Double ?? 120
        limitSeconds = Self.limitChoices.contains(limit) ? limit : 120
        askShortcut = Self.stored(defaults, "voiceAsk") ?? Self.defaultAsk
        let dictate = Self.stored(defaults, "voiceDictate") ?? Self.defaultDictate
        dictateShortcut = dictate
        microphone = environment.microphonePermission()
        gesture = HybridRecordingGesture(tapThreshold: min(max(threshold, 0.15), 0.6))
        let box = KeyCodeBox()
        box.code = dictate.keyCode
        dictateKeyBox = box

        // Dictation must not reach the destination while a hotkey chord is still physically down, or the key-up
        // and modifiers would combine with the pasted text. The wait is short; on timeout the text stays in review.
        var writing = writingEnvironment
        writing.waitForSubmitKeyRelease = { [environment, box] in
            for _ in 0..<75 {
                if environment.modifiersReleased(), !environment.keyIsDown(box.code) { return true }
                await environment.sleep(0.04)
            }
            return environment.modifiersReleased() && !environment.keyIsDown(box.code)
        }
        writer = WritingCoordinator(environment: writing)

        askHotkey.onPressed = { [weak self] in self?.hotkeyPressed(.ask) }
        askHotkey.onReleased = { [weak self] in self?.hotkeyReleased(.ask) }
        dictateHotkey.onPressed = { [weak self] in self?.hotkeyPressed(.dictate) }
        dictateHotkey.onReleased = { [weak self] in self?.hotkeyReleased(.dictate) }
        cancelHotkey.onPressed = { [weak self] in self?.cancel() }
        host.onVoiceStop = { [weak self] in self?.stop() }
        host.onVoiceCancel = { [weak self] in self?.cancel() }
        writerObserver = writer.objectWillChange.sink { [weak self] _ in self?.scheduleWriterReconcile() }
    }

    private static func stored(_ defaults: UserDefaults, _ prefix: String) -> VoiceShortcut? {
        guard defaults.object(forKey: prefix + "KeyCode") != nil, defaults.object(forKey: prefix + "Modifiers") != nil else { return nil }
        return VoiceShortcut(keyCode: UInt32(defaults.integer(forKey: prefix + "KeyCode")),
                             modifiers: UInt32(defaults.integer(forKey: prefix + "Modifiers")))
    }

    func shortcut(for mode: InputMode) -> VoiceShortcut { mode == .ask ? askShortcut : dictateShortcut }

    // MARK: Shortcuts

    @discardableResult
    func registerShortcuts() -> Bool {
        guard enabled else { return false }
        let askOK = askHotkey.register(keyCode: askShortcut.keyCode, modifiers: askShortcut.modifiers)
        let dictateOK = dictateHotkey.register(keyCode: dictateShortcut.keyCode, modifiers: dictateShortcut.modifiers)
        askWarning = askOK ? nil : "This shortcut is unavailable. Pick another."
        dictateWarning = dictateOK ? nil : "This shortcut is unavailable. Pick another."
        return askOK && dictateOK
    }

    func unregisterShortcuts() {
        askHotkey.unregister(); dictateHotkey.unregister(); cancelHotkey.unregister()
    }

    func updateShortcut(_ mode: InputMode, keyCode: UInt32, modifiers: UInt32) {
        let new = VoiceShortcut(keyCode: keyCode, modifiers: modifiers)
        let other = shortcut(for: mode == .ask ? .dictate : .ask)
        func warn(_ text: String?) { if mode == .ask { askWarning = text } else { dictateWarning = text } }
        guard new != other else { warn("Ask and Dictate need different shortcuts."); return }
        guard !state.isActive else { warn("Finish the current recording first."); return }
        let previous = shortcut(for: mode)
        let hotkey = mode == .ask ? askHotkey : dictateHotkey
        if enabled, !hotkey.register(keyCode: keyCode, modifiers: modifiers) {
            _ = hotkey.register(keyCode: previous.keyCode, modifiers: previous.modifiers)
            warn("That shortcut is unavailable. The previous shortcut is still active.")
            return
        }
        if mode == .ask { askShortcut = new } else { dictateShortcut = new; dictateKeyBox.code = keyCode }
        let prefix = mode == .ask ? "voiceAsk" : "voiceDictate"
        defaults.set(Int(keyCode), forKey: prefix + "KeyCode")
        defaults.set(Int(modifiers), forKey: prefix + "Modifiers")
        warn(nil)
    }

    func resetShortcut(_ mode: InputMode) {
        let value = mode == .ask ? Self.defaultAsk : Self.defaultDictate
        updateShortcut(mode, keyCode: value.keyCode, modifiers: value.modifiers)
    }

    // MARK: Settings queries

    func refreshDevices() {
        devices = env.inputDevices()
        microphone = env.microphonePermission()
    }

    /// Stops everything at app quit; nothing is inserted or placed.
    func shutdown() {
        cancel()
        writer.reset()
        unregisterShortcuts()
    }
}
