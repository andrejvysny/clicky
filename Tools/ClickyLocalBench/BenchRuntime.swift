import ClickyCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BenchPaths {
    static var supportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clicky", isDirectory: true)
    }
    static func modelsRoot(_ options: Options) -> URL {
        options.one("models-root").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? supportRoot.appendingPathComponent("Models", isDirectory: true)
    }
    static var personalRoot: URL { supportRoot.appendingPathComponent("Benchmarks/personal", isDirectory: true) }
    static var resultsRoot: URL { supportRoot.appendingPathComponent("Benchmarks/results", isDirectory: true) }
}

/// SIGINT cancels the running task instead of killing the process, so partial results are still written.
final class InterruptHandler {
    private let source: DispatchSourceSignal
    init(_ onInterrupt: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: onInterrupt)
        source.resume()
    }
    deinit { source.cancel(); signal(SIGINT, SIG_DFL) }
}

enum BenchRuntime {
    static func shell(_ arguments: [String], in directory: URL? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func environment(worker: [String: String], metalDevice: String?) -> LocalBenchmarkEnvironment {
        var commit = "unknown"
        if let head = shell(["git", "rev-parse", "--short", "HEAD"]) {
            commit = head
            if let status = shell(["git", "status", "--porcelain"]), !status.isEmpty { commit += "-dirty" }
        }
        let hardware = [sysctlString("hw.model"), sysctlString("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: " / ")
        return LocalBenchmarkEnvironment(commit: commit, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                         hardware: hardware.isEmpty ? "unknown" : hardware,
                                         physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, worker: worker, metalDevice: metalDevice)
    }

    static func workerURL(_ options: Options) throws -> URL {
        if let explicit = options.one("worker") {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError("Worker not executable: \(url.path)") }
            return url
        }
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let top = shell(["git", "rev-parse", "--show-toplevel"]) { candidates.append(URL(fileURLWithPath: top)) }
        for base in candidates {
            let url = base.appendingPathComponent("build/local-worker/clicky-local-worker")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw CLIError("Local worker not found at build/local-worker/clicky-local-worker. Build it with scripts/build-local-worker.sh (needs the Metal toolchain) or pass --worker <path>.")
    }

    struct StartedWorker { let connection: LocalWorkerConnection; let readiness: LocalWorkerReadiness }

    static func start(_ role: LocalWorkerRole, executable: URL, priority: LocalWorkerPriority) async throws -> StartedWorker {
        let connection = LocalWorkerConnection(executable: executable, role: role, arguments: ["--role", role.rawValue],
                                               environment: ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()])
        do {
            let readiness = try await connection.start()
            if !priority.apply(to: readiness.processIdentifier) {
                FileHandle.standardError.write(Data("warning: could not set \(priority.rawValue) priority on the \(role.rawValue) worker\n".utf8))
            }
            return StartedWorker(connection: connection, readiness: readiness)
        } catch let error as LocalWorkerError {
            throw CLIError("\(role.rawValue) worker failed to start (\(error.code.rawValue)): \(error.message) \(connection.diagnosticTail.suffix(300))")
        }
    }

    /// Loads without warm-up and returns the host-measured load time.
    static func load(_ worker: LocalWorkerConnection, model: LocalModelReference) async throws -> Double {
        do {
            return try await LocalSpeechPipeline.run(worker, .load(request: UUID(), model: model, warmUp: false)).hostMilliseconds
        } catch let error as LocalWorkerError {
            throw CLIError("Loading \(model.identifier) failed (\(error.code.rawValue)): \(error.message)")
        }
    }

    static func benchmarkModel(_ installed: InstalledLocalModel, _ entry: LocalModelCatalogEntry) -> LocalBenchmarkModel {
        LocalBenchmarkModel(identifier: entry.id, revision: installed.revision, fingerprint: installed.fingerprint, kind: entry.kind, quantization: entry.quantization)
    }

    static func write(_ run: LocalBenchmarkRun, to explicit: String?) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url: URL
        if let explicit {
            url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            url = BenchPaths.resultsRoot.appendingPathComponent("\(formatter.string(from: run.startedAt))-\(run.configuration.pipeline.rawValue).json")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(run).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func printSummary(_ run: LocalBenchmarkRun, file: URL) {
        func rate(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "-" }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "n/a" }
        let summary = run.summary ?? LocalBenchmarkSummary(samples: run.results.count, failures: 0)
        print("pipeline        \(run.configuration.pipeline.rawValue)  dataset \(run.configuration.dataset)  priority \(run.configuration.workerPriority)")
        print("samples         \(summary.samples)  failures \(summary.failures)  warm-ups \(run.configuration.warmUpRuns)  repetitions \(run.configuration.repetitions)")
        if run.configuration.pipeline != .text && run.configuration.pipeline != .vision {
            print("WER (corpus)    raw \(rate(summary.corpusRawWordErrorRate))  clean \(rate(summary.corpusCleanWordErrorRate))  clean CER \(rate(summary.corpusCleanCharacterErrorRate))")
            let verdicts = summary.verdictCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("gate verdicts   \(verdicts.isEmpty ? "-" : verdicts)")
            print("stop-to-final   P50 \(ms(summary.stopToFinalP50))  P95 \(ms(summary.stopToFinalP95)) ms (needs >= 5 samples)")
        } else {
            let times = run.results.filter { $0.failure == nil }.compactMap(\.hostCleanupMilliseconds)
            print("generation      P50 \(times.count >= 5 ? ms(SpeechMetrics.percentile(times, 50)) : "n/a")  P95 \(times.count >= 5 ? ms(SpeechMetrics.percentile(times, 95)) : "n/a") ms (needs >= 5 samples)")
            if run.configuration.pipeline == .vision {
                print("vision          schema \(rate(summary.schemaComplianceRate))  target \(rate(summary.targetAccuracy))  mean IoU \(rate(summary.meanIntersectionOverUnion))")
            }
        }
        print("load ms         " + (run.loadMilliseconds.isEmpty ? "-" : run.loadMilliseconds.sorted { $0.key < $1.key }.map { "\($0.key)=\(ms($0.value))" }.joined(separator: " ")))
        print("cold first ms   " + (run.coldFirstMilliseconds.isEmpty ? "-" : run.coldFirstMilliseconds.sorted { $0.key < $1.key }.map { "\($0.key)=\(ms($0.value))" }.joined(separator: " ")))
        let megabytes = run.memory.combinedPeakFootprintBytes.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "-"
        print("combined peak   \(megabytes) (both workers resident together)")
        print("result file     \(file.path)")
    }
}
