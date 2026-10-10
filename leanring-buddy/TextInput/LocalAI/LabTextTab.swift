import Combine
import SwiftUI

/// One streamed generation through the runtime's tracked job path, shared by the Text and Vision tabs.
enum LabGeneration {
    struct Output {
        var text: String
        var worker: LocalRunMetrics
        var metrics: LabRunMetrics
    }

    @MainActor
    static func run(runtime: LocalAIRuntime, group: LocalModelGroup, messages: [LocalChatMessage], image: Data?,
                    parameters: LocalGenerationParameters, onDelta: @escaping (String) -> Void) async throws -> Output {
        try await runtime.ensureReady(group, explicitRun: false)
        let clock = ContinuousClock()
        let start = clock.now
        var final: (text: String, metrics: LocalRunMetrics)?
        for try await event in runtime.generate(group: group, messages: messages, imagePNG: image, parameters: parameters) {
            switch event {
            case .delta(_, _, let piece): onDelta(piece)
            case .completed(_, _, let text, let metrics): final = (text, metrics)
            default: break
            }
        }
        try Task.checkCancellation()
        guard let final else { throw LocalWorkerError(.internalError, "Worker ended the request without a result.") }
        let elapsed = clock.now - start
        let host = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let load = runtime.groups[group]?.loadMilliseconds
        return Output(text: final.text, worker: final.metrics, metrics: LabRunMetrics(worker: final.metrics, host: host, load: load))
    }
}

@MainActor
final class LabTextModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case ordinary = "Ordinary", draft = "Draft", rewrite = "Rewrite"
        var id: String { rawValue }
    }

    enum ParsedReply: Equatable {
        case draft(text: String, subject: String?)
        case clarification(String)
        case failure(String)
    }

    let runtime: LocalAIRuntime
    let results: LabResults
    @Published var mode: Mode = .ordinary
    @Published var prompt = ""
    @Published var source = ""
    @Published var maximumTokens = 256
    @Published var temperature = 0.0
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var metrics: LabRunMetrics?
    @Published private(set) var parsed: ParsedReply?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(runtime: LocalAIRuntime, results: LabResults) { self.runtime = runtime; self.results = results }

    var canRun: Bool {
        !running && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode != .rewrite || !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Draft and Rewrite use the production writing prompt and host payload, so the Lab measures what Writing would send.
    func messages() -> [LocalChatMessage] {
        guard mode != .ordinary else { return [LocalChatMessage(role: .user, text: prompt)] }
        let payload = WritingHostPayload(operation: mode == .draft ? .draft : .rewrite, source: mode == .rewrite ? source : nil, destination: .none)
        let request = GuideHostRequest(purpose: .writing, text: prompt, task: nil, capture: nil, writing: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [LocalChatMessage(role: .system, text: WritingPrompt.prompt), LocalChatMessage(role: .user, text: json)]
    }

    func run() {
        guard canRun else { return }
        let token = UUID()
        generation = token
        output = ""; errorMessage = nil; metrics = nil; parsed = nil
        running = true
        let requested = messages()
        let parameters = LocalGenerationParameters(maximumTokens: maximumTokens, temperature: temperature)
        let mode = self.mode
        task = Task {
            do {
                let result = try await LabGeneration.run(runtime: runtime, group: .vision, messages: requested, image: nil, parameters: parameters) { [weak self] piece in
                    guard let self, generation == token else { return }
                    output += piece
                }
                guard generation == token else { return }
                output = result.text
                metrics = result.metrics
                if mode != .ordinary { parsed = Self.parseWritingReply(result.text) }
                results.record(runtime: runtime, pipeline: .text, groups: [.vision],
                               promptIdentifier: mode == .ordinary ? "lab-text-ordinary" : WritingPrompt.promptVersion, parameters: parameters) {
                    $0.outputText = result.text; $0.generationMetrics = result.worker
                }
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError) {
                    errorMessage = LocalAIRuntime.describe(error)
                    results.record(runtime: runtime, pipeline: .text, groups: [.vision], promptIdentifier: nil, parameters: parameters) {
                        $0.failure = LocalAIRuntime.describe(error)
                    }
                }
            }
            if generation == token { running = false }
        }
    }

    func cancel() {
        task?.cancel()
        generation = UUID()
        running = false
    }

    static func parseWritingReply(_ output: String) -> ParsedReply {
        guard let data = LabJSON.firstObject(in: output) else { return .failure("The reply contains no JSON object.") }
        do {
            switch try WritingReply(try GuidePresentation.parseResponse(data, purpose: .writing)) {
            case .draft(let text, let subject): return .draft(text: text, subject: subject)
            case .clarification(let text): return .clarification(text)
            }
        } catch { return .failure(error.localizedDescription) }
    }
}

struct LabTextTab: View {
    @ObservedObject var model: LabTextModel
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabCard(title: "Text test · \(runtime.displayName(.vision))") {
                Picker("", selection: $model.mode) { ForEach(LabTextModel.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).disabled(model.running)
                labNote(modeNote)
                editor(model.mode == .ordinary ? "Prompt" : "Instruction", text: $model.prompt, height: 80)
                if model.mode == .rewrite { editor("Source text to rewrite", text: $model.source, height: 80) }
                HStack(spacing: 18) {
                    Stepper("Max tokens: \(model.maximumTokens)", value: $model.maximumTokens, in: 16...LocalWorkerProtocol.maximumOutputTokens, step: 64)
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        Text("Temperature \(model.temperature, specifier: "%.1f")").font(.system(size: 12))
                        Slider(value: $model.temperature, in: 0...1.5, step: 0.1).frame(width: 120)
                    }
                    Spacer()
                    if model.running { Button("Cancel") { model.cancel() }.islandButton(.warning) }
                    else { Button("Run") { model.run() }.islandButton(.primary).disabled(!model.canRun) }
                }
                if let error = model.errorMessage {
                    labError(error)
                    if error.hasPrefix("Load "), runtime.installedModel(.vision) != nil {
                        Button("Load \(runtime.displayName(.vision))") { Task { try? await runtime.load(.vision) } }.islandButton(.secondary)
                    }
                }
            }
            LabCard(title: "Output") {
                LabOutputBox(text: model.output)
                if let parsed = model.parsed { parsedView(parsed) }
                HStack {
                    Button("Copy") { labCopy(copyText) }.islandButton(.secondary).disabled(copyText.isEmpty)
                    labNote("Copy only. The Lab never pastes or submits text anywhere.")
                }
                if let metrics = model.metrics { LabMetricsView(metrics: metrics) }
            }
        }
    }

    private var copyText: String {
        if case .draft(let text, _)? = model.parsed { return text }
        return model.output
    }

    private var modeNote: String {
        switch model.mode {
        case .ordinary: return "A free prompt to the vision model, text only."
        case .draft: return "Uses the production writing prompt and host payload (\(WritingPrompt.promptVersion)); the reply is parsed like a Writing draft."
        case .rewrite: return "Same as Draft, with your source text as writing.source."
        }
    }

    @ViewBuilder private func parsedView(_ parsed: LabTextModel.ParsedReply) -> some View {
        switch parsed {
        case .draft(let text, let subject):
            VStack(alignment: .leading, spacing: 4) {
                Text("Parsed draft").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.success)
                if let subject { Text("Subject: \(subject)").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary) }
                LabOutputBox(text: text, minHeight: 50)
            }
        case .clarification(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Parsed clarification (would not be inserted)").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.info)
                Text(text).font(.system(size: 12)).textSelection(.enabled)
            }
        case .failure(let message):
            labError("Parse failure: \(message)")
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: height)
                .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
                .disabled(model.running)
        }
    }
}
