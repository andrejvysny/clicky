import Carbon
import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Gesture handling, recording lifecycle and the transcription pipeline. Every asynchronous continuation re-checks the
/// session generation, so a canceled or superseded session can never reach a destination.
extension VoiceController {
    // MARK: Hotkey events

    func hotkeyPressed(_ mode: InputMode) {
        guard enabled else { return }
        let time = env.now()
        // Carbon does not normally auto-repeat hot key presses, but a repeat must never restart or finalize a
        // session, so a press within 150 ms of the previous press/release of the same mode counts as a repeat.
        let isRepeat = lastKeyEvent[mode].map { time - $0 < 0.15 } ?? false
        lastKeyEvent[mode] = time
        perform(gesture.keyDown(mode: mode, time: time, isRepeat: isRepeat))
    }

    func hotkeyReleased(_ mode: InputMode) {
        guard enabled else { return }
        let time = env.now()
        lastKeyEvent[mode] = time
        perform(gesture.keyUp(mode: mode, time: time))
    }

    private func perform(_ effect: HybridRecordingGesture.Effect) {
        switch effect {
        case .start(let mode): startSession(mode)
        case .finalize: finalizeRecording(interrupted: nil)
        case .discard, .none: break
        }
    }

    // MARK: Start

    private func startSession(_ mode: InputMode) {
        // A running session (or a write in flight) wins; the extra press is dropped and must not leave the gesture latched.
        guard !state.isActive, writer.phase != .applying else { _ = gesture.cancel(); return }
        clearTransient()
        switch env.microphonePermission() {
        case .undetermined:
            _ = gesture.cancel(); requestMicrophonePermission(); return
        case .denied:
            microphone = .denied
            _ = gesture.cancel(); showFailed(VoiceText.deniedMessage, microphoneSettings: true); return
        case .granted: microphone = .granted
        }
        let withCleanup = cleanupEnabled
        var loadInParallel = false
        switch env.speechAdmission(withCleanup) {
        case .needsExplicitLoad:
            _ = gesture.cancel(); phase = .needsSpeechModels(mode); return
        case .unavailable(let message):
            _ = gesture.cancel(); showFailed(message); return
        case .loadAutomatically: loadInParallel = true
        case .ready: break
        }
        // The destination is bound before anything (the HUD is nonactivating) can change focus.
        if mode == .dictate { writer.beginBinding(processIdentifier: env.frontmostProcess()) }
        else { quickAsk.showQuickAsk() }
        guard let generation = state.begin(mode: mode, cleanup: withCleanup, at: env.now()) else { _ = gesture.cancel(); return }
        let newRecorder = env.makeRecorder()
        newRecorder.onLevel = { [weak self] value in self?.level = value }
        newRecorder.onInterrupted = { [weak self] reason in self?.recorderInterrupted(reason, generation) }
        newRecorder.onLimitReached = { [weak self] in self?.recorderLimitReached(generation) }
        do {
            try newRecorder.start(deviceUID: inputDeviceUID, maximumSamples: limits.maximumSamples)
        } catch {
            newRecorder.cancel()
            _ = state.fail(generation, .microphoneUnavailable(Self.describe(error)))
            _ = gesture.cancel()
            if mode == .dictate { writer.discard() }
            showFailed(Self.describe(error)); return
        }
        recorder = newRecorder
        deviceName = newRecorder.deviceName
        bluetoothMicrophone = env.inputDevices().contains { device in
            device.transport == "bluetooth" && (inputDeviceUID.map { device.uid == $0 } ?? (device.name == deviceName))
        }
        recordingStartedAt = env.now()
        level = 0
        releaseReadings = 0
        statusNote = nil
        if loadInParallel {
            loadTask = Task { [env] in try await env.loadSpeech(withCleanup) }
            loadToken = UUID()
        }
        cancelTimer = env.repeatEvery(0.2) { [weak self] in self?.tick() }
        cancelWatchdog = env.repeatEvery(0.1) { [weak self] in self?.watchdogTick() }
        if !cancelHotkey.register(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey | shiftKey)) {
            statusNote = "⌥⇧Esc unavailable — use Cancel"
        }
        publishRecording()
    }

    private func requestMicrophonePermission() {
        phase = .requestingPermission
        let token = UUID()
        permissionToken = token
        Task { [weak self] in
            guard let self else { return }
            let granted = await env.requestMicrophone()
            guard permissionToken == token else { return }
            microphone = env.microphonePermission()
            if granted { showResult(VoiceText.allowedMessage) } else { showFailed(VoiceText.deniedMessage, microphoneSettings: true) }
        }
    }

    // MARK: Timers

    func tick() {
        guard state.isRecording else { return }
        let elapsed = env.now() - recordingStartedAt
        if limits.isExhausted(elapsed: elapsed) {
            statusNote = "Recording limit reached (\(VoiceText.clock(limits.maximumSeconds)))"
            finalizeRecording(interrupted: nil)
            return
        }
        publishRecording()
    }

    /// Carbon can miss a key-up (focus changes, secure input). While the gesture believes the key is held, two
    /// consecutive "up" readings synthesize the release, so a hold can never record forever.
    func watchdogTick() {
        guard state.isRecording, case .held(let mode) = gesture.phase else { releaseReadings = 0; return }
        if env.keyIsDown(shortcut(for: mode).keyCode) { releaseReadings = 0; return }
        releaseReadings += 1
        if releaseReadings >= 2 {
            releaseReadings = 0
            hotkeyReleased(mode)
        }
    }

    private func publishRecording() {
        let elapsed = max(0, env.now() - recordingStartedAt)
        phase = .recording(mode: state.mode, elapsed: elapsed, limit: limits.maximumSeconds, deviceName: deviceName, level: level)
        publishAskStatus()
    }

    func publishAskStatus() {
        guard state.mode == .ask else { host.setVoiceStatus(nil); return }
        switch phase {
        case .recording(_, let elapsed, let limit, _, _):
            host.setVoiceStatus(VoiceAskStatus(line: "Asking · \(VoiceText.clock(elapsed)) / \(VoiceText.clock(limit))", canStop: true))
        case .transcribing: host.setVoiceStatus(VoiceAskStatus(line: statusNote ?? "Transcribing…", canStop: false))
        case .cleaning: host.setVoiceStatus(VoiceAskStatus(line: "Cleaning up…", canStop: false))
        default: host.setVoiceStatus(nil)
        }
    }

    // MARK: Recorder events

    private func recorderInterrupted(_ reason: String, _ generation: UInt64) {
        guard generation == state.generation, state.isRecording else { return }
        statusNote = reason
        finalizeRecording(interrupted: reason)
    }

    private func recorderLimitReached(_ generation: UInt64) {
        guard generation == state.generation, state.isRecording else { return }
        statusNote = "Recording limit reached (\(VoiceText.clock(limits.maximumSeconds)))"
        finalizeRecording(interrupted: nil)
    }

    // MARK: Stop

    /// Stop button.
    func stop() {
        guard state.isRecording else { return }
        _ = gesture.cancel()
        finalizeRecording(interrupted: nil)
    }

    func finalizeRecording(interrupted reason: String?) {
        let generation = state.generation
        guard state.stop(generation) else { return }
        _ = gesture.cancel()
        stopTimers()
        // The microphone is torn down right here; only draining and analyzing the buffer runs off the main actor.
        let stopped = recorder?.stop()
        recorder = nil
        let mode = state.mode
        phase = .transcribing(mode)
        publishAskStatus()
        processing = Task { [weak self] in
            let audio = await stopped?.collect()
            guard let self, generation == state.generation, state.isActive else { return }
            let interrupted = reason != nil || audio?.interrupted != nil
            guard let audio, !audio.stats.isLikelySilence else {
                // No speech-like signal: no worker call at all.
                if let next = state.transcribed(generation, raw: ""), case .delivering(let delivery) = next {
                    deliver(delivery, generation, interrupted: interrupted)
                }
                return
            }
            await process(audio.samples, generation, interrupted: interrupted)
        }
    }

    func stopTimers() {
        cancelTimer?(); cancelTimer = nil
        cancelWatchdog?(); cancelWatchdog = nil
    }

    // MARK: Pipeline

    private func process(_ samples: [Int16], _ generation: UInt64, interrupted: Bool) async {
        let mode = state.mode
        let withCleanup = state.cleanupRequested
        do {
            if let pending = loadTask {
                statusNote = "Loading speech models…"
                publishAskStatus()
                // Only the load this session started may be cleared; a newer session owns a newer one.
                let token = loadToken
                defer {
                    if loadToken == token { loadTask = nil }
                    if generation == state.generation, statusNote == "Loading speech models…" { statusNote = nil }
                }
                try await pending.value
            }
            guard generation == state.generation, state.isActive else { return }
            let stages = try env.makeStages(withCleanup)
            let raw = try await stages.transcribe(samples)
            guard let next = state.transcribed(generation, raw: raw) else { return }
            switch next {
            case .cleaning(let transcript):
                phase = .cleaning(mode)
                publishAskStatus()
                var cleaned: String?
                do { cleaned = try await stages.cleanup(transcript) }
                catch is CancellationError { return }
                catch { cleaned = nil }
                guard let delivery = state.cleaned(generation, cleaned: cleaned) else { return }
                deliver(delivery, generation, interrupted: interrupted)
            case .delivering(let delivery):
                deliver(delivery, generation, interrupted: interrupted)
            default: return
            }
        } catch is CancellationError {
            return
        } catch {
            guard state.fail(generation, .transcriptionFailed(Self.describe(error))) else { return }
            endActive()
            showFailed(Self.describe(error))
        }
    }

    // MARK: Cancel

    /// Cancel button and Option+Shift+Escape: nothing is inserted or placed.
    func cancel() {
        _ = gesture.cancel()
        permissionToken = UUID()
        let generation = state.generation
        if state.isActive {
            recorder?.cancel(); recorder = nil
            processing?.cancel(); processing = nil
            loadTask?.cancel(); loadTask = nil
            _ = state.cancel(generation)
            if writer.phase != .applying { writer.discard() }
            awaitingWriter = false; pendingReview = nil
            endActive()
            phase = .idle
            return
        }
        clearTransient()
    }

    /// Common teardown when a session stops being active (delivered, failed or canceled).
    func endActive() {
        stopTimers()
        cancelHotkey.unregister()
        statusNote = nil
        host.setVoiceStatus(nil)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
