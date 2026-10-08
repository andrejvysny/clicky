import XCTest
@testable import ClickyCore

final class InputTests: XCTestCase {
    func testSubmissionPreservesTechnicalTextAndRejectsDuplicate() throws {
        var state = AskInputState()
        let identifier = UUID()
        let text = "  /tmp/a b\n    let číslo = 42\n"
        let generation = try state.begin(text: text, identifier: identifier)
        XCTAssertEqual(state.recoveryDraft, text)
        XCTAssertThrowsError(try state.begin(text: "duplicate", identifier: UUID()))
        XCTAssertTrue(state.append("reply", identifier: identifier, generation: generation))
        state.finish(identifier: identifier, generation: generation, succeeded: true)
        XCTAssertEqual(state.response, "reply")
        XCTAssertEqual(state.recoveryDraft, "")
    }

    func testCanceledCallbacksCannotMutateNewTurn() throws {
        var state = AskInputState()
        let oldIdentifier = UUID()
        let oldGeneration = try state.begin(text: "old", identifier: oldIdentifier)
        state.cancel()
        let newIdentifier = UUID()
        _ = try state.begin(text: "new", identifier: newIdentifier)
        XCTAssertFalse(state.append("late", identifier: oldIdentifier, generation: oldGeneration))
        state.finish(identifier: oldIdentifier, generation: oldGeneration, succeeded: true)
        XCTAssertEqual(state.activeRequest, newIdentifier)
        XCTAssertEqual(state.recoveryDraft, "new")
    }

    func testValidationAndFailedDraftRecovery() throws {
        var state = AskInputState()
        XCTAssertThrowsError(try state.begin(text: " \n\t", identifier: UUID()))
        XCTAssertThrowsError(try state.begin(text: String(repeating: "é", count: 32_769), identifier: UUID()))
        let identifier = UUID()
        let generation = try state.begin(text: "recover me", identifier: identifier)
        state.finish(identifier: identifier, generation: generation, succeeded: false)
        XCTAssertEqual(state.recoveryDraft, "recover me")
        XCTAssertNil(state.activeRequest)
    }

    func testPlacementAcrossNegativeCoordinatesAndSmallDisplays() {
        for display in [CGRect(x: -1920, y: -200, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 300, height: 200)] {
            for pointer in [CGPoint(x: display.minX, y: display.minY), CGPoint(x: display.maxX, y: display.maxY), CGPoint(x: display.midX, y: display.midY)] {
                let result = PopupPlacement.frame(pointer: pointer, size: CGSize(width: 420, height: 260), visibleFrame: display)
                XCTAssertTrue(display.contains(result))
                let ghost = PopupPlacement.besideCompanion(pointer: pointer, size: CGSize(width: 300, height: 34), visibleFrame: display)
                XCTAssertTrue(display.contains(ghost))
            }
        }
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ghost = PopupPlacement.besideCompanion(pointer: CGPoint(x: 500, y: 500), size: CGSize(width: 300, height: 34), visibleFrame: display)
        XCTAssertEqual(ghost.origin, CGPoint(x: 545, y: 440))
        let flipped = PopupPlacement.besideCompanion(pointer: CGPoint(x: 1900, y: 20), size: CGSize(width: 300, height: 34), visibleFrame: display)
        XCTAssertLessThan(flipped.maxX, 1900)
        XCTAssertGreaterThan(flipped.minY, 20)
    }

    func testTypedSpeechDefaultAndDictationExclusion() {
        XCTAssertFalse(SpeechReplyPreference.voiceOnly.shouldSpeak(voiceInitiated: false, dictation: false))
        XCTAssertTrue(SpeechReplyPreference.voiceOnly.shouldSpeak(voiceInitiated: true, dictation: false))
        XCTAssertFalse(SpeechReplyPreference.always.shouldSpeak(voiceInitiated: true, dictation: true))
    }
}
