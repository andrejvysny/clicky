import ClickyCore
import CoreGraphics
import Foundation
import ImageIO

/// Input limits enforced before a request is queued, so a bad request never reaches a model.
enum WorkerValidation {
    static let maximumImageSide = 4096

    static func generation(messages: [LocalChatMessage], parameters: LocalGenerationParameters, hasImage: Bool, payload: Data) throws {
        guard !messages.isEmpty else { throw LocalWorkerError(.invalidMessage, "No messages.") }
        let characters = messages.reduce(0) { $0 + $1.text.count }
        guard characters <= LocalWorkerProtocol.maximumPromptCharacters else {
            throw LocalWorkerError(.inputTooLarge, "Prompt exceeds the character limit.")
        }
        guard parameters.maximumTokens > 0, parameters.maximumTokens <= LocalWorkerProtocol.maximumOutputTokens else {
            throw LocalWorkerError(.inputTooLarge, "Output token limit out of range.")
        }
        guard parameters.maximumImageSide > 0, parameters.temperature >= 0, (0...1).contains(parameters.topP) else {
            throw LocalWorkerError(.invalidMessage, "Generation parameters out of range.")
        }
        if hasImage { try validatePNG(payload) }
        else if !payload.isEmpty { throw LocalWorkerError(.invalidMessage, "Unexpected payload.") }
    }

    private static func validatePNG(_ payload: Data) throws {
        guard !payload.isEmpty else { throw LocalWorkerError(.invalidMessage, "Image payload missing.") }
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw LocalWorkerError(.invalidMessage, "Image payload is not a decodable PNG.")
        }
        guard width > 0, height > 0, max(width, height) <= maximumImageSide else {
            throw LocalWorkerError(.inputTooLarge, "Image side exceeds the limit.")
        }
    }

    /// Little-endian Int16 mono 16 kHz PCM to Float in [-1, 1).
    static func samples(sampleCount: Int, payload: Data) throws -> [Float] {
        guard sampleCount > 0 else { throw LocalWorkerError(.invalidMessage, "Empty audio.") }
        guard Double(sampleCount) / Double(LocalWorkerProtocol.audioSampleRate) <= LocalWorkerProtocol.maximumAudioSeconds else {
            throw LocalWorkerError(.inputTooLarge, "Audio exceeds the duration limit.")
        }
        guard payload.count == sampleCount * 2 else { throw LocalWorkerError(.invalidMessage, "Audio payload size mismatch.") }
        return payload.withUnsafeBytes { raw in
            (0..<sampleCount).map { index in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
    }
}
