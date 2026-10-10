import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Dictate Anywhere reuses the production writing coordinator: same binding, plan and single guarded apply.
@MainActor
final class DictationWritingTests: XCTestCase {
    func testDictationInsertsAtUnchangedCaretWithoutProviderOrCommandParsing() async {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator()
        let text = "/write this stays literal text"
        XCTAssertTrue(coordinator.startDictation(text, session: UUID(), autoApply: true))
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertEqual(world.applyCalls.first?.text, text)
        XCTAssertEqual(world.agentsMade, 0)
        XCTAssertEqual(world.readSourceCalls, 0)
    }

    func testReviewDeliveryNeverAppliesWithoutExplicitInsert() async {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator()
        XCTAssertTrue(coordinator.startDictation("maybe changed meaning", session: UUID(), autoApply: false))
        await waitUntil("no review") { coordinator.phase == .review }
        XCTAssertTrue(world.applyCalls.isEmpty)
        coordinator.apply()
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.applyCalls.count, 1)
    }

    func testChangedFrontmostAppKeepsDictationAsPreview() async {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator()
        world.frontmost = 999
        XCTAssertTrue(coordinator.startDictation("hello there", session: UUID(), autoApply: true))
        await waitUntil("no review") { coordinator.phase == .review }
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertNotNil(coordinator.invalidation)
    }

    func testSelectionNeedsExplicitReplace() async {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(2, 3)))
        let coordinator = await world.makeCoordinator()
        XCTAssertTrue(coordinator.startDictation("replacement", session: UUID(), autoApply: true))
        await waitUntil("no review") { coordinator.phase == .review }
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertTrue(coordinator.replacesSelection)
    }

    func testPlanNeverPastesDictationBlindAndKeepsTerminalsSingleLine() {
        let field = FakeWritingWorld.field()
        let pasteOnly = TextTargetSnapshot(kind: .textField, applicationName: "Any", bundleIdentifier: "any.app", processIdentifier: 1,
                                           windowIdentifier: 1, paneIdentity: nil, selection: .caret(0)!, contentRevision: "", pasteOnly: true)
        let terminal = FakeWritingWorld.field(kind: .terminal)
        let provenance = WritingProvenance.dictation(session: UUID())
        XCTAssertEqual(WritingApplyPlan.decide(intent: .dictation, target: field, text: "hi", provenance: provenance), .automatic)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .dictation, target: pasteOnly, text: "hi", provenance: provenance), .review(replacesSelection: false))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .dictation, target: terminal, text: "git status", provenance: provenance), .automatic)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .dictation, target: terminal, text: "a\nb", provenance: provenance), .previewOnly(.terminalMultiline))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .dictation, target: nil, text: "hi", provenance: provenance), .previewOnly(.noTarget))
    }
}
