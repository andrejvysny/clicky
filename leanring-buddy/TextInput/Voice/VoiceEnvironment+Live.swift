import AppKit
import CoreGraphics
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Adapts the bounded microphone recorder to the controller's `VoiceRecording`.
@MainActor
final class VoiceRecorderAdapter: VoiceRecording {
    private let recorder = VoiceAudioRecorder()
    private(set) var deviceName = "Microphone"

    var onInterrupted: ((String) -> Void)? {
        get { recorder.onInterrupted }
        set { recorder.onInterrupted = newValue }
    }
    var onLevel: ((Float) -> Void)? {
        get { recorder.onLevel }
        set { recorder.onLevel = newValue }
    }
    var onLimitReached: (() -> Void)? {
        get { recorder.onLimitReached }
        set { recorder.onLimitReached = newValue }
    }

    func start(deviceUID: String?, maximumSamples: Int) throws {
        try recorder.start(deviceUID: deviceUID, maximumSamples: maximumSamples)
        let selected = deviceUID.flatMap { uid in VoiceAudioRecorder.inputDevices().first { $0.uid == uid } }
        deviceName = selected?.name ?? "System default microphone"
    }

    func stop() -> StoppedRecording { recorder.stop() }
    func cancel() { recorder.cancel() }
}

extension VoiceEnvironment {
    static func live(runtime: LocalAIRuntime) -> VoiceEnvironment {
        VoiceEnvironment(
            microphonePermission: { VoiceAudioRecorder.permission() },
            requestMicrophone: { await VoiceAudioRecorder.requestPermission() },
            inputDevices: { VoiceAudioRecorder.inputDevices() },
            makeRecorder: { VoiceRecorderAdapter() },
            keyIsDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) },
            modifiersReleased: {
                CGEventSource.flagsState(.combinedSessionState)
                    .isDisjoint(with: [.maskCommand, .maskAlternate, .maskShift, .maskControl])
            },
            frontmostProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            speechAdmission: { withCleanup in admission(runtime, withCleanup: withCleanup) },
            loadSpeech: { withCleanup in
                do {
                    try await runtime.load(.speech)
                    // Cleanup is optional: a missing or failing cleanup model never blocks plain transcription.
                    if withCleanup, runtime.installedModel(.cleanup) != nil { try? await runtime.load(.cleanup) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw VoiceMessageError(LocalAIRuntime.describe(error))
                }
            },
            makeStages: { withCleanup in
                guard runtime.isLoaded(.speech) else { throw VoiceMessageError("The speech model is not loaded.") }
                let pipeline = try runtime.speechPipeline(cleanup: withCleanup)
                return VoiceStages(
                    transcribe: { samples in
                        do {
                            return try await runtime.perform(.speech, jobClass: .foreground) { _, _ in
                                try await pipeline.transcribe(samples)
                            }.text
                        } catch is CancellationError { throw CancellationError() }
                        catch { throw VoiceMessageError(LocalAIRuntime.describe(error)) }
                    },
                    cleanup: { raw in
                        guard pipeline.canClean else { return nil }
                        return try await runtime.perform(.cleanup, jobClass: .foreground) { _, _ in
                            try await pipeline.cleanup(raw)
                        }.text
                    })
            },
            now: { ProcessInfo.processInfo.systemUptime },
            repeatEvery: { interval, action in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { action() } }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
    }

    /// Speech must be usable. Cleanup joins the check when it is on and a cleanup model is installed: under the Manual
    /// policy an installed but unloaded cleanup model also needs "Load speech pipeline" (which loads both). With no
    /// cleanup model installed, plain transcription proceeds and delivery falls back to review with the raw text.
    private static func admission(_ runtime: LocalAIRuntime, withCleanup: Bool) -> VoiceSpeechAdmission {
        guard runtime.workerAvailable else { return .unavailable(LocalAIError.workerMissing.errorDescription ?? "The local worker is missing.") }
        if !runtime.isLoaded(.speech), runtime.installedModel(.speech) == nil {
            return .unavailable("\(runtime.displayName(.speech)) is not installed. Download or import it in the Local AI Lab.")
        }
        var groups: [LocalModelGroup] = [.speech]
        if withCleanup, runtime.installedModel(.cleanup) != nil || runtime.isLoaded(.cleanup) { groups.append(.cleanup) }
        var result = VoiceSpeechAdmission.ready
        for group in groups {
            switch LocalResidencyPlanner.admission(policy: runtime.residency[group], isLoaded: runtime.isLoaded(group), explicitRun: false) {
            case .ready: break
            case .needsExplicitLoad: return .needsExplicitLoad
            case .loadAutomatically: result = .loadAutomatically
            case .overBudget(let required, let available):
                return .unavailable("Needs \(LocalAIRuntime.megabytes(required)) MB, \(LocalAIRuntime.megabytes(available)) MB free.")
            }
        }
        return result
    }
}
