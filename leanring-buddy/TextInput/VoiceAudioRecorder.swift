import AppKit
@preconcurrency import AVFoundation
import CoreAudio
#if canImport(ClickyCore)
import ClickyCore
#endif

struct VoiceInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// "built-in", "usb", "bluetooth", "virtual", "aggregate", ... (Bluetooth headsets often drop to a low-quality profile).
    let transport: String
}

/// Capture ended (hardware released); draining and analyzing the buffer is deferred so Stop never blocks the main actor.
struct StoppedRecording: Sendable {
    let collect: @Sendable () async -> RecordedAudio
}

struct RecordedAudio: Sendable {
    /// 16 kHz mono Int16. Held in memory only; the caller releases it after processing.
    let samples: [Int16]
    let stats: AudioSignalStats
    let interrupted: String?
    let reachedLimit: Bool
    let deviceName: String
}

enum MicrophonePermission { case granted, denied, undetermined }

enum VoiceRecorderError: LocalizedError {
    case permissionDenied, noInputDevice, deviceUnavailable(String), engineFailed(String), alreadyRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is not allowed. Enable it in System Settings > Privacy & Security > Microphone."
        case .noInputDevice: return "No microphone was found."
        case .deviceUnavailable(let name): return "The selected microphone is not available: \(name)."
        case .engineFailed(let detail): return "Could not start recording: \(detail)"
        case .alreadyRecording: return "Already recording."
        }
    }
}

/// Everything the realtime tap touches. It is deliberately nonisolated and allocation-light: the converter and
/// scratch buffers exist before the engine starts, and the tap only converts, copies into the bounded buffer and
/// (at most 15 times a second) posts a level. No disk, inference, IPC or logging happens on the audio thread.
private nonisolated final class CaptureCore: @unchecked Sendable {
    private let converter: AVAudioConverter
    private var output: AVAudioPCMBuffer
    private var scratch: [Int16] = []
    let buffer: BoundedSampleBuffer
    private let lock = NSLock()
    private var stopped = false
    private var limitSignalled = false
    private var lastLevelNanos: UInt64 = 0
    private let levelSink: @Sendable (Float) -> Void
    private let limitSink: @Sendable () -> Void

    init(converter: AVAudioConverter, buffer: BoundedSampleBuffer, levelSink: @escaping @Sendable (Float) -> Void,
         limitSink: @escaping @Sendable () -> Void) throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 8192) else {
            throw VoiceRecorderError.engineFailed("could not allocate the audio buffer")
        }
        self.output = output
        self.converter = converter
        self.buffer = buffer
        self.levelSink = levelSink
        self.limitSink = limitSink
        scratch.reserveCapacity(8192)
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func process(_ input: AVAudioPCMBuffer) {
        guard !isStopped, input.frameLength > 0 else { return }
        emitLevel(input)

        let needed = AVAudioFrameCount((Double(input.frameLength) * converter.outputFormat.sampleRate / input.format.sampleRate).rounded(.up)) + 32
        if needed > output.frameCapacity, let larger = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: needed) {
            output = larger // rare: only when the hardware delivers an unusually large buffer
        }
        output.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        PCMConversion.int16(fromFloat: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)), into: &scratch)
        let fitted = scratch.withUnsafeBufferPointer { buffer.append($0) }
        if !fitted { signalLimitOnce() }
    }

    private func signalLimitOnce() {
        lock.lock()
        let first = !limitSignalled
        limitSignalled = true
        lock.unlock()
        if first { limitSink() }
    }

    private func emitLevel(_ input: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastLevelNanos >= 66_000_000, let channel = input.floatChannelData?[0] else { return }
        lastLevelNanos = now
        var sum: Float = 0
        let count = Int(input.frameLength)
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = rms > 0 ? 20 * log10(rms) : -80
        levelSink(max(0, min(1, (decibels + 60) / 60)))
    }

    /// Built outside any actor so the tap block never inherits main-actor isolation.
    static func tapBlock(_ core: CaptureCore) -> AVAudioNodeTapBlock {
        { buffer, _ in core.process(buffer) }
    }
}

/// One recording's resources. `teardown()` is idempotent and safe from `deinit`.
private nonisolated final class RecordingSession: @unchecked Sendable {
    let engine: AVAudioEngine
    let core: CaptureCore
    let deviceName: String
    var cleanups: [() -> Void] = []
    var tapInstalled = false
    var engineStarted = false
    var interrupted: String?
    var reachedLimit = false
    var tornDown = false

    init(engine: AVAudioEngine, core: CaptureCore, deviceName: String) {
        self.engine = engine
        self.core = core
        self.deviceName = deviceName
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        core.stop()
        for cleanup in cleanups { cleanup() }
        cleanups = []
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        if engineStarted { engine.stop() }
    }
}

/// Bounded microphone capture for explicit voice input. There is no always-listening service: a session exists
/// only between `start` and `stop`/`cancel`, audio lives only in memory, and every exit path removes the tap
/// and engine. Interruptions end capture immediately but keep what was recorded so far.
@MainActor
final class VoiceAudioRecorder {
    var onInterrupted: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onLimitReached: (() -> Void)?
    private(set) var isRecording = false
    private var session: RecordingSession?

    deinit { session?.teardown() }

    // MARK: Permission and devices

    static func permission() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// Only call from an explicit user action (never at launch or when Quick Ask opens).
    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func inputDevices() -> [VoiceInputDevice] {
        CoreAudioQuery.deviceIDs().compactMap { id in
            guard CoreAudioQuery.hasInputStreams(id), let uid = CoreAudioQuery.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return VoiceInputDevice(id: id, uid: uid, name: CoreAudioQuery.string(id, kAudioObjectPropertyName) ?? uid,
                                    transport: CoreAudioQuery.transportName(id))
        }
    }

    // MARK: Control

    func start(deviceUID: String?, maximumSamples: Int) throws {
        guard !isRecording else { throw VoiceRecorderError.alreadyRecording }
        guard Self.permission() == .granted else { throw VoiceRecorderError.permissionDenied }
        cancel() // drops an interrupted session nobody collected
        let devices = Self.inputDevices()
        var selected: VoiceInputDevice?
        if let deviceUID {
            guard let match = devices.first(where: { $0.uid == deviceUID }) else { throw VoiceRecorderError.deviceUnavailable(deviceUID) }
            selected = match
        } else if devices.isEmpty {
            throw VoiceRecorderError.noInputDevice
        }

        let engine = AVAudioEngine()
        if let selected {
            guard var deviceID = Optional(selected.id), let unit = engine.inputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw VoiceRecorderError.deviceUnavailable(selected.name)
            }
        }
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { throw VoiceRecorderError.noInputDevice }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LocalWorkerProtocol.audioSampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw VoiceRecorderError.engineFailed("unsupported input format")
        }

        let core = try CaptureCore(
            converter: converter, buffer: BoundedSampleBuffer(capacity: maximumSamples),
            levelSink: { [weak self] level in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLevel?(level) } }
            },
            limitSink: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleLimit() } }
            })
        let newSession = RecordingSession(engine: engine, core: core, deviceName: selected?.name ?? Self.defaultInputName() ?? "Microphone")
        session = newSession
        installObservers(on: newSession, engine: engine, selected: selected)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: CaptureCore.tapBlock(core))
        newSession.tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            newSession.engineStarted = true
        } catch {
            newSession.teardown()
            session = nil
            throw VoiceRecorderError.engineFailed(error.localizedDescription)
        }
        isRecording = true
    }

    func stop() -> StoppedRecording {
        guard let current = session else {
            return StoppedRecording {
                RecordedAudio(samples: [], stats: AudioSignalStats.analyze([]), interrupted: nil, reachedLimit: false, deviceName: "")
            }
        }
        current.teardown()
        session = nil
        isRecording = false
        let buffer = current.core.buffer
        let interrupted = current.interrupted, reachedLimit = current.reachedLimit, deviceName = current.deviceName
        return StoppedRecording {
            await Task.detached(priority: .userInitiated) {
                let samples = buffer.drain()
                return RecordedAudio(samples: samples, stats: AudioSignalStats.analyze(samples, sampleRate: LocalWorkerProtocol.audioSampleRate),
                                     interrupted: interrupted, reachedLimit: reachedLimit, deviceName: deviceName)
            }.value
        }
    }

    func cancel() {
        guard let current = session else { return }
        current.teardown()
        current.core.buffer.clear()
        session = nil
        isRecording = false
    }

    // MARK: Interruptions

    private func handleLimit() {
        guard let current = session, isRecording, !current.reachedLimit else { return }
        current.reachedLimit = true
        current.teardown() // nothing more can be stored; keep the samples for stop()
        isRecording = false
        onLimitReached?()
    }

    private func interrupt(_ reason: String) {
        guard let current = session, isRecording, current.interrupted == nil else { return }
        current.interrupted = reason
        current.teardown()
        isRecording = false
        onInterrupted?(reason)
    }

    private func installObservers(on session: RecordingSession, engine: AVAudioEngine, selected: VoiceInputDevice?) {
        func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil, reason: String) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt(reason) }
            }
            session.cleanups.append { center.removeObserver(token) }
        }
        observe(.default, .AVAudioEngineConfigurationChange, object: engine, reason: "The audio device changed.")
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, reason: "The Mac is going to sleep.")
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, reason: "The user session became inactive.")
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), reason: "The screen was locked.")

        let removed = "The microphone was disconnected."
        session.cleanups.append(CoreAudioQuery.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { [weak self] in
            // A device list change only matters when the selected device left it.
            guard let selected, !Self.inputDevices().contains(where: { $0.uid == selected.uid }) else { return }
            self?.interrupt(removed)
        })
        if let selected {
            session.cleanups.append(CoreAudioQuery.listen(selected.id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                self?.interrupt(removed)
            })
        }
    }

    private static func defaultInputName() -> String? {
        guard let id = CoreAudioQuery.defaultInputDevice() else { return nil }
        return CoreAudioQuery.string(id, kAudioObjectPropertyName)
    }
}

private nonisolated enum CoreAudioQuery {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transportName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr else { return "unknown" }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        default: return "other"
        }
    }

    /// Main-queue property listener; the returned closure removes it.
    @MainActor
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) -> () -> Void {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr else { return {} }
        return {
            var removeAddr = address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &removeAddr, DispatchQueue.main, block)
        }
    }
}
