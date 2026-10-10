import AppKit
import SwiftUI

/// Small building blocks shared by the Lab tabs, in the dark Clicky style.
struct LabCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(DS.Colors.textTertiary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

func labNote(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
}

func labError(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
}

/// Selectable monospaced output, scrollable, for streamed model text.
struct LabOutputBox: View {
    let text: String
    var placeholder = "Output appears here."
    var minHeight: CGFloat = 90

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(text.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: minHeight, maxHeight: 220)
        .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

func labCopy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

enum LabFormat {
    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.0f ms", value)
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "–" }
        return bytes >= 1 << 30 ? String(format: "%.2f GB", Double(bytes) / Double(1 << 30)) : String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
    }

    static func size(_ bytes: Int64) -> String { megabytes(UInt64(max(0, bytes))) }
}

/// Everything measured for one generation, as the worker reported it plus the host's end-to-end time.
struct LabRunMetrics: Equatable {
    var loadMilliseconds: Double?
    var preprocessMilliseconds: Double?
    var firstTokenMilliseconds: Double?
    var workerMilliseconds: Double?
    var hostMilliseconds: Double?
    var promptTokens: Int?
    var generatedTokens: Int?
    var memory: LocalMemoryReport?

    init(worker: LocalRunMetrics?, host: Double?, load: Double?) {
        loadMilliseconds = load ?? worker?.loadMilliseconds
        preprocessMilliseconds = worker?.preprocessMilliseconds
        firstTokenMilliseconds = worker?.firstTokenMilliseconds
        workerMilliseconds = worker?.totalMilliseconds
        hostMilliseconds = host
        promptTokens = worker?.promptTokens
        generatedTokens = worker?.generatedTokens
        memory = worker?.memory
    }

    /// Decode speed: generated tokens over the time after the first token.
    var tokensPerSecond: Double? {
        guard let generated = generatedTokens, generated > 1, let total = workerMilliseconds, total > 0 else { return nil }
        guard let first = firstTokenMilliseconds else { return Double(generated) / (total / 1000) }
        let decode = total - first
        return decode > 0 ? Double(generated - 1) / (decode / 1000) : nil
    }
}

struct LabMetricsView: View {
    let metrics: LabRunMetrics

    var body: some View {
        let rows: [(String, String)] = [
            ("Load", LabFormat.milliseconds(metrics.loadMilliseconds)),
            ("Preprocess", LabFormat.milliseconds(metrics.preprocessMilliseconds)),
            ("First token", LabFormat.milliseconds(metrics.firstTokenMilliseconds)),
            ("Worker total", LabFormat.milliseconds(metrics.workerMilliseconds)),
            ("Host end-to-end", LabFormat.milliseconds(metrics.hostMilliseconds)),
            ("Prompt tokens", metrics.promptTokens.map(String.init) ?? "–"),
            ("Generated tokens", metrics.generatedTokens.map(String.init) ?? "–"),
            ("Decode tokens/s", metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "–"),
            ("Worker memory (phys_footprint)", LabFormat.megabytes(metrics.memory?.physicalFootprintBytes)),
        ]
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                    Text(row.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.Colors.textPrimary)
                }
            }
        }
    }
}

struct LabPhaseBadge: View {
    let phase: LocalAIRuntime.Phase
    var progress: Double?

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, outlined: phase == .missing)
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
        .help(detail)
    }

    private var label: String {
        switch phase {
        case .missing: return "Missing"
        case .downloading: return progress.map { "Downloading \(Int($0 * 100))%" } ?? "Importing…"
        case .installed: return "Installed"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .running: return "Running"
        case .canceling: return "Canceling"
        case .unloading: return "Unloading"
        case .failed: return "Failed"
        }
    }

    private var detail: String { if case .failed(let message) = phase { return message }; return label }

    private var color: Color {
        switch phase {
        case .missing, .installed: return DS.Colors.textSecondary
        case .downloading, .loading, .canceling, .unloading: return DS.Colors.info
        case .ready: return DS.Colors.success
        case .running: return DS.Colors.accentText
        case .failed: return DS.Colors.warningText
        }
    }
}
