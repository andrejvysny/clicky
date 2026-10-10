import ClickyCore
import Foundation

/// `text` and `vision` subcommands: one inference worker, one model, generate requests.
enum GenerationCommand {
    static let valued: Set<String> = ["model", "prompt-file", "max-tokens", "count", "seed", "warmup", "repetitions", "priority", "worker",
                                      "models-root", "out", "observation"]

    static func run(vision: Bool, _ arguments: [String]) async throws {
        let options = try Options(arguments, valued: valued)
        let store = LocalModelStore(root: BenchPaths.modelsRoot(options))
        let model = try SpeechCommand.installed(options.one("model"), "--model", .vision, store)
        var cases: [LocalGenerationCase] = []
        var maximumTokens = try options.integer("max-tokens", default: vision ? 128 : 512, minimum: 1) ?? 512
        if vision {
            #if canImport(CoreGraphics)
            let count = try options.integer("count", default: 5, minimum: 1) ?? 5
            cases = try SyntheticVision.cases(count: count, seed: UInt64(try options.integer("seed", default: 42) ?? 42))
            #else
            throw CLIError("The vision benchmark needs CoreGraphics (macOS).")
            #endif
        } else {
            guard let file = options.one("prompt-file") else { throw CLIError("--prompt-file <file> is required for text.") }
            let prompt = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
            guard !prompt.isEmpty, prompt.count <= LocalWorkerProtocol.maximumPromptCharacters else { throw CLIError("Prompt file must be 1...\(LocalWorkerProtocol.maximumPromptCharacters) characters.") }
            cases = [LocalGenerationCase(id: "prompt", messages: [LocalChatMessage(role: .user, text: prompt)])]
        }
        maximumTokens = min(maximumTokens, LocalWorkerProtocol.maximumOutputTokens)
        let priority = try SpeechCommand.parsePriority(options)
        let executable = try BenchRuntime.workerURL(options)
        let started = try await BenchRuntime.start(.inference, executable: executable, priority: priority)
        defer { started.connection.shutdown() }
        let loadMilliseconds = try await BenchRuntime.load(started.connection, model: model.model.reference)
        let parameters = LocalGenerationParameters(maximumTokens: maximumTokens, temperature: 0, topP: 1, seed: 42, maximumImageSide: 1280)
        let configuration = LocalBenchmarkConfiguration(
            pipeline: vision ? .vision : .text, generator: BenchRuntime.benchmarkModel(model.model, model.entry), parameters: parameters,
            warmUpRuns: try options.integer("warmup", default: 1) ?? 1, repetitions: max(1, try options.integer("repetitions", default: 1) ?? 1),
            workerPriority: priority.rawValue, dataset: vision ? "synthetic-buttons" : "prompt-file")
        var benchmark = LocalGenerationBenchmark(connection: started.connection, modelIdentifier: model.entry.id, parameters: parameters,
                                                 configuration: configuration,
                                                 environment: BenchRuntime.environment(worker: started.readiness.runtime, metalDevice: started.readiness.metalDevice))
        benchmark.loadMilliseconds = [model.entry.id: loadMilliseconds]
        benchmark.workerReuse = "fresh"
        let caseList = cases
        let task = Task { await benchmark.run(cases: caseList, progress: SpeechCommand.progress) }
        let interrupt = InterruptHandler { task.cancel() }
        var run = await task.value
        _ = interrupt
        FileHandle.standardError.write(Data("\n".utf8))
        run.observations = options.many("observation")
        let file = try BenchRuntime.write(run, to: options.one("out"))
        BenchRuntime.printSummary(run, file: file)
    }
}
