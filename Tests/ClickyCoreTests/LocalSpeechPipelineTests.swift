import XCTest
@testable import ClickyCore

final class LocalSpeechPipelineTests: XCTestCase {
    private func worker(_ role: LocalWorkerRole) async throws -> LocalWorkerConnection {
        let url = Bundle(for: LocalSpeechPipelineTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clicky-fake-worker")
        let connection = LocalWorkerConnection(executable: url, role: role, arguments: ["--role", role.rawValue, "--behavior", "normal"],
                                               environment: [:], handshakeTimeout: 4, cancelGrace: 1)
        addTeardownBlock { connection.terminate() }
        _ = try await connection.start()
        return connection
    }

    func testTranscribeSendsExactPCMAndCleanupUsesInferenceWorker() async throws {
        let pipeline = LocalSpeechPipeline(speech: try await worker(.speech), recognizer: "asr",
                                           inference: try await worker(.inference), cleanupModel: "cleanup")
        let samples = [Int16](repeating: 120, count: 16_000)
        let raw = try await pipeline.transcribe(samples)
        XCTAssertEqual(raw.text, "samples=16000")
        XCTAssertGreaterThan(raw.hostMilliseconds, 0)
        let cleaned = try await pipeline.cleanup("uh hello")
        XCTAssertEqual(cleaned.text, "abc")
    }

    func testOverlongRecordingIsRefusedBeforeTransmission() async throws {
        let pipeline = LocalSpeechPipeline(speech: try await worker(.speech), recognizer: "asr", inference: nil, cleanupModel: nil)
        let samples = [Int16](repeating: 0, count: 16_000 * 301)
        do { _ = try await pipeline.transcribe(samples); XCTFail("expected refusal") }
        catch let error as LocalWorkerError { XCTAssertEqual(error.code, .inputTooLarge) }
        XCTAssertFalse(pipeline.canClean)
    }

    func testCleanupPromptMatchesModelCardAndSanitizes() {
        let messages = LocalCleanupPrompt.s1Mini.messages(for: "Um, so I think.")
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.last?.text, "[Styling: semi-formal] [Structure: prose] [Context: general]\nUm, so I think.")
        XCTAssertEqual(LocalCleanupPrompt.s1MiniLowercase.messages(for: "Um, so I think.").last?.text,
                       "[Styling: semi-formal] [Structure: prose] [Context: general]\num so i think")
        XCTAssertEqual(LocalCleanupPrompt.sanitize("<think>\n</think>\n\nSo I think."), "So I think.")
        XCTAssertEqual(LocalCleanupPrompt.s1Mini.outputTokenBudget(for: "hi"), 65)
    }
}
