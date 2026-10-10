@preconcurrency import AVFoundation
import Foundation

/// Decodes a user-chosen audio file to the worker's input format: 16 kHz mono Int16, at most 300 seconds.
enum LabAudioImporter {
    enum ImportError: LocalizedError {
        case unreadable, tooLong, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be decoded as audio."
            case .tooLong: return "Audio is longer than the 300 second local limit."
            case .empty: return "The audio file contains no samples."
            }
        }
    }

    nonisolated static func samples(from url: URL) throws -> [Int16] {
        guard let file = try? AVAudioFile(forReading: url) else { throw ImportError.unreadable }
        let inputRate = file.processingFormat.sampleRate
        guard inputRate > 0, Double(file.length) / inputRate <= LocalWorkerProtocol.maximumAudioSeconds else { throw ImportError.tooLong }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LocalWorkerProtocol.audioSampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw ImportError.unreadable }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(Double(file.length) / inputRate * Double(LocalWorkerProtocol.audioSampleRate)) + 1024)
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
                      (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || conversionError != nil { throw ImportError.unreadable }
            if let channel = output.int16ChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status != .haveData { break }
        }
        guard !samples.isEmpty else { throw ImportError.empty }
        guard Double(samples.count) / Double(LocalWorkerProtocol.audioSampleRate) <= LocalWorkerProtocol.maximumAudioSeconds else { throw ImportError.tooLong }
        return samples
    }
}
