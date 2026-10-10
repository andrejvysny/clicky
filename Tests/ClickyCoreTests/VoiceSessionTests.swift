import XCTest
@testable import ClickyCore

final class VoiceSessionTests: XCTestCase {
    func testDictationAcceptedCleanupInsertsAutomatically() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .dictate, cleanup: true, at: 0)!
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.stop(generation))
        XCTAssertEqual(state.transcribed(generation, raw: "um so I think uh we should go"), .cleaning(raw: "um so I think uh we should go"))
        XCTAssertEqual(state.cleaned(generation, cleaned: "So I think we should go."), .insert(text: "So I think we should go."))
        XCTAssertTrue(state.finish(generation))
        XCTAssertEqual(state.stage, .completed)
    }

    func testDictationAnsweredQuestionGoesToReviewPreferringRaw() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .dictate, cleanup: true, at: 0)!
        _ = state.stop(generation)
        _ = state.transcribed(generation, raw: "what kind of a car do you think you'll buy next")
        guard case .review(let raw, let cleaned, let preferRaw, let concerns, false)? = state.cleaned(generation, cleaned: "I would buy a Tesla Model 3.") else {
            return XCTFail("expected review")
        }
        XCTAssertEqual(raw, "what kind of a car do you think you'll buy next")
        XCTAssertEqual(cleaned, "I would buy a Tesla Model 3.")
        XCTAssertTrue(preferRaw)
        XCTAssertFalse(concerns.isEmpty)
    }

    func testCleanupFailureKeepsRawForExplicitRecovery() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .dictate, cleanup: true, at: 0)!
        _ = state.stop(generation)
        _ = state.transcribed(generation, raw: "send the report tomorrow")
        XCTAssertEqual(state.cleaned(generation, cleaned: nil),
                       .review(raw: "send the report tomorrow", cleaned: nil, preferRaw: true, concerns: [], cleanupFailed: true))
    }

    func testSilenceAndFillersNeverProduceText() {
        for raw in ["", "   ", "uh um", "hmm."] {
            var state = VoiceSessionState()
            let generation = state.begin(mode: .dictate, cleanup: true, at: 0)!
            _ = state.stop(generation)
            XCTAssertEqual(state.transcribed(generation, raw: raw), .delivering(.noSpeech), raw)
        }
        XCTAssertEqual(VoiceDelivery.decide(mode: .ask, raw: "uh", cleaned: nil, cleanupRequested: false, assessment: nil), .noSpeech)
    }

    func testAskVoiceAlwaysBecomesDraftAndKeepsOriginal() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .ask, cleanup: true, at: 0)!
        _ = state.stop(generation)
        _ = state.transcribed(generation, raw: "um how do I export this as PDF")
        guard case .quickAskDraft(let text, let raw, _, false)? = state.cleaned(generation, cleaned: "How do I export this as PDF?") else {
            return XCTFail("expected draft")
        }
        XCTAssertEqual(text, "How do I export this as PDF?")
        XCTAssertEqual(raw, "um how do I export this as PDF")
        // A rejected cleanup puts the original transcript in the draft instead.
        let rejected = VoiceDelivery.decide(mode: .ask, raw: "what kind of a car do you think you'll buy next",
                                            cleaned: "I would buy a Tesla.", cleanupRequested: true,
                                            assessment: CleanupGate.assess(raw: "what kind of a car do you think you'll buy next", cleaned: "I would buy a Tesla."))
        guard case .quickAskDraft(let rejectedText, _, _, _) = rejected else { return XCTFail("expected draft") }
        XCTAssertEqual(rejectedText, "what kind of a car do you think you'll buy next")
    }

    func testVerbatimModeSkipsCleanup() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .dictate, cleanup: false, at: 0)!
        _ = state.stop(generation)
        XCTAssertEqual(state.transcribed(generation, raw: "uh hello there"), .delivering(.insert(text: "uh hello there")))
    }

    func testStaleGenerationsCannotReachNewerSession() {
        var state = VoiceSessionState()
        let first = state.begin(mode: .dictate, cleanup: true, at: 0)!
        XCTAssertTrue(state.cancel(first))
        let second = state.begin(mode: .dictate, cleanup: true, at: 1)!
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.stop(first))
        XCTAssertTrue(state.stop(second))
        XCTAssertNil(state.transcribed(first, raw: "late text"))
        XCTAssertNotNil(state.transcribed(second, raw: "current text"))
        XCTAssertNil(state.cleaned(first, cleaned: "late"))
        XCTAssertFalse(state.finish(first))
    }

    func testFinalizationHappensExactlyOnce() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .dictate, cleanup: false, at: 0)!
        XCTAssertTrue(state.stop(generation))
        XCTAssertFalse(state.stop(generation))
        XCTAssertNotNil(state.transcribed(generation, raw: "hello"))
        XCTAssertNil(state.transcribed(generation, raw: "hello"))
        XCTAssertTrue(state.finish(generation))
        XCTAssertFalse(state.finish(generation))
    }

    func testCannotBeginWhileActiveAndCancelEndsAnyActiveStage() {
        var state = VoiceSessionState()
        let generation = state.begin(mode: .ask, cleanup: true, at: 0)!
        XCTAssertNil(state.begin(mode: .dictate, cleanup: true, at: 1))
        _ = state.stop(generation)
        XCTAssertTrue(state.cancel(generation))
        XCTAssertEqual(state.stage, .canceled)
        XCTAssertNil(state.transcribed(generation, raw: "late"))
        XCTAssertFalse(state.cancel(generation))
        XCTAssertTrue(state.fail(state.begin(mode: .ask, cleanup: true, at: 2)!, .microphoneDenied))
    }

    func testRecordingLimitsAreBoundedAndVisible() {
        let limits = VoiceRecordingLimits(maximumSeconds: 120, warningSeconds: 15)
        XCTAssertEqual(limits.maximumSamples, 1_920_000)
        XCTAssertFalse(limits.isWarning(elapsed: 100))
        XCTAssertTrue(limits.isWarning(elapsed: 106))
        XCTAssertTrue(limits.isExhausted(elapsed: 120))
        XCTAssertEqual(VoiceRecordingLimits(maximumSeconds: 9999).maximumSeconds, LocalWorkerProtocol.maximumAudioSeconds)
        XCTAssertEqual(VoiceRecordingLimits(maximumSeconds: 1).maximumSeconds, 10)
    }
}
