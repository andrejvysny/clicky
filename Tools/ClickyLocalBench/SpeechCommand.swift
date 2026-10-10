import ClickyCore
import Foundation

enum SpeechCommand {
    static let valued: Set<String> = ["recognizer", "cleanup", "prompt", "pipeline", "dataset", "manifest", "split", "ids", "ids-file", "count", "seed",
                                      "warmup", "repetitions", "priority", "worker", "models-root", "out", "observation", "personal-root"]
    static let defaultManifest = "~/workspace/voice-benchmark/data/disfluency_speech/test/full_manifest.csv"

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments, valued: valued)
        let pipelineName = options.one("pipeline") ?? ""
        let mode: LocalBenchmarkConfiguration.Pipeline
        switch pipelineName {
        case "asr": mode = .asrOnly
        case "asr+cleanup": mode = .asrWithCleanup
        case "cleanup-on-reference": mode = .cleanupOnReference
        default: throw CLIError("--pipeline must be asr, asr+cleanup or cleanup-on-reference.")
        }
        let store = LocalModelStore(root: BenchPaths.modelsRoot(options))
        let recognizer = mode == .cleanupOnReference ? nil : try installed(options.one("recognizer"), "--recognizer", .speech, store)
        let cleanup = mode == .asrOnly ? nil : try installed(options.one("cleanup"), "--cleanup", .cleanup, store)
        let prompt: LocalCleanupPrompt
        if let name = options.one("prompt") {
            guard let found = LocalCleanupPrompt.all.first(where: { $0.identifier == name }) else {
                throw CLIError("--prompt must be one of " + LocalCleanupPrompt.all.map(\.identifier).joined(separator: ", "))
            }
            prompt = found
        } else { prompt = .s1Mini }
        let priority = try parsePriority(options)

        let (samples, datasetName, datasetRevision, audio) = try loadSamples(options)
        guard !samples.isEmpty else { throw CLIError("No approved samples selected.") }

        let executable = try BenchRuntime.workerURL(options)
        var workers: [LocalWorkerConnection] = []
        defer { workers.forEach { $0.shutdown() } }
        var loads: [String: Double] = [:]
        var runtime: [String: String] = [:]
        var metal: String?
        var speechWorker: LocalWorkerConnection?, inferenceWorker: LocalWorkerConnection?
        if let recognizer {
            let started = try await BenchRuntime.start(.speech, executable: executable, priority: priority)
            workers.append(started.connection); speechWorker = started.connection
            runtime.merge(started.readiness.runtime) { $1 }; metal = started.readiness.metalDevice ?? metal
            loads[recognizer.entry.id] = try await BenchRuntime.load(started.connection, model: recognizer.model.reference)
        }
        if let cleanup {
            let started = try await BenchRuntime.start(.inference, executable: executable, priority: priority)
            workers.append(started.connection); inferenceWorker = started.connection
            runtime.merge(started.readiness.runtime) { $1 }; metal = started.readiness.metalDevice ?? metal
            loads[cleanup.entry.id] = try await BenchRuntime.load(started.connection, model: cleanup.model.reference)
        }
        guard let speechPipelineWorker = speechWorker ?? inferenceWorker else { throw CLIError("No worker to run.") }
        // cleanup-on-reference never transcribes, so the inference worker stands in for the unused speech slot.
        let pipeline = LocalSpeechPipeline(speech: speechPipelineWorker, recognizer: recognizer?.entry.id ?? "", inference: inferenceWorker,
                                           cleanupModel: cleanup?.entry.id, prompt: prompt)
        let configuration = LocalBenchmarkConfiguration(
            pipeline: mode, recognizer: recognizer.map { BenchRuntime.benchmarkModel($0.model, $0.entry) },
            cleanup: cleanup.map { BenchRuntime.benchmarkModel($0.model, $0.entry) }, promptIdentifier: cleanup == nil ? nil : prompt.identifier,
            warmUpRuns: try options.integer("warmup", default: 2) ?? 2, repetitions: max(1, try options.integer("repetitions", default: 1) ?? 1),
            workerPriority: priority.rawValue, dataset: datasetName, datasetRevision: datasetRevision)
        var benchmark = LocalSpeechBenchmark(pipeline: pipeline, configuration: configuration,
                                             environment: BenchRuntime.environment(worker: runtime, metalDevice: metal))
        benchmark.loadMilliseconds = loads
        benchmark.workerReuse = "fresh"
        let task = Task { await benchmark.run(samples: samples, audio: audio, progress: Self.progress) }
        let interrupt = InterruptHandler { task.cancel() }
        var run = await task.value
        _ = interrupt
        FileHandle.standardError.write(Data("\n".utf8))
        run.observations = options.many("observation")
        let file = try BenchRuntime.write(run, to: options.one("out"))
        BenchRuntime.printSummary(run, file: file)
    }

    static let progress: @Sendable (Int, Int) -> Void = { done, total in
        FileHandle.standardError.write(Data("\r  \(done)/\(total)".utf8))
    }

    static func parsePriority(_ options: Options) throws -> LocalWorkerPriority {
        guard let name = options.one("priority") else { return .standard }
        guard let priority = LocalWorkerPriority(rawValue: name) else { throw CLIError("--priority must be foreground-protected or default.") }
        return priority
    }

    struct InstalledModel { let entry: LocalModelCatalogEntry; let model: InstalledLocalModel }

    static func installed(_ id: String?, _ flag: String, _ group: LocalModelGroup, _ store: LocalModelStore) throws -> InstalledModel {
        guard let id else { throw CLIError("\(flag) <entry-id> is required for this pipeline.") }
        guard let entry = LocalModelCatalog.entry(id: id) else { throw CLIError("Unknown catalog entry \(id).") }
        guard entry.group == group else { throw CLIError("\(id) is a \(entry.group.rawValue) model, not \(group.rawValue).") }
        guard let model = store.installed(id) else { throw CLIError("\(id) is not installed. Run: clicky-local-bench models download \(id)") }
        return InstalledModel(entry: entry, model: model)
    }

    typealias Loaded = (samples: [LocalBenchmarkSample], name: String, revision: String?, audio: @Sendable (LocalBenchmarkSample) throws -> [Int16])

    static func loadSamples(_ options: Options) throws -> Loaded {
        let seed = UInt64(try options.integer("seed", default: 42) ?? 42)
        var ids: [String]? = options.many("ids").flatMap { $0.split(separator: ",").map(String.init) }
        if let file = options.one("ids-file") {
            let text = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
            ids = text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if ids?.isEmpty == true { ids = nil }
        let count = try options.integer("count")
        var split: LocalBenchmarkSample.Split?
        switch options.one("split") {
        case nil: split = nil
        case "development": split = .development
        case "held-out": split = .heldOut
        default: throw CLIError("--split must be development or held-out.")
        }
        switch options.one("dataset") {
        case "disfluency":
            let manifest = URL(fileURLWithPath: ((options.one("manifest") ?? defaultManifest) as NSString).expandingTildeInPath)
            let dataset = try LocalPublicDataset.loadDisfluency(manifest: manifest)
            let chosen = dataset.select(ids: ids, count: count, seed: seed).filter { split == nil || $0.split == split }
            let audio: @Sendable (LocalBenchmarkSample) throws -> [Int16] = { sample in
                let decoded = try WAVFile.read(dataset.url(for: sample))
                guard decoded.channels == 1, decoded.sampleRate == LocalWorkerProtocol.audioSampleRate else { throw LocalDatasetError.unsupportedAudio("Expected 16 kHz mono.") }
                return decoded.samples
            }
            return (chosen, dataset.name, dataset.revision, audio)
        case "personal":
            let root = options.one("personal-root").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? BenchPaths.personalRoot
            let dataset = LocalPersonalDataset(root: root)
            let approved = try dataset.samples().filter { $0.isApproved && (split == nil || $0.split == split) }
            let pool = LocalPublicDataset(name: "personal", revision: nil, samples: approved, root: root)
            return (pool.select(ids: ids, count: count, seed: seed), "personal", nil, { sample in try dataset.audio(for: sample) })
        default: throw CLIError("--dataset must be disfluency or personal.")
        }
    }
}
