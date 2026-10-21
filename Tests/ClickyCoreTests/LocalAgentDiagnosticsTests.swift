import XCTest
@testable import ClickyCore

final class LocalAgentDiagnosticsTests: XCTestCase {
    func testReplySummaryIsContentFreeAndFlagsRepeatedStep() {
        let previous = "{\"presentation\": {\"kind\": \"guide_step\", \"text\": \"Click Secret\", \"target\": [100, 200, 300, 260], \"milestone\": \"Open Secret\"}}"
        let history = [LocalChatMessage(role: .user, text: "{}"), LocalChatMessage(role: .assistant, text: previous)]
        let output = "{\"presentation\": {\"kind\": \"guide_step\", \"text\": \"Click Secret again\", \"target\": [100, 200, 300, 260], "
            + "\"action\": {\"kind\": \"tap\"}, \"outcome\": {\"description\": \"Opens\", \"axRole\": \"AXButton\"}, \"milestone\": \"Open Secret\", \"plan\": [\"a\", \"b\"]}}"
        let line = LocalAgentDiagnostics.reply(output, history: history, milliseconds: 12)
        XCTAssertFalse(line.contains("Secret"))
        XCTAssertFalse(line.contains("Opens"))
        XCTAssertTrue(line.contains("kind=guide_step"))
        XCTAssertTrue(line.contains("target=grid(200x60)"))
        XCTAssertTrue(line.contains("action=tap"))
        XCTAssertTrue(line.contains("outcomeAX=axRole"))
        XCTAssertTrue(line.contains("targetFromHistory=true"))
        XCTAssertTrue(line.contains("iouPreviousStep=1.00"))
        XCTAssertTrue(line.contains("sameMilestone=true"))
        XCTAssertTrue(line.contains("plan=2"))
    }

    func testPromptExampleBoxIsDetected() {
        XCTAssertFalse(LocalAgentDiagnostics.exampleBoxes.isEmpty)
        let line = LocalAgentDiagnostics.reply("{\"kind\": \"guide_step\", \"text\": \"x\", \"target\": [20, 300, 180, 340]}", history: [], milliseconds: 0)
        XCTAssertTrue(line.contains("targetFromExample=true"))
    }

    func testUnparsableReplyIsReported() {
        XCTAssertTrue(LocalAgentDiagnostics.reply("no json here", history: [], milliseconds: 0).hasSuffix("json=none"))
    }
}
