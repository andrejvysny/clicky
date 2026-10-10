import Combine
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Bounds a user-chosen image the way attachments are bounded: at most 4096 px per axis and 3 MiB of PNG, and
/// downscaled so the long side is at most 1568 px. The result lives in memory only.
enum LabImageLoader {
    nonisolated struct Prepared: Sendable {
        let png: Data
        let width: Int
        let height: Int
    }

    nonisolated enum LoadError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be read as an image."
            case .tooLarge: return "The image could not be reduced below 3 MiB."
            }
        }
    }

    nonisolated static let longSide = 1568

    nonisolated static func prepare(url: URL) throws -> Prepared {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoadError.unreadable
        }
        var side = min(longSide, max(image.width, image.height))
        while side >= 128 {
            let scale = min(1, Double(side) / Double(max(image.width, image.height)))
            let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
            if let png = encode(image, width: width, height: height), png.count <= PNGImageAttachment.maximumBytes,
               (try? PNGImageAttachment(data: png)) != nil {
                return Prepared(png: png, width: width, height: height)
            }
            side = Int(Double(side) * 0.75)
        }
        throw LoadError.tooLarge
    }

    private nonisolated static func encode(_ image: CGImage, width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

@MainActor
final class LabVisionModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case question = "Question", grounded = "Grounded target"
        var id: String { rawValue }
    }

    let runtime: LocalAIRuntime
    let results: LabResults
    @Published var mode: Mode = .question
    @Published var question = ""
    @Published var maximumTokens = 256
    @Published private(set) var image: NSImage?
    @Published private(set) var imageName: String?
    @Published private(set) var pixelSize = CGSize.zero
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var metrics: LabRunMetrics?
    @Published private(set) var target: LabGroundedTarget?
    @Published private(set) var targetFailure: String?
    private var png: Data?
    private var imageToken = UUID()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(runtime: LocalAIRuntime, results: LabResults) { self.runtime = runtime; self.results = results }

    var canRun: Bool { !running && png != nil && (mode == .grounded || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let token = UUID()
        imageToken = token
        Task {
            // Decoding and re-encoding a large image happens off the main actor.
            do {
                let prepared = try await Task.detached { try LabImageLoader.prepare(url: url) }.value
                guard imageToken == token else { return }
                png = prepared.png
                image = NSImage(data: prepared.png)
                imageName = url.lastPathComponent
                pixelSize = CGSize(width: prepared.width, height: prepared.height)
                output = ""; metrics = nil; target = nil; targetFailure = nil; errorMessage = nil
            } catch {
                guard imageToken == token else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearImage() { imageToken = UUID(); cancel(); png = nil; image = nil; imageName = nil; output = ""; target = nil; metrics = nil }

    func run() {
        guard canRun, let png else { return }
        let token = UUID()
        generation = token
        output = ""; errorMessage = nil; metrics = nil; target = nil; targetFailure = nil
        running = true
        let mode = self.mode
        let messages = mode == .grounded
            ? [LocalChatMessage(role: .system, text: LabGroundedTarget.systemPrompt),
               LocalChatMessage(role: .user, text: question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Find the most prominent button." : question)]
            : [LocalChatMessage(role: .user, text: question)]
        let parameters = LocalGenerationParameters(maximumTokens: maximumTokens, temperature: 0, maximumImageSide: LabImageLoader.longSide)
        let size = pixelSize
        task = Task {
            do {
                let result = try await LabGeneration.run(runtime: runtime, group: .vision, messages: messages, image: png, parameters: parameters) { [weak self] piece in
                    guard let self, generation == token else { return }
                    output += piece
                }
                guard generation == token else { return }
                output = result.text
                metrics = result.metrics
                if mode == .grounded {
                    target = LabGroundedTarget.parse(result.text, imageWidth: Int(size.width), imageHeight: Int(size.height))
                    if target == nil { targetFailure = "The reply is not a valid target rectangle inside the image." }
                }
                results.record(runtime: runtime, pipeline: .vision, groups: [.vision],
                               promptIdentifier: mode == .grounded ? "lab-vision-grounded" : "lab-vision-question", parameters: parameters) {
                    $0.outputText = result.text; $0.generationMetrics = result.worker
                }
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError) {
                    errorMessage = LocalAIRuntime.describe(error)
                    results.record(runtime: runtime, pipeline: .vision, groups: [.vision], promptIdentifier: nil, parameters: parameters) {
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
}

struct LabVisionTab: View {
    @ObservedObject var model: LabVisionModel
    @ObservedObject var runtime: LocalAIRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabCard(title: "Vision test · \(runtime.displayName(.vision))") {
                HStack(spacing: 8) {
                    Button("Choose image…") { model.chooseImage() }.islandButton(.secondary).disabled(model.running)
                    if model.image != nil { Button("Remove image") { model.clearImage() }.islandButton(.quiet).disabled(model.running) }
                    Text(model.imageName.map { "\($0) · \(Int(model.pixelSize.width))×\(Int(model.pixelSize.height)) px" } ?? "No image chosen")
                        .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                }
                labNote("The image stays in memory, is bounded to 4096 px and 3 MiB, downscaled to 1568 px on the long side, and is sent only to the local worker.")
                Picker("", selection: $model.mode) { ForEach(LabVisionModel.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).disabled(model.running)
                TextField(model.mode == .grounded ? "Which element? (e.g. the Save button)" : "Question about the image", text: $model.question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).disabled(model.running)
                HStack(spacing: 18) {
                    Stepper("Max tokens: \(model.maximumTokens)", value: $model.maximumTokens, in: 16...LocalWorkerProtocol.maximumOutputTokens, step: 64)
                        .font(.system(size: 12))
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
            if let image = model.image {
                LabCard(title: "Preview") {
                    ZStack {
                        Image(nsImage: image).resizable().scaledToFit()
                            .overlay(GeometryReader { geometry in targetOverlay(in: geometry.size) })
                    }
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    if let target = model.target {
                        Text("\(target.label): x \(Int(target.x)), y \(Int(target.y)), \(Int(target.width))×\(Int(target.height)) px")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary)
                    }
                    if let failure = model.targetFailure { labError(failure) }
                    labNote("The rectangle is drawn only in this preview; nothing is drawn on your screen.")
                }
            }
            LabCard(title: "Output") {
                LabOutputBox(text: model.output)
                HStack {
                    Button("Copy") { labCopy(model.output) }.islandButton(.secondary).disabled(model.output.isEmpty)
                }
                if let metrics = model.metrics { LabMetricsView(metrics: metrics) }
            }
        }
    }

    @ViewBuilder private func targetOverlay(in size: CGSize) -> some View {
        if let target = model.target, model.pixelSize.width > 0 {
            let scale = size.width / model.pixelSize.width
            ZStack(alignment: .topLeading) {
                Rectangle().stroke(DS.Colors.destructiveText, lineWidth: 2)
                    .frame(width: target.width * scale, height: target.height * scale)
                    .offset(x: target.x * scale, y: target.y * scale)
                Text(target.label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 4)
                    .background(DS.Colors.destructive, in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: target.x * scale, y: max(0, target.y * scale - 16))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }
}
