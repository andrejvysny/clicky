import ClickyCore
import FluidAudio
import Foundation

/// FluidAudio Parakeet TDT v3 (int8 encoder). Uses `AsrModels.loadLocal`, which reads the exact directory and
/// fails locally if a component is missing; `AsrModels.load(from:)` would fall through to the Hub downloader.
final class ParakeetEngine: TranscribingEngine, @unchecked Sendable {
    private var manager: AsrManager?

    static func load(_ reference: LocalModelReference) async throws -> LoadedEngine {
        let directory = URL(fileURLWithPath: reference.directory, isDirectory: true)
        let models: AsrModels
        do {
            models = try AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8)
        } catch AsrModelsError.modelNotFound {
            throw LocalWorkerError(.loadFailed, "model files incomplete")
        } catch {
            throw LocalWorkerError(.loadFailed, "Parakeet load failed (\(String(describing: type(of: error)))).")
        }
        let manager = AsrManager(config: .default)
        do { try await manager.loadModels(models) }
        catch { throw LocalWorkerError(.loadFailed, "Parakeet initialization failed.") }
        let engine = ParakeetEngine()
        engine.manager = manager
        return LoadedEngine(engine: engine, warmUpMilliseconds: nil)
    }

    /// Core ML cannot be interrupted mid-call: a cancel during `transcribe` is honoured when the call returns.
    func transcribe(samples: [Float], language: String, cancel: CancelFlag) async throws -> TranscriptionOutcome {
        guard let manager else { throw LocalWorkerError(.modelNotLoaded, "Model unloaded.") }
        if cancel.isSet { return TranscriptionOutcome(canceled: true) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do { result = try await manager.transcribe(samples, decoderState: &state) }
        catch is CancellationError { return TranscriptionOutcome(canceled: true) }
        catch { throw LocalWorkerError(.inferenceFailed, "Parakeet transcription failed (\(String(describing: type(of: error)))).") }
        if cancel.isSet { return TranscriptionOutcome(canceled: true) }
        return TranscriptionOutcome(text: result.text)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
