import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// The production `WritingCoordinator` over a fake desktop and a scripted provider.
@MainActor
final class WritingCoordinatorTests: XCTestCase {
    private let hostile = "$(date) `id` ${X} 'q' \"dq\" | tail -2 café 日本 😀"

    private func snippet(_ world: FakeWritingWorld, body: String, restriction: SnippetRestriction = .any) throws -> SavedSnippet {
        try world.definitions.addSnippet(name: "S", alias: "s", summary: "", body: body, restriction: restriction)
    }

    private func finished(_ coordinator: WritingCoordinator) async {
        await waitUntil("not finished") { coordinator.phase == .finished }
    }

    // 1
    func testSnippetInsertsExactBodyWithoutProviderOrSourceRead() async throws {
        for kind in [WritingTargetKind.textField, .terminal] {
            let world = FakeWritingWorld(primary: FakeWritingWorld.field(kind: kind))
            let saved = try snippet(world, body: hostile)
            let coordinator = await world.makeCoordinator()
            XCTAssertTrue(coordinator.start(.snippet(saved)))
            await finished(coordinator)
            XCTAssertEqual(world.applyCalls.count, 1)
            XCTAssertEqual(world.applyCalls.first?.text, hostile)
            XCTAssertEqual(world.applyCalls.first?.expectedSource, "")
            XCTAssertEqual(world.agentsMade, 0)
            XCTAssertEqual(world.readSourceCalls, 0)
            XCTAssertEqual(coordinator.notice, kind == .terminal ? "Inserted — not executed" : "Inserted")
        }
    }

    // 2
    func testSnippetIntoSelectionWaitsForExplicitApplyThenUsesExactSelectedText() async throws {
        let selected = " ab\r\n"
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(2, selected.utf16.count)))
        world.sourceText = selected
        let saved = try snippet(world, body: hostile)
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: true))
        XCTAssertTrue(coordinator.replacesSelection)
        await Task.yield(); await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        coordinator.apply()
        await finished(coordinator)
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertEqual(world.applyCalls.first?.range, FakeWritingWorld.range(2, selected.utf16.count))
        XCTAssertEqual(world.applyCalls.first?.expectedSource, selected)
        XCTAssertEqual(coordinator.notice, "Replaced selection")
    }

    // 3
    func testTerminalMultilineAndTabSnippetsStayPreviewOnlyAndCopyExactly() async throws {
        let cases: [(String, WritingBlockReason)] = [("a\nb", .terminalMultiline), ("a\tb", .terminalControlCharacters)]
        for (body, reason) in cases {
            let world = FakeWritingWorld(primary: FakeWritingWorld.field(kind: .terminal))
            let saved = try snippet(world, body: body)
            let coordinator = await world.makeCoordinator()
            coordinator.start(.snippet(saved))
            await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
            XCTAssertEqual(coordinator.plan, .previewOnly(reason))
            XCTAssertFalse(coordinator.canApply)
            coordinator.apply()
            await settle()
            XCTAssertTrue(world.applyCalls.isEmpty)
            coordinator.copyProposal()
            XCTAssertEqual(world.copied, [body])
        }
    }

    // 4
    func testTerminalOnlySnippetPrefersTheAlternateTerminal() async throws {
        let editor = FakeWritingWorld.field(kind: .vscodeEditor, pane: "file:///x.swift")
        let terminal = FakeWritingWorld.field(kind: .terminal, pane: "pid-9")
        let world = FakeWritingWorld(primary: editor)
        world.alternate = terminal
        let saved = try snippet(world, body: "ls -la", restriction: .terminalOnly)
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
        await finished(coordinator)
        XCTAssertEqual(coordinator.target?.kind, .terminal)
        XCTAssertEqual(world.applyCalls.first?.target.token, terminal.token)
        XCTAssertEqual(coordinator.alternateTarget?.token, editor.token)
    }

    // 5
    func testWriteSendsDraftPayloadWithoutSourceAndAppliesOnlyTheDraft() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.reply(FakeWritingWorld.draft("Hello,\n  Anna", subject: "Greetings")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "greet Anna", skill: nil))
        await finished(coordinator)
        let turn = try XCTUnwrap(world.agent.turns.first)
        XCTAssertEqual(turn.purpose, .writing)
        XCTAssertEqual(turn.writing?.operation, .draft)
        XCTAssertNil(turn.writing?.source)
        XCTAssertNil(turn.writing?.surrounding)
        XCTAssertEqual(world.readSourceCalls, 0)
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertEqual(world.applyCalls.first?.text, "Hello,\n  Anna")
        XCTAssertEqual(coordinator.proposal?.subject, "Greetings")
    }

    // 6
    func testWriteKeptAsPreviewWhenFrontmostProcessChangedDuringGeneration() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.suspend)
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("turn not pending") { world.agent.hasPendingTurn }
        world.frontmost = 999
        world.agent.release(FakeWritingWorld.draft("late text"))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        XCTAssertEqual(coordinator.phase, .review)
        XCTAssertEqual(coordinator.invalidation, WritingNotAppliedReason.focusChanged.message)
        XCTAssertFalse(coordinator.canApply)
        XCTAssertEqual(coordinator.previewText, "late text")
        coordinator.apply()
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        coordinator.copyProposal()
        XCTAssertEqual(world.copied, ["late text"])
    }

    // 7
    func testChangedLiveTargetAtApplyTimeIsNotApplied() async throws {
        let moved = FakeWritingWorld.field(selection: FakeWritingWorld.range(1, 0))
        let edited = FakeWritingWorld.field(revision: "r9")
        for live in [moved, edited] {
            let world = FakeWritingWorld()
            world.live = live
            world.agent.enqueue(.reply(FakeWritingWorld.draft("text")))
            let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
            coordinator.start(.write(instruction: "w", skill: nil))
            await waitUntil("no notice") { coordinator.notice != nil }
            XCTAssertTrue(world.applyCalls.isEmpty)
            XCTAssertTrue(coordinator.notice?.hasPrefix("Not inserted") == true, coordinator.notice ?? "nil")
            XCTAssertEqual(coordinator.phase, .review)
            XCTAssertNotNil(coordinator.invalidation)
        }
    }

    // 8
    func testRewriteReadsExactSourceAfterSubmissionAndAppliesEditedRevisionOnce() async throws {
        let selected = "  Héllo\r\nwörld 😀  "
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(3, selected.utf16.count)))
        world.sourceText = selected
        world.agent.enqueue(.reply(FakeWritingWorld.draft("Hello world")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        XCTAssertEqual(world.readSourceCalls, 0, "binding reads no content")
        coordinator.start(.rewrite(instruction: "simplify", skill: nil))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        XCTAssertEqual(world.readSourceCalls, 1)
        XCTAssertEqual(world.agent.turns.first?.writing?.source, selected)
        XCTAssertEqual(world.agent.turns.first?.writing?.operation, .rewrite)
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: true))
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        coordinator.previewText = "Hello, edited"
        coordinator.apply(); coordinator.apply()
        await finished(coordinator)
        coordinator.apply()
        await settle()
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertEqual(world.applyCalls.first?.text, "Hello, edited")
        XCTAssertEqual(world.applyCalls.first?.expectedSource, selected)
        XCTAssertEqual(coordinator.proposal?.revision, 2)
        XCTAssertEqual(coordinator.proposal?.edited, true)
        XCTAssertEqual(world.readSourceCalls, 1)
    }

    // 9
    func testClarificationIsShownAndNeverApplied() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.reply(GuidePresentation(kind: .clarification, text: "Who is it for?")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("no clarification") { coordinator.clarification != nil }
        XCTAssertEqual(coordinator.clarification, "Who is it for?")
        XCTAssertNil(coordinator.proposal)
        XCTAssertEqual(coordinator.phase, .review)
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
    }

    // 10
    func testStopDuringGenerationIgnoresTheLateReplyAndClosesTheAgent() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.suspend)
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("turn not pending") { world.agent.hasPendingTurn }
        coordinator.stop()
        XCTAssertNotEqual(coordinator.phase, .generating)
        world.agent.release(FakeWritingWorld.draft("too late"))
        await settle()
        XCTAssertNil(coordinator.proposal)
        XCTAssertTrue(world.applyCalls.isEmpty)
        await waitUntil("agent not closed") { world.agent.closeCount >= 1 }
    }

    // 11
    func testHeldSubmitKeyAndUnrestorableFocusBlockApplication() async throws {
        let world = FakeWritingWorld()
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        world.keyReleased = false
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
        await waitUntil("no notice") { coordinator.notice != nil }
        XCTAssertEqual(coordinator.notice, "Not inserted: " + WritingNotAppliedReason.keyStillHeld.message)
        XCTAssertTrue(world.applyCalls.isEmpty)

        let second = FakeWritingWorld()
        let other = try snippet(second, body: "text")
        let focused = await second.makeCoordinator()
        second.focusRestorable = false
        focused.start(.snippet(other))
        await waitUntil { focused.phase != .generating }  // snippets resolve after the pending bind
        await waitUntil("no notice") { focused.notice != nil }
        XCTAssertEqual(focused.notice, "Not inserted: " + WritingNotAppliedReason.focusChanged.message)
        XCTAssertTrue(second.applyCalls.isEmpty)
    }

    // 12
    func testDeliveryUnknownIsNeverRetried() async throws {
        let world = FakeWritingWorld()
        world.applyResult = .deliveryUnknown
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
        await waitUntil("no notice") { coordinator.notice != nil }
        XCTAssertTrue(coordinator.notice?.contains("Delivery unconfirmed") == true)
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertFalse(coordinator.canApply)
        coordinator.apply()
        await settle()
        XCTAssertEqual(world.applyCalls.count, 1)
    }

    // 13
    func testSnippetEditedBetweenResolutionAndApplyIsNotApplied() async throws {
        let selected = "abc"
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(2, 3)))
        world.sourceText = selected
        var saved = try snippet(world, body: "original")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase != .generating }  // snippets resolve after the pending bind
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: true))
        saved.body = "changed"
        try world.definitions.updateSnippet(saved)
        coordinator.apply()
        await waitUntil("no notice") { coordinator.notice != nil }
        XCTAssertEqual(coordinator.notice, "Not inserted: " + WritingNotAppliedReason.definitionChanged.message)
        XCTAssertTrue(world.applyCalls.isEmpty)
    }

    // 14
    func testPreviewBackendWriteIsPreviewOnly() async throws {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator(provider: .preview)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        XCTAssertEqual(coordinator.plan, .previewOnly(.previewBackend))
        XCTAssertFalse(coordinator.canApply)
        coordinator.apply()
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertEqual(world.agentsMade, 0)
    }

    // 15
    func testSurroundingContextIsReadOnlyWhenOptedInAndResets() async throws {
        let world = FakeWritingWorld()
        world.surrounding = .init(before: "before ", after: " after")
        world.agent.enqueue(.reply(FakeWritingWorld.draft("one")))
        world.agent.enqueue(.reply(FakeWritingWorld.draft("two")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.includeSurrounding = true
        coordinator.start(.write(instruction: "w", skill: nil))
        await finished(coordinator)
        XCTAssertEqual(world.readSurroundingCalls, 1)
        XCTAssertEqual(world.agent.turns.first?.writing?.surrounding, .init(before: "before ", after: " after"))
        XCTAssertFalse(coordinator.includeSurrounding)

        coordinator.start(.write(instruction: "w2", skill: nil))
        await waitUntil("second turn") { world.agent.turns.count == 2 }
        await finished(coordinator)
        XCTAssertEqual(world.readSurroundingCalls, 1)
        XCTAssertNil(world.agent.turns.last?.writing?.surrounding)
    }

    // 16
    func testRefinementSendsCurrentPreviewAndStaysUnapplied() async throws {
        let selected = "source"
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(0, selected.utf16.count)))
        world.sourceText = selected
        world.agent.enqueue(.reply(FakeWritingWorld.draft("first draft")))
        world.agent.enqueue(.reply(FakeWritingWorld.draft("short")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.rewrite(instruction: "polish", skill: nil))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        coordinator.previewText = "edited draft"
        coordinator.refine("shorter")
        await waitUntil("revision 2") { coordinator.proposal?.text == "short" }
        let refined = try XCTUnwrap(world.agent.turns.last)
        XCTAssertEqual(refined.writing?.previousDraft, "edited draft")
        XCTAssertEqual(refined.writing?.refinement, "shorter")
        XCTAssertEqual(refined.writing?.source, selected)
        XCTAssertEqual(coordinator.proposal?.revision, 2)
        XCTAssertEqual(coordinator.phase, .review)
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
    }

    // 17
    func testRestoreOriginalAfterAppliedWriteCallsRestoreOnce() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.reply(FakeWritingWorld.draft("inserted")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await finished(coordinator)
        let edit = try XCTUnwrap(coordinator.lastEdit)
        coordinator.restoreOriginal()
        coordinator.restoreOriginal()
        await waitUntil("restore not called") { !world.restoreCalls.isEmpty }
        await settle()
        XCTAssertEqual(world.restoreCalls, [edit])
        XCTAssertEqual(coordinator.notice, "Restored the original text")
    }

    // 18
    func testBindingWhileProposalRetainedDemotesAutomaticPlanToExplicitReview() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.suspend)
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("turn not pending") { world.agent.hasPendingTurn }
        world.frontmost = 999
        world.agent.release(FakeWritingWorld.draft("kept"))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        XCTAssertEqual(coordinator.plan, .automatic)

        let next = FakeWritingWorld.field(revision: "other")
        world.primary = next
        world.frontmost = FakeWritingWorld.pid
        await coordinator.bind(processIdentifier: FakeWritingWorld.pid)
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: false))
        XCTAssertNil(coordinator.invalidation)
        XCTAssertEqual(coordinator.target?.token, next.token)
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty, "no automatic application into the new target")
        coordinator.apply()
        await finished(coordinator)
        XCTAssertEqual(world.applyCalls.first?.target.token, next.token)
    }

    // Review regressions

    func testEmptiedPreviewCannotReplaceTheSelection() async throws {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(0, 5)))
        world.sourceText = "Hello"
        let coordinator = await world.makeCoordinator()
        let saved = try snippet(world, body: "Hi")
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase == .review }
        XCTAssertTrue(coordinator.canApply)
        coordinator.previewText = ""
        XCTAssertFalse(coordinator.canApply)
        coordinator.apply()
        XCTAssertEqual(world.applyCalls.count, 0)
    }

    func testFastSubmitWaitsForTheNewBindingInsteadOfReusingTheOldTarget() async throws {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator()
        let oldToken = coordinator.target?.token
        let fresh = FakeWritingWorld.field(revision: "fresh")
        world.primary = fresh; world.live = fresh
        let saved = try snippet(world, body: "x")
        coordinator.beginBinding(processIdentifier: FakeWritingWorld.pid)
        XCTAssertNil(coordinator.target, "the previous destination is cleared synchronously")
        coordinator.start(.snippet(saved))
        await finished(coordinator)
        XCTAssertEqual(world.applyCalls.first?.target.token, fresh.token)
        XCTAssertNotEqual(world.applyCalls.first?.target.token, oldToken)
    }

    func testDiscardIsRefusedWhileAnExternalWriteIsInFlight() async throws {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(0, 5)))
        world.sourceText = "Hello"
        world.keyReleased = true
        let coordinator = await world.makeCoordinator()
        let saved = try snippet(world, body: "Hi")
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase == .review }
        coordinator.apply()
        XCTAssertEqual(coordinator.phase, .applying)
        coordinator.discard()
        XCTAssertEqual(coordinator.phase, .applying, "discard must not drop the record of a write that may land")
        await finished(coordinator)
        XCTAssertNotNil(coordinator.lastEdit)
    }

    func testRestoreTargetsTheEditedControlAfterQuickAskRebinds() async throws {
        let world = FakeWritingWorld()
        let coordinator = await world.makeCoordinator()
        let edited = coordinator.target
        coordinator.start(.snippet(try snippet(world, body: "x")))
        await finished(coordinator)
        world.primary = FakeWritingWorld.field(revision: "other")
        await coordinator.bind(processIdentifier: FakeWritingWorld.pid)
        coordinator.restoreOriginal()
        await waitUntil { world.restoreCalls.count == 1 }
        XCTAssertEqual(world.restoreCalls.first?.targetToken, edited?.token)
    }
}

