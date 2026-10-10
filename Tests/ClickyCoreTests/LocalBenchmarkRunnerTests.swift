import XCTest
@testable import ClickyCore

final class LocalBenchmarkRunnerTests: XCTestCase {
    private func worker(_ role: LocalWorkerRole) async throws -> LocalWorkerConnection {
        let url = Bundle(for: LocalBenchmarkRunnerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clicky-fake-worker")
        let connection = LocalWorkerConnection(executable: url, role: role, arguments: ["--role", role.rawValue, "--behavior", "normal"],
                                               environment: [:], handshakeTimeout: 4, cancelGrace: 1)
        addTeardownBlock { connection.terminate() }
        _ = try await connection.start()
        return connection
    }

    private let environment = LocalBenchmarkEnvironment(commit: "test", operatingSystem: "os", hardware: "hw", physicalMemoryBytes: 1, worker: [:], metalDevice: nil)

    private func configuration(_ pipeline: LocalBenchmarkConfiguration.Pipeline, warmUp: Int = 0, repetitions: Int = 1) -> LocalBenchmarkConfiguration {
        LocalBenchmarkConfiguration(pipeline: pipeline, warmUpRuns: warmUp, repetitions: repetitions, workerPriority: "default", dataset: "test")
    }

    private func samples(_ count: Int) -> [LocalBenchmarkSample] {
        (0..<count).map {
            LocalBenchmarkSample(id: "s\($0)", audioFile: "s\($0).wav", rawReference: "um hello there", cleanReference: "hello there",
                                 split: .heldOut, approvedAt: Date(timeIntervalSince1970: 0))
        }
    }

    private func benchmark(_ pipeline: LocalBenchmarkConfiguration.Pipeline, warmUp: Int = 0, repetitions: Int = 1) async throws -> LocalSpeechBenchmark {
        let speech = try await worker(.speech)
        let inference = try await worker(.inference)
        let cleaner = LocalSpeechPipeline(speech: speech, recognizer: "asr", inference: inference, cleanupModel: "clean")
        return LocalSpeechBenchmark(pipeline: cleaner, configuration: configuration(pipeline, warmUp: warmUp, repetitions: repetitions), environment: environment)
    }

    private let pcm: @Sendable (LocalBenchmarkSample) throws -> [Int16] = { _ in [Int16](repeating: 100, count: 1600) }

    func testAsrOnlyScoresRawAndCleanAndSummarizesPercentilesOnlyFromFive() async throws {
        let run = await (try await benchmark(.asrOnly)).run(samples: samples(5), audio: pcm, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 5)
        XCTAssertTrue(run.results.allSatisfy { $0.rawText == "samples=1600" && $0.cleanedText == nil && $0.failure == nil })
        XCTAssertNotNil(run.results[0].rawWordErrorRate)
        XCTAssertNotNil(run.summary?.corpusRawWordErrorRate)
        XCTAssertNotNil(run.summary?.stopToFinalP50)
        XCTAssertNotNil(run.memory.speechWorker)
        XCTAssertEqual(run.memory.combinedPeakFootprintBytes, 1234 + 0 + (run.memory.inferenceWorker?.physicalFootprintBytes ?? 0))
        let small = await (try await benchmark(.asrOnly)).run(samples: samples(4), audio: pcm, progress: { _, _ in })
        XCTAssertNil(small.summary?.stopToFinalP50)
        XCTAssertEqual(small.summary?.samples, 4)
    }

    func testAsrWithCleanupRecordsGateAndSingleSpan() async throws {
        let run = await (try await benchmark(.asrWithCleanup)).run(samples: samples(2), audio: pcm, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 2)
        let first = run.results[0]
        XCTAssertEqual(first.cleanedText, "abc")
        XCTAssertNotNil(first.gateVerdict)
        let parts = (first.hostRecognizerMilliseconds ?? 0) + (first.hostCleanupMilliseconds ?? 0)
        XCTAssertGreaterThanOrEqual(first.stopToFinalMilliseconds ?? 0, parts)
        XCTAssertNotNil(first.cleanWordErrorRate)
        XCTAssertNotNil(run.coldFirstMilliseconds["recognizer"])
        XCTAssertNotNil(run.coldFirstMilliseconds["cleanup"])
        XCTAssertEqual(run.summary?.verdictCounts.values.reduce(0, +), 2)
    }

    func testCleanupOnReferenceSkipsAsr() async throws {
        let run = await (try await benchmark(.cleanupOnReference)).run(samples: samples(2), audio: { _ in throw LocalDatasetError.io("unused") }, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 2)
        XCTAssertTrue(run.results.allSatisfy { $0.failure == nil && $0.rawText == nil && $0.cleanedText == "abc" && $0.hostRecognizerMilliseconds == nil })
        XCTAssertNil(run.memory.speechWorker)
    }

    func testWarmUpsAreExcludedButColdFirstIsKept() async throws {
        let run = await (try await benchmark(.asrOnly, warmUp: 2)).run(samples: samples(2), audio: pcm, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 2)
        XCTAssertNotNil(run.coldFirstMilliseconds["recognizer"])
        XCTAssertEqual(run.configuration.warmUpRuns, 2)
    }

    func testRepetitionsAreRecordedPerSample() async throws {
        let progressBox = ProgressBox()
        let run = await (try await benchmark(.asrOnly, repetitions: 3)).run(samples: samples(2), audio: pcm, progress: { done, total in progressBox.record(done, total) })
        XCTAssertEqual(run.results.map(\.repetition), [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(run.results.map(\.sampleIdentifier), ["s0", "s0", "s0", "s1", "s1", "s1"])
        XCTAssertEqual(progressBox.last, [6, 6])
    }

    func testPerSampleFailureContinuesWithCodeOnly() async throws {
        let run = await (try await benchmark(.asrOnly)).run(samples: samples(3), audio: { sample in
            if sample.id == "s1" { throw LocalDatasetError.io("secret path detail") }
            if sample.id == "s2" { return [Int16](repeating: 0, count: 16_000 * 301) }
            return [1, 2, 3]
        }, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 3)
        XCTAssertNil(run.results[0].failure)
        XCTAssertEqual(run.results[1].failure, "audioUnavailable")
        XCTAssertEqual(run.results[2].failure, "inputTooLarge")
        XCTAssertEqual(run.summary?.failures, 2)
    }

    func testCancellationReturnsPartialResults() async throws {
        let runner = try await benchmark(.asrOnly)
        let box = TaskBox()
        let task = Task { await runner.run(samples: samples(6), audio: { sample in
            if sample.id == "s2" { box.task?.cancel() }
            return [1, 2, 3]
        }, progress: { _, _ in }) }
        box.task = task
        let run = await task.value
        XCTAssertGreaterThanOrEqual(run.results.count, 2)
        XCTAssertLessThan(run.results.count, 6)
        XCTAssertNotNil(run.summary)
    }

    func testVisionScoringConvertsModelGridToPixels() {
        // 2000×500 image: grid x maps ×2, grid y maps ×0.5.
        let box = LocalVisionBox(label: "Save", x: 200, y: 50, width: 200, height: 20)
        let exact = LocalVisionScoring.score(output: "```json\n{\"label\":\"Save\",\"bbox_2d\":[100,100,200,140]}\n```", expected: box,
                                             imageWidth: 2000, imageHeight: 500)
        XCTAssertTrue(exact.schemaCompliant); XCTAssertTrue(exact.targetHit); XCTAssertEqual(exact.intersectionOverUnion, 1, accuracy: 1e-9)
        let off = LocalVisionScoring.score(output: #"{"label":"Save","bbox_2d":[800,800,810,810]}"#, expected: box, imageWidth: 2000, imageHeight: 500)
        XCTAssertTrue(off.schemaCompliant); XCTAssertFalse(off.targetHit); XCTAssertEqual(off.intersectionOverUnion, 0)
        XCTAssertFalse(LocalVisionScoring.score(output: "I think it is on the left", expected: box, imageWidth: 2000, imageHeight: 500).schemaCompliant)
        XCTAssertFalse(LocalVisionScoring.score(output: #"{"label":"Save","x":100,"y":100,"width":100,"height":40}"#, expected: box,
                                                imageWidth: 2000, imageHeight: 500).schemaCompliant)
        XCTAssertFalse(LocalVisionScoring.score(output: #"{"label":"Save","bbox_2d":[1,true,3,4]}"#, expected: box, imageWidth: 2000, imageHeight: 500).schemaCompliant)
    }

    func testGenerationBenchmarkRecordsMetricsAndSchemaFailure() async throws {
        let inference = try await worker(.inference)
        let box = LocalVisionBox(label: "Save", x: 1, y: 1, width: 2, height: 2)
        let runner = LocalGenerationBenchmark(connection: inference, modelIdentifier: "vlm", parameters: LocalGenerationParameters(),
                                              configuration: configuration(.vision, warmUp: 1, repetitions: 2), environment: environment)
        let cases = [LocalGenerationCase(id: "v0", messages: [LocalChatMessage(role: .user, text: "q")], image: Data([1, 2, 3]), expectedBox: box)]
        let run = await runner.run(cases: cases, progress: { _, _ in })
        XCTAssertEqual(run.results.count, 2)
        XCTAssertEqual(run.results[0].outputText, "abc")
        XCTAssertNotNil(run.results[0].generationMetrics)
        XCTAssertEqual(run.results[0].schemaCompliant, false)
        XCTAssertEqual(run.summary?.schemaComplianceRate, 0)
        XCTAssertNotNil(run.coldFirstMilliseconds["generation"])
        XCTAssertNotNil(run.memory.inferenceWorker)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ done: Int, _ total: Int) { lock.lock(); values = [done, total]; lock.unlock() }
    var last: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<LocalBenchmarkRun, Never>?
    var task: Task<LocalBenchmarkRun, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
