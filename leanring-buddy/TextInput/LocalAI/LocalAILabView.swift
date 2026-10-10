import Combine
import AppKit
import SwiftUI

/// State shared by the Lab tabs. Everything lives in memory; closing the window cancels recording and running jobs.
@MainActor
final class LocalAILabModel: ObservableObject {
    let runtime: LocalAIRuntime
    let results = LabResults()
    lazy var text = LabTextModel(runtime: runtime, results: results)
    lazy var vision = LabVisionModel(runtime: runtime, results: results)
    lazy var speech = LabSpeechModel(runtime: runtime, results: results)

    init(runtime: LocalAIRuntime) { self.runtime = runtime }

    func windowClosed() {
        speech.cancelRecording()
        text.cancel(); vision.cancel(); speech.cancelProcessing()
    }
}

enum LabTab: String, CaseIterable, Identifiable {
    case text = "Text", vision = "Vision", speech = "Speech", models = "Models", results = "Results"
    var id: String { rawValue }
}

struct LocalAILabView: View {
    @ObservedObject var model: LocalAILabModel
    @ObservedObject private var runtime: LocalAIRuntime
    @State private var tab: LabTab = .models

    init(model: LocalAILabModel) {
        self.model = model
        runtime = model.runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            LabHeader(runtime: runtime)
            Picker("", selection: $tab) {
                ForEach(LabTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                Group {
                    switch tab {
                    case .text: LabTextTab(model: model.text, runtime: runtime)
                    case .vision: LabVisionTab(model: model.vision, runtime: runtime)
                    case .speech: LabSpeechTab(model: model.speech, runtime: runtime)
                    case .models: LabModelsTab(runtime: runtime)
                    case .results: LabResultsTab(results: model.results)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .background(ClickyChrome.panel)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 520)
        .accessibilityIdentifier("localAILab")
    }
}

/// Worker states and clearly labeled measurements. Numbers update only on Refresh or after a run, never in the background.
struct LabHeader: View {
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach([LocalWorkerRole.inference, .speech], id: \.rawValue) { role in
                    HStack(spacing: 5) {
                        StatusDot(color: color(runtime.workers[role]), outlined: runtime.workers[role] == .stopped)
                        Text("\(role == .inference ? "Inference" : "Speech") worker: \(label(runtime.workers[role]))").font(.system(size: 11))
                    }
                    .help(detail(runtime.workers[role]))
                }
                Spacer()
                Button("Refresh") { Task { await runtime.refreshMemory() } }.islandButton(.secondary)
                Button("Clear caches") { Task { await runtime.clearCaches(); await runtime.refreshMemory() } }.islandButton(.secondary)
            }
            let snapshot = runtime.memory
            let inference = snapshot.workers[.inference], speech = snapshot.workers[.speech]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 4) {
                measure("Worker memory (phys_footprint)",
                        "inference \(LabFormat.megabytes(inference?.physicalFootprintBytes)) · speech \(LabFormat.megabytes(speech?.physicalFootprintBytes))")
                measure("MLX active / peak",
                        "\(LabFormat.megabytes(inference?.mlxActiveBytes)) / \(LabFormat.megabytes(inference?.mlxPeakBytes))")
                measure("Host memory", LabFormat.megabytes(snapshot.hostFootprintBytes == 0 ? nil : snapshot.hostFootprintBytes))
                measure("System pressure", snapshot.pressure.rawValue)
                measure("Thermal", Self.thermal(snapshot.thermal))
            }
            Text(snapshot.measuredAt.map { "Measured \($0.formatted(date: .omitted, time: .standard)). Press Refresh to measure again." }
                 ?? "Not measured yet. Press Refresh; workers are asked only for their own memory.")
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(DS.Colors.surface1)
    }

    private func measure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func label(_ state: LocalAIRuntime.WorkerState?) -> String {
        switch state {
        case .starting: return "starting"
        case .ready: return "ready"
        case .failed: return "failed"
        default: return "stopped"
        }
    }

    private func detail(_ state: LocalAIRuntime.WorkerState?) -> String {
        switch state {
        case .failed(let message): return message
        case .ready(let readiness): return "pid \(readiness.processIdentifier) · network denied: \(readiness.networkDenied ? "yes" : "no") · \(readiness.metalDevice ?? "no Metal device")"
        default: return label(state)
        }
    }

    private func color(_ state: LocalAIRuntime.WorkerState?) -> Color {
        switch state {
        case .ready: return DS.Colors.success
        case .starting: return DS.Colors.info
        case .failed: return DS.Colors.warningText
        default: return DS.Colors.textTertiary
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
