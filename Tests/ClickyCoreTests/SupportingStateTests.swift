import XCTest
@testable import ClickyCore

final class SupportingStateTests: XCTestCase {
    func testTapLatchHoldAndDuplicateRelease() {
        var gesture = HybridRecordingGesture()
        XCTAssertEqual(gesture.keyDown(mode: .ask, time: 0), .start(.ask))
        XCTAssertEqual(gesture.keyUp(mode: .ask, time: 0.1), .none)
        XCTAssertEqual(gesture.phase, .latched(.ask))
        XCTAssertEqual(gesture.keyDown(mode: .dictate, time: 0.2), .none)
        XCTAssertEqual(gesture.keyDown(mode: .ask, time: 1), .finalize(.ask))
        XCTAssertEqual(gesture.keyUp(mode: .ask, time: 1.1), .none)
        XCTAssertEqual(gesture.keyDown(mode: .dictate, time: 2), .start(.dictate))
        XCTAssertEqual(gesture.keyDown(mode: .dictate, time: 2.1, isRepeat: true), .none)
        XCTAssertEqual(gesture.keyUp(mode: .dictate, time: 2.4), .finalize(.dictate))
        XCTAssertEqual(gesture.keyUp(mode: .dictate, time: 2.5), .none)
    }

    func testCancelDiscardsRecordingWithoutFinalizing() {
        var gesture = HybridRecordingGesture()
        _ = gesture.keyDown(mode: .dictate, time: 0)
        XCTAssertEqual(gesture.cancel(), .discard(.dictate))
        XCTAssertEqual(gesture.keyUp(mode: .dictate, time: 1), .none)
        XCTAssertEqual(gesture.cancel(), .none)
    }

    func testExpectedActionRequiresFreshTargetAndVerifiedOutcome() throws {
        var guidance = try GuidanceVerification(windowIdentifier: 1, displayIdentifier: 2, target: CGRect(x: 10, y: 20, width: 30, height: 40), expectedAction: .click(button: 0), generation: 7)
        XCTAssertFalse(guidance.observe(.click(button: 0, point: .zero), windowIdentifier: 1, displayIdentifier: 2, targetIsFresh: true))
        XCTAssertFalse(guidance.observe(.click(button: 0, point: CGPoint(x: 20, y: 30)), windowIdentifier: 99, displayIdentifier: 2, targetIsFresh: true))
        XCTAssertFalse(guidance.observe(.click(button: 0, point: CGPoint(x: 20, y: 30)), windowIdentifier: 1, displayIdentifier: 2, targetIsFresh: false))
        XCTAssertTrue(guidance.observe(.click(button: 0, point: CGPoint(x: 20, y: 30)), windowIdentifier: 1, displayIdentifier: 2, targetIsFresh: true))
        guidance.verify(outcomeMatches: true, generation: 6)
        XCTAssertEqual(guidance.phase, .verifying)
        guidance.verify(outcomeMatches: false, generation: 7)
        XCTAssertEqual(guidance.phase, .uncertain)
        guidance.manualNext(explicitOverride: false)
        XCTAssertEqual(guidance.phase, .uncertain)
        guidance.manualNext(explicitOverride: true)
        XCTAssertEqual(guidance.phase, .completed)
    }

    func testCanceledGuidanceIgnoresLateVerification() throws {
        var guidance = try GuidanceVerification(windowIdentifier: 1, displayIdentifier: 2, target: CGRect(x: 0, y: 0, width: 10, height: 10), expectedAction: .key(code: 36, modifiers: 0), generation: 1)
        XCTAssertFalse(guidance.observe(.key(code: 36, modifiers: 1), windowIdentifier: 1, displayIdentifier: 2, targetIsFresh: true))
        XCTAssertTrue(guidance.observe(.key(code: 36, modifiers: 0), windowIdentifier: 1, displayIdentifier: 2, targetIsFresh: true))
        guidance.cancel()
        guidance.verify(outcomeMatches: true, generation: 1)
        XCTAssertEqual(guidance.phase, .canceled)
    }

    func testDictationRejectsSecureStaleOrUnsupportedDestination() {
        let valid = DictationDestination(processIdentifier: 1, windowIdentifier: 2, elementIdentifier: "field", selection: NSRange(location: 3, length: 0), secure: false, supportsInsertion: true)
        XCTAssertTrue(valid.permitsInsertion(current: valid))
        for current in [
            DictationDestination(processIdentifier: 1, windowIdentifier: 2, elementIdentifier: "field", selection: NSRange(location: 4, length: 0), secure: false, supportsInsertion: true),
            DictationDestination(processIdentifier: 1, windowIdentifier: 2, elementIdentifier: "field", selection: NSRange(location: 3, length: 0), secure: true, supportsInsertion: true),
            DictationDestination(processIdentifier: 1, windowIdentifier: 2, elementIdentifier: "field", selection: NSRange(location: 3, length: 0), secure: false, supportsInsertion: false),
        ] { XCTAssertFalse(valid.permitsInsertion(current: current)) }
    }
}
