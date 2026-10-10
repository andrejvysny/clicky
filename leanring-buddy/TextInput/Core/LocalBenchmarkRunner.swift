import Foundation

nonisolated enum BenchmarkSupport {
    /// Error code only: failure strings never carry prompts, transcripts or file contents.
    static func failureCode(_ error: Error) -> String {
        if let error = error as? LocalWorkerError { return error.code.rawValue }
        if error is CancellationError { return "canceled" }
        if error is LocalDatasetError { return "audioUnavailable" }
        return "error"
    }

    static func milliseconds(from start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock().now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func memoryReport(_ connection: LocalWorkerConnection) async -> LocalMemoryReport? {
        do {
            for try await event in connection.request(.memory(request: UUID())) {
                if case .memory(_, _, let report) = event { return report }
            }
        } catch {}
        return nil
    }

    /// Both workers stayed loaded for the whole run, so the sum of their peaks is the simultaneous resident peak.
    static func memory(speech: LocalWorkerConnection?, inference: LocalWorkerConnection?) async -> LocalBenchmarkMemory {
        var memory = LocalBenchmarkMemory()
        if let speech { memory.speechWorker = await memoryReport(speech) }
        if let inference { memory.inferenceWorker = await memoryReport(inference) }
        let peaks = [memory.speechWorker, memory.inferenceWorker].compactMap { $0 }.map { $0.peakPhysicalFootprintBytes ?? $0.physicalFootprintBytes }
        memory.combinedPeakFootprintBytes = peaks.isEmpty ? nil : peaks.reduce(0, +)
        return memory
    }
}

/// Speech benchmark over the production `LocalSpeechPipeline`. Warm-up runs use the first sample and are not
/// recorded, but the very first call after model load is kept in `coldFirstMilliseconds` ("recognizer", "cleanup").
nonisolated public struct LocalSpeechBenchmark: Sendable {
    public let pipeline: LocalSpeechPipeline
    public let configuration: LocalBenchmarkConfiguration
    public let environment: LocalBenchmarkEnvironment
    /// Load times measured by the caller (keyed by catalog entry id); copied into the run.
    public var loadMilliseconds: [String: Double] = [:]

    public init(pipeline: LocalSpeechPipeline, configuration: LocalBenchmarkConfiguration, environment: LocalBenchmarkEnvironment) {
        self.pipeline = pipeline; self.configuration = configuration; self.environment = environment
    }

    public func run(samples: [LocalBenchmarkSample], audio: @Sendable (LocalBenchmarkSample) throws -> [Int16],
                    progress: @Sendable (Int, Int) -> Void) async -> LocalBenchmarkRun {
        var run = LocalBenchmarkRun(environment: environment, configuration: configuration)
        run.loadMilliseconds = loadMilliseconds
        let repetitions = max(1, configuration.repetitions)
        let total = samples.count * repetitions
        var done = 0
        var references: [String: (raw: String?, clean: String?)] = [:]
        for sample in samples { references[sample.id] = (sample.rawReference, sample.cleanReference) }

        if let first = samples.first, configuration.warmUpRuns > 0, let samplesAudio = try? loadAudio(first, audio) {
            for _ in 0..<configuration.warmUpRuns {
                if Task.isCancelled { break }
                _ = await measure(first, repetition: 0, audio: samplesAudio, cold: &run.coldFirstMilliseconds)
            }
        }
        loop: for sample in samples {
            for repetition in 0..<repetitions {
                if Task.isCancelled { break loop }
                var result = LocalBenchmarkSampleResult(sampleIdentifier: sample.id, repetition: repetition)
                do {
                    let pcm = try loadAudio(sample, audio)
                    result = await measure(sample, repetition: repetition, audio: pcm, cold: &run.coldFirstMilliseconds)
                } catch { result.failure = BenchmarkSupport.failureCode(error) }
                if Task.isCancelled && result.failure == "canceled" { break loop }
                run.results.append(result)
                done += 1
                progress(done, total)
            }
        }
        if !Task.isCancelled {
            run.memory = await BenchmarkSupport.memory(speech: configuration.pipeline == .cleanupOnReference ? nil : pipeline.speech,
                                                       inference: pipeline.inference)
        }
        run.summarize(references: references)
        return run
    }

    /// Cleanup-on-reference never reads audio, so a sample without a usable WAV can still be measured.
    private func loadAudio(_ sample: LocalBenchmarkSample, _ audio: @Sendable (LocalBenchmarkSample) throws -> [Int16]) throws -> [Int16] {
        configuration.pipeline == .cleanupOnReference ? [] : try audio(sample)
    }

    private func measure(_ sample: LocalBenchmarkSample, repetition: Int, audio: [Int16], cold: inout [String: Double]) async -> LocalBenchmarkSampleResult {
        var result = LocalBenchmarkSampleResult(sampleIdentifier: sample.id, repetition: repetition)
        if !audio.isEmpty { result.audioSeconds = Double(audio.count) / Double(LocalWorkerProtocol.audioSampleRate) }
        let span = ContinuousClock().now
        do {
            var rawText: String?
            switch configuration.pipeline {
            case .asrOnly, .asrWithCleanup:
                let recognized = try await pipeline.transcribe(audio)
                if cold["recognizer"] == nil { cold["recognizer"] = recognized.hostMilliseconds }
                rawText = recognized.text
                result.rawText = recognized.text
                result.recognizerMetrics = recognized.worker
                result.hostRecognizerMilliseconds = recognized.hostMilliseconds
            case .cleanupOnReference:
                guard let reference = sample.rawReference else { result.failure = "missingReference"; return result }
                rawText = reference
            case .text, .vision:
                result.failure = "unsupportedPipeline"; return result
            }
            if configuration.pipeline != .asrOnly, let input = rawText {
                let cleaned = try await pipeline.cleanup(input)
                if cold["cleanup"] == nil { cold["cleanup"] = cleaned.hostMilliseconds }
                let assessment = CleanupGate.assess(raw: input, cleaned: cleaned.text)
                result.cleanedText = cleaned.text
                result.cleanupMetrics = cleaned.worker
                result.hostCleanupMilliseconds = cleaned.hostMilliseconds
                result.gateVerdict = assessment.verdict
                result.gateConcerns = assessment.concerns
            }
            // One monotonic span from before transcription to after the gate, not a sum of per-stage times.
            if configuration.pipeline == .asrWithCleanup { result.stopToFinalMilliseconds = BenchmarkSupport.milliseconds(from: span) }
            if configuration.pipeline == .asrOnly { result.stopToFinalMilliseconds = result.hostRecognizerMilliseconds }
            if configuration.pipeline != .cleanupOnReference, let raw = result.rawText, let reference = sample.rawReference {
                result.rawWordErrorRate = SpeechMetrics.wordErrorRate(reference: reference, hypothesis: raw)
            }
            if let hypothesis = result.cleanedText ?? result.rawText, let reference = sample.cleanReference {
                result.cleanWordErrorRate = SpeechMetrics.wordErrorRate(reference: reference, hypothesis: hypothesis)
                result.cleanCharacterErrorRate = SpeechMetrics.characterErrorRate(reference: reference, hypothesis: hypothesis)
            }
        } catch { result.failure = BenchmarkSupport.failureCode(error) }
        return result
    }
}

/// One generate request: chat messages and optionally one PNG.
nonisolated public struct LocalGenerationCase: Sendable {
    public let id: String
    public let messages: [LocalChatMessage]
    public let image: Data?
    public let expectedBox: LocalVisionBox?

    public init(id: String, messages: [LocalChatMessage], image: Data? = nil, expectedBox: LocalVisionBox? = nil) {
        self.id = id; self.messages = messages; self.image = image; self.expectedBox = expectedBox
    }
}

nonisolated public struct LocalVisionBox: Codable, Equatable, Sendable {
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(label: String, x: Double, y: Double, width: Double, height: Double) {
        self.label = label; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Scores a model's answer to "give the box of label L": schema compliance, center-in-target and IoU.
nonisolated public enum LocalVisionScoring {
    public struct Score: Equatable, Sendable {
        public var schemaCompliant: Bool
        public var targetHit: Bool
        public var intersectionOverUnion: Double
    }

    public static func score(output: String, expected: LocalVisionBox) -> Score {
        guard let predicted = parse(output) else { return Score(schemaCompliant: false, targetHit: false, intersectionOverUnion: 0) }
        let centerX = predicted.x + predicted.width / 2, centerY = predicted.y + predicted.height / 2
        let hit = centerX >= expected.x && centerX <= expected.x + expected.width
            && centerY >= expected.y && centerY <= expected.y + expected.height
        let overlapWidth = max(0, min(predicted.x + predicted.width, expected.x + expected.width) - max(predicted.x, expected.x))
        let overlapHeight = max(0, min(predicted.y + predicted.height, expected.y + expected.height) - max(predicted.y, expected.y))
        let intersection = overlapWidth * overlapHeight
        let union = predicted.width * predicted.height + expected.width * expected.height - intersection
        return Score(schemaCompliant: true, targetHit: hit, intersectionOverUnion: union > 0 ? intersection / union : 0)
    }

    /// Valid JSON object (optionally inside a code fence) with a string `label` and numeric x/y/width/height.
    public static func parse(_ output: String) -> LocalVisionBox? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
              let data = String(output[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = object["label"] as? String,
              let x = number(object["x"]), let y = number(object["y"]), let width = number(object["width"]), let height = number(object["height"]),
              width >= 0, height >= 0 else { return nil }
        return LocalVisionBox(label: label, x: x, y: y, width: width, height: height)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// Text and vision generation benchmark through one inference connection. Text uses cases without images.
nonisolated public struct LocalGenerationBenchmark: Sendable {
    public let connection: LocalWorkerConnection
    public let modelIdentifier: String
    public let parameters: LocalGenerationParameters
    public let configuration: LocalBenchmarkConfiguration
    public let environment: LocalBenchmarkEnvironment
    public var loadMilliseconds: [String: Double] = [:]

    public init(connection: LocalWorkerConnection, modelIdentifier: String, parameters: LocalGenerationParameters,
                configuration: LocalBenchmarkConfiguration, environment: LocalBenchmarkEnvironment) {
        self.connection = connection; self.modelIdentifier = modelIdentifier; self.parameters = parameters
        self.configuration = configuration; self.environment = environment
    }

    public func run(cases: [LocalGenerationCase], progress: @Sendable (Int, Int) -> Void) async -> LocalBenchmarkRun {
        var run = LocalBenchmarkRun(environment: environment, configuration: configuration)
        run.loadMilliseconds = loadMilliseconds
        let repetitions = max(1, configuration.repetitions)
        let total = cases.count * repetitions
        var done = 0
        if let first = cases.first {
            for _ in 0..<max(0, configuration.warmUpRuns) {
                if Task.isCancelled { break }
                let warm = await measure(first, repetition: 0)
                if run.coldFirstMilliseconds["generation"] == nil, let ms = warm.hostCleanupMilliseconds { run.coldFirstMilliseconds["generation"] = ms }
            }
        }
        loop: for item in cases {
            for repetition in 0..<repetitions {
                if Task.isCancelled { break loop }
                let result = await measure(item, repetition: repetition)
                if result.failure == "canceled" && Task.isCancelled { break loop }
                if run.coldFirstMilliseconds["generation"] == nil, let ms = result.hostCleanupMilliseconds { run.coldFirstMilliseconds["generation"] = ms }
                run.results.append(result)
                done += 1
                progress(done, total)
            }
        }
        if !Task.isCancelled { run.memory = await BenchmarkSupport.memory(speech: nil, inference: connection) }
        run.summarize(references: [:])
        Self.addVisionSummary(&run)
        return run
    }

    private func measure(_ item: LocalGenerationCase, repetition: Int) async -> LocalBenchmarkSampleResult {
        var result = LocalBenchmarkSampleResult(sampleIdentifier: item.id, repetition: repetition)
        let command = LocalWorkerCommand.generate(request: UUID(), modelIdentifier: modelIdentifier, messages: item.messages,
                                                  parameters: parameters, hasImage: item.image != nil)
        do {
            let stage = try await LocalSpeechPipeline.run(connection, command, payload: item.image ?? Data())
            result.outputText = stage.text
            result.generationMetrics = stage.worker
            // hostCleanupMilliseconds doubles as the host-side generation time so the schema stays unchanged.
            result.hostCleanupMilliseconds = stage.hostMilliseconds
            if let expected = item.expectedBox {
                let score = LocalVisionScoring.score(output: stage.text, expected: expected)
                result.schemaCompliant = score.schemaCompliant
                result.targetHit = score.targetHit
                result.intersectionOverUnion = score.intersectionOverUnion
            }
        } catch { result.failure = BenchmarkSupport.failureCode(error) }
        return result
    }

    static func addVisionSummary(_ run: inout LocalBenchmarkRun) {
        let scored = run.results.filter { $0.failure == nil && $0.schemaCompliant != nil }
        guard !scored.isEmpty, var summary = run.summary else { return }
        let count = Double(scored.count)
        summary.schemaComplianceRate = Double(scored.filter { $0.schemaCompliant == true }.count) / count
        summary.targetAccuracy = Double(scored.filter { $0.targetHit == true }.count) / count
        summary.meanIntersectionOverUnion = scored.compactMap(\.intersectionOverUnion).reduce(0, +) / count
        run.summary = summary
    }
}

public typealias LocalTextBenchmark = LocalGenerationBenchmark
public typealias LocalVisionBenchmark = LocalGenerationBenchmark
