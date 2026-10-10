import UniformTypeIdentifiers
import Combine
import AppKit
import SwiftUI

/// This session's Lab runs, in memory only. Nothing is written until the user chooses Export JSON.
@MainActor
final class LabResults: ObservableObject {
    @Published private(set) var runs: [LocalBenchmarkRun] = []

    /// Records one run with one result. `fill` sets the measured fields; the model identities and environment come from the runtime.
    func record(runtime: LocalAIRuntime, pipeline: LocalBenchmarkConfiguration.Pipeline, groups: [LocalModelGroup],
                promptIdentifier: String?, parameters: LocalGenerationParameters?, fill: (inout LocalBenchmarkSampleResult) -> Void) {
        func model(_ group: LocalModelGroup) -> LocalBenchmarkModel? {
            guard groups.contains(group), let reference = runtime.loadedReference(group), let entry = runtime.selectedEntry(group) else { return nil }
            return LocalBenchmarkModel(identifier: reference.identifier, revision: reference.revision, fingerprint: reference.fingerprint,
                                       kind: reference.kind, quantization: entry.quantization)
        }
        let configuration = LocalBenchmarkConfiguration(
            pipeline: pipeline, recognizer: model(.speech), cleanup: model(.cleanup), generator: model(.vision),
            promptIdentifier: promptIdentifier, parameters: parameters, warmUpRuns: 0, repetitions: 1,
            workerPriority: runtime.protectForeground ? LocalWorkerPriority.foregroundProtected.rawValue : LocalWorkerPriority.standard.rawValue,
            dataset: "lab-session")
        var run = LocalBenchmarkRun(environment: Self.environment(runtime), configuration: configuration)
        run.memory.workerReuse = "reused"
        var result = LocalBenchmarkSampleResult(sampleIdentifier: "lab-\(runs.count + 1)", repetition: 0)
        fill(&result)
        run.results = [result]
        for group in groups { if let load = runtime.groups[group]?.loadMilliseconds { run.loadMilliseconds[group.rawValue] = load } }
        run.summarize(references: [:])
        runs.append(run)
    }

    func clear() { runs = [] }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(runs)
    }

    private static func environment(_ runtime: LocalAIRuntime) -> LocalBenchmarkEnvironment {
        var worker: [String: String] = [:]
        var metal: String?
        for role in [LocalWorkerRole.inference, .speech] {
            guard let readiness = runtime.readiness(for: role) else { continue }
            for (key, value) in readiness.runtime { worker[key] = value }
            metal = metal ?? readiness.metalDevice
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return LocalBenchmarkEnvironment(commit: "app-\(version)", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                         hardware: String(cString: buffer), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                                         worker: worker, metalDevice: metal)
    }
}

struct LabResultsTab: View {
    @ObservedObject var results: LabResults
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabCard(title: "Session runs") {
                HStack(spacing: 8) {
                    Button("Export JSON…") { export() }.islandButton(.primary).disabled(results.runs.isEmpty)
                    Button("Clear") { results.clear(); message = nil }.islandButton(.secondary).disabled(results.runs.isEmpty)
                    Spacer()
                    Text("\(results.runs.count) run\(results.runs.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                }
                labNote("Runs stay in memory until you quit or press Clear. Export JSON writes only where you choose. It includes model outputs and, for Speech runs, the transcripts of your recordings; it never includes audio or images.")
                if let message { labNote(message) }
            }
            if results.runs.isEmpty {
                labNote("No runs yet. Run a test in the Text, Vision or Speech tab.")
            }
            ForEach(Array(results.runs.enumerated().reversed()), id: \.element.identifier) { index, run in
                LabCard(title: "Run \(index + 1) · \(run.configuration.pipeline.rawValue)") {
                    ForEach(run.results, id: \.sampleIdentifier) { result in
                        if let failure = result.failure { labError(failure) }
                        let line = [run.configuration.generator, run.configuration.recognizer, run.configuration.cleanup]
                            .compactMap { $0 }.map { "\($0.identifier) (\($0.quantization), rev \($0.revision.prefix(7)))" }.joined(separator: " · ")
                        Text(line).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                        Text(timings(result)).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary)
                    }
                    Text("\(run.environment.hardware) · \(run.environment.operatingSystem) · \(LabFormat.megabytes(run.environment.physicalMemoryBytes)) · priority \(run.configuration.workerPriority)")
                        .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func timings(_ result: LocalBenchmarkSampleResult) -> String {
        var parts: [String] = []
        if let metrics = result.generationMetrics { parts.append("worker \(LabFormat.milliseconds(metrics.totalMilliseconds))") }
        if let host = result.hostRecognizerMilliseconds { parts.append("ASR host \(LabFormat.milliseconds(host))") }
        if let host = result.hostCleanupMilliseconds { parts.append("cleanup host \(LabFormat.milliseconds(host))") }
        if let stop = result.stopToFinalMilliseconds { parts.append("pipeline \(LabFormat.milliseconds(stop))") }
        if let verdict = result.gateVerdict { parts.append("gate \(verdict.rawValue)") }
        return parts.isEmpty ? "no timings" : parts.joined(separator: " · ")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clicky-lab-results.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try results.exportData().write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }
}
