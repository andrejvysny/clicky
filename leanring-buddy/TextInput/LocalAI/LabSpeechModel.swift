import Combine
import AppKit
import Foundation
import UniformTypeIdentifiers

/// State of the Speech tab. Audio and transcripts exist only in memory; saving a benchmark sample is an explicit action.
@MainActor
final class LabSpeechModel: ObservableObject {
    enum Capture: Equatable { case idle, recording, ready }

    static let maximumSeconds = Int(LocalWorkerProtocol.maximumAudioSeconds)

    let runtime: LocalAIRuntime
    let results: LabResults
    private let recorder = VoiceAudioRecorder()
    @Published private(set) var capture: Capture = .idle
    @Published private(set) var devices: [VoiceInputDevice] = []
    @Published var deviceUID: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var activeDeviceName = ""
    @Published private(set) var samples: [Int16] = []
    @Published var cleanupEnabled = true
    @Published var promptIndex = 0
    @Published private(set) var processing = false
    @Published private(set) var rawTranscript: String?
    @Published private(set) var cleanedTranscript: String?
    @Published private(set) var assessment: CleanupAssessment?
    @Published var useOriginal = false
    @Published private(set) var asrMetrics: LabStage?
    @Published private(set) var cleanupMetrics: LabStage?
    @Published private(set) var stopToFinalMilliseconds: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cleanupError: String?
    @Published private(set) var savedSamples: [LocalBenchmarkSample] = []
    @Published var saveMessage: String?
    private var timer: Timer?
    private var startedAt = Date()
    private var stoppedAt: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    /// Bumped whenever recording or import is canceled, so a late permission prompt or decode result is dropped.
    private var captureToken = UUID()
    private var captureTask: Task<Void, Never>?
    @Published private(set) var diffSegments: [LabWordDiff.Segment]?

    struct LabStage: Equatable {
        let worker: LocalRunMetrics
        let hostMilliseconds: Double
    }

    init(runtime: LocalAIRuntime, results: LabResults) { self.runtime = runtime; self.results = results }

    var dataset: LocalPersonalDataset { LocalPersonalDataset(root: runtime.env.benchmarksRoot.appendingPathComponent("Personal", isDirectory: true)) }
    var audioSeconds: Double { Double(samples.count) / Double(LocalWorkerProtocol.audioSampleRate) }
    var prompt: LocalCleanupPrompt { LocalCleanupPrompt.all[min(promptIndex, LocalCleanupPrompt.all.count - 1)] }

    /// "Use original transcript" selects the raw text as the result; otherwise the cleaned text when there is one.
    var resultText: String? { useOriginal || cleanedTranscript == nil ? rawTranscript : cleanedTranscript }

    /// Listing devices and saved samples reads no audio and asks for no permission.
    func refresh() {
        devices = VoiceAudioRecorder.inputDevices()
        if let deviceUID, !devices.contains(where: { $0.uid == deviceUID }) { self.deviceUID = nil }
        savedSamples = dataset.samples()
    }

    // MARK: Recording

    func startRecording() {
        guard capture != .recording, !processing else { return }
        clearResults()
        let token = UUID()
        captureToken = token
        captureTask = Task {
            // The permission prompt appears only here, from the user's click on Record.
            if VoiceAudioRecorder.permission() == .undetermined { _ = await VoiceAudioRecorder.requestPermission() }
            // The window may have closed while the prompt was up: never start recording after that.
            guard !Task.isCancelled, captureToken == token else { return }
            do {
                recorder.onLevel = { [weak self] value in self?.level = value }
                recorder.onLimitReached = { [weak self] in self?.stopRecording() }
                recorder.onInterrupted = { [weak self] reason in self?.errorMessage = reason; self?.stopRecording() }
                try recorder.start(deviceUID: deviceUID, maximumSamples: Self.maximumSeconds * LocalWorkerProtocol.audioSampleRate)
                activeDeviceName = devices.first { $0.uid == deviceUID }?.name ?? "Default input"
                startedAt = Date(); elapsed = 0; level = 0; capture = .recording
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    let model = self
                    Task { @MainActor in model?.tick() }
                }
            } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func tick() { if capture == .recording { elapsed = Date().timeIntervalSince(startedAt) } }

    func stopRecording() {
        guard capture == .recording else { return }
        timer?.invalidate(); timer = nil
        let stopped = ContinuousClock.now
        let pending = recorder.stop()
        level = 0
        capture = .idle
        let token = captureToken
        // Draining the buffer happens off the main actor; the capture flag already left .recording so Stop is single-shot.
        Task { [weak self] in
            let recording = await pending.collect()
            guard let self, captureToken == token else { return }
            if let interrupted = recording.interrupted { errorMessage = interrupted }
            samples = recording.samples
            capture = samples.isEmpty ? .idle : .ready
            if samples.isEmpty { errorMessage = errorMessage ?? "Nothing was recorded." }
            else { stoppedAt = stopped; transcribe(automatic: true) }
        }
    }

    func cancelRecording() {
        captureToken = UUID()
        captureTask?.cancel(); captureTask = nil
        timer?.invalidate(); timer = nil
        recorder.cancel()
        if capture == .recording { capture = .idle }
        level = 0
    }

    /// Drops the recording and everything derived from it.
    func discardAudio() {
        cancelProcessing()
        cancelRecording()
        samples = []
        capture = .idle
        clearResults()
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, !processing, capture != .recording else { return }
        clearResults()
        let token = UUID()
        captureToken = token
        captureTask = Task {
            do {
                let decoded = try await Task.detached { try LabAudioImporter.samples(from: url) }.value
                guard !Task.isCancelled, captureToken == token else { return }
                samples = decoded
                capture = .ready
                stoppedAt = nil
            } catch {
                guard captureToken == token else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearResults() {
        rawTranscript = nil; cleanedTranscript = nil; diffSegments = nil; assessment = nil; asrMetrics = nil; cleanupMetrics = nil
        stopToFinalMilliseconds = nil; errorMessage = nil; cleanupError = nil; useOriginal = false; saveMessage = nil
    }

    // MARK: Transcription

    func cancelProcessing() {
        task?.cancel()
        generation = UUID()
        processing = false
    }

    /// Recognition on the speech worker, then optional cleanup. A missing cleanup model never discards the raw transcript.
    func transcribe(automatic: Bool = false) {
        guard !processing, !samples.isEmpty else { return }
        if !automatic { stoppedAt = nil }
        let token = UUID()
        generation = token
        processing = true
        let audio = samples
        let cleanup = cleanupEnabled
        let chosenPrompt = prompt
        let stopped = stoppedAt
        let clock = ContinuousClock()
        task = Task {
            var result = LocalBenchmarkSampleResult(sampleIdentifier: "lab", repetition: 0)
            do {
                clearResults()
                try await runtime.ensureReady(.speech, explicitRun: false)
                let asrPipeline = try runtime.speechPipeline(cleanup: false)
                let asr = try await runtime.perform(.speech) { _, _ in try await asrPipeline.transcribe(audio) }
                guard generation == token else { return }
                rawTranscript = asr.text
                asrMetrics = LabStage(worker: asr.worker, hostMilliseconds: asr.hostMilliseconds)
                result.rawText = asr.text; result.recognizerMetrics = asr.worker; result.hostRecognizerMilliseconds = asr.hostMilliseconds
                result.audioSeconds = Double(audio.count) / Double(LocalWorkerProtocol.audioSampleRate)
                var pipeline = LocalBenchmarkConfiguration.Pipeline.asrOnly
                if cleanup, asr.text.contains(where: { !$0.isWhitespace }) {
                    do {
                        try await runtime.ensureReady(.cleanup, explicitRun: false)
                        let cleaner = try runtime.speechPipeline(cleanup: true, prompt: chosenPrompt)
                        let cleaned = try await runtime.perform(.cleanup) { _, _ in try await cleaner.cleanup(asr.text) }
                        guard generation == token else { return }
                        cleanedTranscript = cleaned.text
                        diffSegments = LabWordDiff.diff(asr.text, cleaned.text)
                        cleanupMetrics = LabStage(worker: cleaned.worker, hostMilliseconds: cleaned.hostMilliseconds)
                        let verdict = CleanupGate.assess(raw: asr.text, cleaned: cleaned.text)
                        assessment = verdict
                        pipeline = .asrWithCleanup
                        result.cleanedText = cleaned.text; result.cleanupMetrics = cleaned.worker
                        result.hostCleanupMilliseconds = cleaned.hostMilliseconds
                        result.gateVerdict = verdict.verdict; result.gateConcerns = verdict.concerns
                    } catch is CancellationError { throw CancellationError() }
                    catch { cleanupError = LocalAIRuntime.describe(error) }
                }
                if let stopped {
                    let elapsed = clock.now - stopped
                    stopToFinalMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                    result.stopToFinalMilliseconds = stopToFinalMilliseconds
                }
                let recorded = result
                results.record(runtime: runtime, pipeline: pipeline, groups: pipeline == .asrOnly ? [.speech] : [.speech, .cleanup],
                               promptIdentifier: pipeline == .asrOnly ? nil : chosenPrompt.identifier, parameters: nil) { $0 = recorded }
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError) { errorMessage = LocalAIRuntime.describe(error) }
            }
            if generation == token { processing = false }
        }
    }

    // MARK: Personal benchmark samples

    func saveSample(raw: String, clean: String, split: LocalBenchmarkSample.Split, tags: [String], approve: Bool) {
        let dataset = self.dataset
        let audio = samples
        Task {
            // Writing the WAV file and index happens off the main actor.
            let message = await Task.detached { () -> String in
                do {
                    let sample = try dataset.add(audio, rawReference: raw.isEmpty ? nil : raw, cleanReference: clean.isEmpty ? nil : clean,
                                                 split: split, tags: tags)
                    if approve { try dataset.approve(sample.id, at: Date()) }
                    return approve ? "Saved and approved \(sample.id)." : "Saved \(sample.id) (not approved)."
                } catch { return "Could not save: \(error.localizedDescription)" }
            }.value
            saveMessage = message
            savedSamples = dataset.samples()
        }
    }

    func deleteSample(_ sample: LocalBenchmarkSample) {
        do { try dataset.delete(sample.id) } catch { saveMessage = "Could not delete: \(error.localizedDescription)" }
        savedSamples = dataset.samples()
    }
}
