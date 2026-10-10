import Foundation

/// Fixed-capacity PCM store filled from the realtime audio tap. Storage is allocated up front so appending
/// never allocates; the lock is held only for a memcpy. Samples beyond capacity are dropped, never wrapped.
nonisolated public final class BoundedSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [Int16]
    private var used = 0
    private var exhausted = false

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage = [Int16](repeating: 0, count: self.capacity)
    }

    /// False when any samples were dropped because the buffer is full.
    public func append(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if storage.count < capacity { storage = [Int16](repeating: 0, count: capacity) } // reused after drain
        let room = capacity - used
        let taken = min(room, samples.count)
        if taken > 0, let source = samples.baseAddress {
            storage.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + used).update(from: source, count: taken)
            }
            used += taken
        }
        if taken < samples.count { exhausted = true; return false }
        return true
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return used }
    public var isExhausted: Bool { lock.lock(); defer { lock.unlock() }; return exhausted }

    /// Returns everything captured and releases the storage so audio does not linger in memory.
    public func drain() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let result = Array(storage.prefix(used))
        resetLocked()
        return result
    }

    public func clear() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    private func resetLocked() {
        // Overwrite before release so a cancelled recording is not left behind in freed memory.
        if used > 0 { storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        storage = []
        used = 0
        exhausted = false
    }
}

/// Cheap signal summary used to refuse empty or unusable recordings before any worker call.
nonisolated public struct AudioSignalStats: Equatable, Sendable {
    public let durationSeconds: Double
    public let rmsDBFS: Double
    public let peakDBFS: Double
    public let clippedFraction: Double
    public let voicedFraction: Double

    public static let floorDBFS = -120.0
    static let frameSeconds = 0.030
    static let voicedThresholdDBFS = -45.0

    public static func analyze(_ samples: [Int16], sampleRate: Int = 16000) -> AudioSignalStats {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AudioSignalStats(durationSeconds: 0, rmsDBFS: floorDBFS, peakDBFS: floorDBFS,
                                    clippedFraction: 0, voicedFraction: 0)
        }
        let clipThreshold = 32767.0 * 0.999
        var peak = 0.0
        var clipped = 0
        var totalSquares = 0.0
        let frameLength = max(1, Int(Double(sampleRate) * frameSeconds))
        var voiced = 0
        var frames = 0
        var frameSquares = 0.0
        var frameFill = 0

        func closeFrame() {
            let rms = (frameSquares / Double(frameFill)).squareRoot()
            if decibels(rms) > voicedThresholdDBFS { voiced += 1 }
            frames += 1
            frameSquares = 0
            frameFill = 0
        }

        for sample in samples {
            let value = Double(sample)
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
            if magnitude >= clipThreshold { clipped += 1 }
            let square = value * value
            totalSquares += square
            frameSquares += square
            frameFill += 1
            if frameFill == frameLength { closeFrame() }
        }
        // A trailing partial frame counts only when it is the whole clip, so a tiny tail cannot skew the ratio.
        if frameFill > 0 && frames == 0 { closeFrame() }

        let count = Double(samples.count)
        return AudioSignalStats(
            durationSeconds: count / Double(sampleRate),
            rmsDBFS: decibels((totalSquares / count).squareRoot()),
            peakDBFS: decibels(peak),
            clippedFraction: Double(clipped) / count,
            voicedFraction: frames == 0 ? 0 : Double(voiced) / Double(frames))
    }

    public var isLikelySilence: Bool {
        durationSeconds < 0.3 || peakDBFS < -50 || voicedFraction < 0.02
    }

    public var isHeavilyClipped: Bool { clippedFraction > 0.01 }

    private static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDBFS }
        return max(floorDBFS, 20 * log10(amplitude / 32768.0))
    }
}

nonisolated public enum PCMConversion {
    /// Replaces `into` with `samples` scaled to Int16: clamped to full scale, rounded to nearest, NaN as silence.
    /// Reuses the array's capacity so a realtime caller allocates only on its first (largest) buffer.
    public static func int16(fromFloat samples: UnsafeBufferPointer<Float>, into: inout [Int16]) {
        into.removeAll(keepingCapacity: true)
        into.reserveCapacity(samples.count)
        for sample in samples {
            guard !sample.isNaN else { into.append(0); continue }
            let scaled = (sample * 32768).rounded()
            into.append(Int16(max(-32768, min(32767, scaled))))
        }
    }
}
