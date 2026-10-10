import XCTest
@testable import ClickyCore

final class AudioCaptureTests: XCTestCase {
    private func sine(seconds: Double, amplitude: Double, frequency: Double = 440) -> [Int16] {
        (0..<Int(seconds * 16000)).map {
            Int16((amplitude * 32767 * sin(2 * .pi * frequency * Double($0) / 16000)).rounded())
        }
    }

    private func append(_ buffer: BoundedSampleBuffer, _ samples: [Int16]) -> Bool {
        samples.withUnsafeBufferPointer { buffer.append($0) }
    }

    // MARK: Buffer

    func testBufferStoresDrainsAndClears() {
        let buffer = BoundedSampleBuffer(capacity: 10)
        XCTAssertTrue(append(buffer, [1, 2, 3]))
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.drain(), [1, 2, 3])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(append(buffer, [9]))
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.drain(), [])
    }

    func testBufferExhaustionDropsExcess() {
        let buffer = BoundedSampleBuffer(capacity: 4)
        XCTAssertTrue(append(buffer, [1, 2, 3, 4]))
        XCTAssertFalse(buffer.isExhausted)
        XCTAssertFalse(append(buffer, [5, 6]))
        XCTAssertTrue(buffer.isExhausted)
        XCTAssertEqual(buffer.drain(), [1, 2, 3, 4])
        XCTAssertFalse(buffer.isExhausted)
    }

    func testBufferPartialFitKeepsPrefix() {
        let buffer = BoundedSampleBuffer(capacity: 3)
        XCTAssertFalse(append(buffer, [1, 2, 3, 4, 5]))
        XCTAssertEqual(buffer.drain(), [1, 2, 3])
    }

    func testBufferZeroCapacity() {
        let buffer = BoundedSampleBuffer(capacity: 0)
        XCTAssertFalse(append(buffer, [1]))
        XCTAssertTrue(buffer.isExhausted)
        XCTAssertEqual(buffer.drain(), [])
    }

    func testBufferConcurrentAppendsNeverExceedCapacity() {
        let buffer = BoundedSampleBuffer(capacity: 5_000)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<100 { _ = append(buffer, [Int16](repeating: 7, count: 10)) }
        }
        XCTAssertEqual(buffer.count, 5_000)
        XCTAssertTrue(buffer.isExhausted)
        XCTAssertTrue(buffer.drain().allSatisfy { $0 == 7 })
    }

    // MARK: Stats

    func testSilenceStats() {
        let stats = AudioSignalStats.analyze([Int16](repeating: 0, count: 16000))
        XCTAssertEqual(stats.durationSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.rmsDBFS, -120)
        XCTAssertTrue(stats.isLikelySilence)
        XCTAssertFalse(stats.isHeavilyClipped)
        XCTAssertTrue(AudioSignalStats.analyze([]).isLikelySilence)
    }

    func testHalfScaleSineLevels() {
        let stats = AudioSignalStats.analyze(sine(seconds: 1, amplitude: 0.5))
        XCTAssertEqual(stats.peakDBFS, -6.02, accuracy: 0.1)
        XCTAssertEqual(stats.rmsDBFS, -9.03, accuracy: 0.1)
        XCTAssertEqual(stats.voicedFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.clippedFraction, 0)
        XCTAssertFalse(stats.isLikelySilence)
    }

    func testClippedSquareWave() {
        let samples = (0..<16000).map { ($0 / 20) % 2 == 0 ? Int16.max : Int16.min }
        let stats = AudioSignalStats.analyze(samples)
        XCTAssertEqual(stats.clippedFraction, 1, accuracy: 1e-9)
        XCTAssertTrue(stats.isHeavilyClipped)
    }

    func testShortClipIsLikelySilence() {
        let stats = AudioSignalStats.analyze(sine(seconds: 0.1, amplitude: 0.5))
        XCTAssertEqual(stats.durationSeconds, 0.1, accuracy: 1e-9)
        XCTAssertTrue(stats.isLikelySilence)
    }

    func testQuietNoiseBelowPeakFloorIsSilence() {
        let stats = AudioSignalStats.analyze(sine(seconds: 1, amplitude: 0.001)) // about -60 dBFS
        XCTAssertLessThan(stats.peakDBFS, -50)
        XCTAssertTrue(stats.isLikelySilence)
    }

    func testSpeechLikeBurstsWithGaps() {
        var samples: [Int16] = []
        for _ in 0..<3 {
            samples += sine(seconds: 0.3, amplitude: 0.3)
            samples += [Int16](repeating: 0, count: 4800) // 0.3 s gap
        }
        let stats = AudioSignalStats.analyze(samples)
        XCTAssertEqual(stats.voicedFraction, 0.5, accuracy: 0.05)
        XCTAssertFalse(stats.isLikelySilence)
    }

    // MARK: PCM

    func testPCMClampsAndRounds() {
        let input: [Float] = [0, 0.5, -0.5, 1, -1, 2, -3, .nan, 0.0000153, 0.0000458]
        var output: [Int16] = [99, 99]
        input.withUnsafeBufferPointer { PCMConversion.int16(fromFloat: $0, into: &output) }
        // 0.0000153*32768 = 0.50 rounds away from zero to 1; 0.0000458*32768 = 1.50 -> 2
        XCTAssertEqual(output, [0, 16384, -16384, 32767, -32768, 32767, -32768, 0, 1, 2])
    }

    func testPCMReplacesPreviousContents() {
        var output: [Int16] = [1, 2, 3, 4]
        [Float(0.25)].withUnsafeBufferPointer { PCMConversion.int16(fromFloat: $0, into: &output) }
        XCTAssertEqual(output, [8192])
    }
}
