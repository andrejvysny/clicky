import ClickyCore
import Foundation
import WhisperKit

/// WhisperKit Core ML bundle. `download: false` plus an explicit tokenizer folder keep it from ever reaching the Hub.
final class WhisperEngine: TranscribingEngine, @unchecked Sendable {
    private var pipeline: WhisperKit?

    /// WhisperKit falls back to downloading a tokenizer when `tokenizer.json` is missing, so require it up front.
    private static let requiredEntries = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "tokenizer.json"]

    static func load(_ reference: LocalModelReference) async throws -> LoadedEngine {
        let directory = URL(fileURLWithPath: reference.directory, isDirectory: true)
        let manager = FileManager.default
        guard requiredEntries.allSatisfy({ manager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            throw LocalWorkerError(.loadFailed, "model files incomplete")
        }
        let config = WhisperKitConfig(
            modelFolder: directory.path, tokenizerFolder: directory, verbose: false, logLevel: .none, load: true, download: false)
        let pipeline: WhisperKit
        do { pipeline = try await WhisperKit(config) }
        catch { throw LocalWorkerError(.loadFailed, "Whisper load failed (\(String(describing: type(of: error)))).") }
        let engine = WhisperEngine()
        engine.pipeline = pipeline
        return LoadedEngine(engine: engine, warmUpMilliseconds: nil)
    }

    /// Cancellation is polled by WhisperKit between decoder steps through the progress callback (returning false
    /// stops decoding), so latency is about one decoder step plus the current window's encoder pass.
    func transcribe(samples: [Float], language: String, cancel: CancelFlag) async throws -> TranscriptionOutcome {
        guard let pipeline else { throw LocalWorkerError(.modelNotLoaded, "Model unloaded.") }
        if cancel.isSet { return TranscriptionOutcome(canceled: true) }
        var options = DecodingOptions()
        options.language = language.isEmpty ? "en" : language
        options.temperature = 0
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        options.verbose = false
        let results: [TranscriptionResult]
        do {
            results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in cancel.isSet ? false : nil })
        } catch is CancellationError {
            return TranscriptionOutcome(canceled: true)
        } catch {
            throw LocalWorkerError(.inferenceFailed, "Whisper transcription failed (\(String(describing: type(of: error)))).")
        }
        if cancel.isSet { return TranscriptionOutcome(canceled: true) }
        let text = results.flatMap(\.segments).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutcome(text: text)
    }

    func unload() async {
        await pipeline?.unloadModels()
        pipeline = nil
    }
}
