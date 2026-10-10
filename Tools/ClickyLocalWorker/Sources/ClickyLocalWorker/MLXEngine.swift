import ClickyCore
import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// MLX text / vision-language model. Each generation is a fresh prompt: no KV cache survives a request.
final class MLXEngine: GeneratingEngine, @unchecked Sendable {
    private var container: ModelContainer?
    private let kind: LocalModelKind

    private init(container: ModelContainer, kind: LocalModelKind) { self.container = container; self.kind = kind }

    /// Loads strictly from `reference.directory`; the directory loaders never touch a downloader.
    static func load(
        _ reference: LocalModelReference, warmUp: Bool, progress: @Sendable (String, Double?) -> Void
    ) async throws -> LoadedEngine {
        guard WorkerMemory.metallibAvailable else { throw LocalWorkerError(.loadFailed, "mlx.metallib missing next to the worker.") }
        let directory = URL(fileURLWithPath: reference.directory, isDirectory: true)
        progress("loading", nil)
        let loader = LocalDirectoryTokenizerLoader()
        let container: ModelContainer
        do {
            switch reference.kind {
            case .mlxVLM: container = try await VLMModelFactory.shared.loadContainer(from: directory, using: loader)
            case .mlxLLM: container = try await LLMModelFactory.shared.loadContainer(from: directory, using: loader)
            default: throw LocalWorkerError(.unsupported, "Not an MLX model kind.")
            }
        } catch let error as LocalWorkerError {
            throw error
        } catch {
            throw LocalWorkerError(.loadFailed, "MLX model load failed (\(String(describing: type(of: error)))).")
        }
        let engine = MLXEngine(container: container, kind: reference.kind)
        var warmUpMilliseconds: Double?
        if warmUp {
            progress("warm-up", nil)
            let start = ContinuousClock.now
            let request = GenerationRequest(
                messages: [LocalChatMessage(role: .user, text: "Hi")],
                parameters: LocalGenerationParameters(maximumTokens: 1, temperature: 0), image: nil)
            do { _ = try await engine.generate(request, cancel: CancelFlag(), delta: { _ in }) }
            catch { throw LocalWorkerError(.loadFailed, "MLX warm-up failed.") }
            warmUpMilliseconds = start.millisecondsElapsed()
        }
        return LoadedEngine(engine: engine, warmUpMilliseconds: warmUpMilliseconds)
    }

    func generate(_ request: GenerationRequest, cancel: CancelFlag, delta: @escaping @Sendable (String) -> Void) async throws -> GenerationOutcome {
        guard let container else { throw LocalWorkerError(.modelNotLoaded, "Model unloaded.") }
        if request.image != nil, kind != .mlxVLM { throw LocalWorkerError(.unsupported, "Model does not accept images.") }
        let clock = ContinuousClock()
        let start = clock.now
        var outcome = GenerationOutcome()
        let input = try Self.userInput(for: request)
        let parameters = request.parameters
        let generate = GenerateParameters(
            maxTokens: parameters.maximumTokens, temperature: Float(parameters.temperature), topP: Float(parameters.topP),
            seed: parameters.seed)
        do {
            // MLX errors normally terminate the process; scope them into throws so the host gets inferenceFailed.
            outcome = try await withError {
                let prepared = try await container.prepare(input: input)
                var result = GenerationOutcome()
                result.preprocessMilliseconds = start.millisecondsElapsed(on: clock)
                result.promptTokens = prepared.text.tokens.size
                let stream = try await container.generate(input: prepared, parameters: generate)
                try await Self.consume(stream, into: &result, start: start, cancel: cancel, delta: delta)
                return result
            }
        } catch is CancellationError {
            outcome.canceled = true
        } catch let error as LocalWorkerError {
            throw error
        } catch {
            throw LocalWorkerError(.inferenceFailed, "MLX inference failed (\(String(describing: type(of: error)))).")
        }
        return outcome
    }

    /// Reads the generation stream, batching deltas (40 ms or 16 chunks) and checking cancellation on every chunk.
    private static func consume(
        _ stream: AsyncStream<Generation>, into result: inout GenerationOutcome, start: ContinuousClock.Instant,
        cancel: CancelFlag, delta: @Sendable (String) -> Void
    ) async throws {
        let clock = ContinuousClock()
        var pending = ""
        var pendingChunks = 0
        var lastFlush = clock.now
        func flush() {
            guard !pending.isEmpty else { return }
            delta(pending)
            pending = ""
            pendingChunks = 0
            lastFlush = clock.now
        }
        for await generation in stream {
            if cancel.isSet || Task.isCancelled { result.canceled = true; break }
            switch generation {
            case .chunk(let text):
                if result.firstTokenMilliseconds == nil { result.firstTokenMilliseconds = start.millisecondsElapsed(on: clock) }
                result.text += text
                pending += text
                pendingChunks += 1
                let waited = (clock.now - lastFlush).components
                if pendingChunks >= 16 || (waited.seconds == 0 && waited.attoseconds >= 40_000_000_000_000_000) || waited.seconds > 0 { flush() }
            case .info(let info):
                result.promptTokens = info.promptTokenCount
                result.generatedTokens = info.generationTokenCount
            default: break
            }
        }
        flush()
    }

    /// Builds the chat, resizing so the longest image side never exceeds `maximumImageSide` (never upscales).
    private static func userInput(for request: GenerationRequest) throws -> UserInput {
        var chat: [Chat.Message] = request.messages.map { message in
            switch message.role {
            case .system: return .system(message.text)
            case .user: return .user(message.text)
            case .assistant: return .assistant(message.text)
            }
        }
        var processing = UserInput.Processing()
        if let data = request.image {
            guard let image = CIImage(data: data), let last = chat.lastIndex(where: { $0.role == .user }) else {
                throw LocalWorkerError(.invalidMessage, "Image needs a user message.")
            }
            chat[last].images = [.ciImage(image)]
            let side = CGFloat(request.parameters.maximumImageSide)
            if max(image.extent.width, image.extent.height) > side { processing.resize = CGSize(width: side, height: side) }
        }
        // Qwen3-family templates default to a thinking preamble; other templates ignore the unknown key.
        return UserInput(chat: chat, processing: processing, additionalContext: ["enable_thinking": false])
    }

    func clearCaches() async { Memory.clearCache() }

    func unload() async {
        container = nil
        Memory.clearCache()
    }
}
