import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Regressions for the writing review (CLICKY-37–44): keyboard hand-off, commit-point authority, immutable
/// operation destinations, ambiguous VS Code bindings, clarification/failure recovery and reference input.
@MainActor
final class WritingHardeningTests: XCTestCase {
    private func snippet(_ world: FakeWritingWorld, body: String, restriction: SnippetRestriction = .any) throws -> SavedSnippet {
        try world.definitions.addSnippet(name: "S", alias: "s", summary: "", body: body, restriction: restriction)
    }

    // F3
    func testComposerClosesOnlyAfterTheSubmitKeyIsReleased() async throws {
        let world = FakeWritingWorld()
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.events, ["keyRelease", "closeComposer", "restoreFocus", "apply"])

        let held = FakeWritingWorld()
        held.keyReleased = false
        let heldSnippet = try snippet(held, body: "text")
        let heldCoordinator = await held.makeCoordinator()
        heldCoordinator.start(.snippet(heldSnippet))
        await waitUntil("no notice") { heldCoordinator.notice != nil }
        XCTAssertEqual(held.events, ["keyRelease"], "Quick Ask keeps the keyboard while Return is held")
    }

    // F2
    func testStopAtTheAdapterCommitPointPreventsTheWrite() async throws {
        let world = FakeWritingWorld()
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        world.beforeCommit = { coordinator.stop() }
        coordinator.start(.snippet(saved))
        await waitUntil("no notice") { coordinator.notice != nil }
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertEqual(world.canceledAtCommit, 1)
        XCTAssertEqual(coordinator.invalidation, WritingNotAppliedReason.canceled.message)
    }

    // F2
    func testProviderResetRevokesAPendingWrite() async throws {
        let world = FakeWritingWorld()
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        world.beforeCommit = { coordinator.reset() }
        coordinator.start(.snippet(saved))
        await waitUntil("not canceled at commit") { world.canceledAtCommit == 1 }
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
    }

    // F2
    func testStopBeforeRestoreCommitKeepsTheEdit() async throws {
        let world = FakeWritingWorld()
        let saved = try snippet(world, body: "text")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil("not finished") { coordinator.phase == .finished }
        world.beforeCommit = { coordinator.stop() }
        coordinator.restoreOriginal()
        await waitUntil("restore not settled") { coordinator.phase == .finished && coordinator.notice == "Stopped" }
        XCTAssertTrue(world.restoreCalls.isEmpty)
        XCTAssertNotNil(coordinator.lastEdit, "Restore stays available after a stopped attempt")
    }

    // F4
    func testRebindingDuringGenerationNeverInheritsAutomaticApplication() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.suspend)
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("turn not pending") { world.agent.hasPendingTurn }
        let other = FakeWritingWorld.field(selection: .caret(9)!)
        world.primary = other
        await coordinator.bind(processIdentifier: FakeWritingWorld.pid)
        world.agent.release(FakeWritingWorld.draft("draft"))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: false))
        XCTAssertEqual(coordinator.target?.token, other.token)
    }

    // F4
    func testRetainedRewriteCannotReplaceADifferentSelection() async throws {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(selection: FakeWritingWorld.range(0, 3)))
        world.sourceText = "abc"
        world.agent.enqueue(.reply(FakeWritingWorld.draft("ABC")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.rewrite(instruction: "upper", skill: nil))
        await waitUntil("no proposal") { coordinator.proposal != nil }
        world.primary = FakeWritingWorld.field(selection: FakeWritingWorld.range(4, 3))
        await coordinator.bind(processIdentifier: FakeWritingWorld.pid)
        XCTAssertEqual(coordinator.plan, .previewOnly(.rewriteTargetChanged))
        XCTAssertFalse(coordinator.canApply)
        coordinator.apply()
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
    }

    // F1
    func testAmbiguousEditorAndTerminalBindingNeverAppliesAutomatically() async throws {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(kind: .vscodeEditor, pane: "file:///x"))
        world.alternate = FakeWritingWorld.field(kind: .terminal, pane: "vscode-terminal:9")
        world.ambiguous = true
        let saved = try snippet(world, body: "ls")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase == .review }
        await settle()
        XCTAssertTrue(world.applyCalls.isEmpty)
        XCTAssertEqual(coordinator.plan, .review(replacesSelection: false))
        coordinator.apply()
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.applyCalls.first?.target.kind, .vscodeEditor)
    }

    // F4
    func testRestrictedSnippetIsRecheckedAfterSwitchingDestination() async throws {
        let world = FakeWritingWorld(primary: FakeWritingWorld.field(kind: .vscodeEditor, pane: "file:///x"))
        world.alternate = FakeWritingWorld.field(kind: .terminal, pane: "vscode-terminal:9")
        world.ambiguous = true
        let saved = try snippet(world, body: "text", restriction: .editorsOnly)
        let coordinator = await world.makeCoordinator()
        world.keyReleased = false  // keep the editor attempt from finishing
        coordinator.start(.snippet(saved))
        await waitUntil { coordinator.phase == .review && coordinator.notice != nil }
        coordinator.switchDestination()
        XCTAssertEqual(coordinator.target?.kind, .terminal)
        XCTAssertEqual(coordinator.plan, .previewOnly(.snippetEditorsOnly))
        XCTAssertFalse(coordinator.canApply)
    }

    // F8
    func testClarificationAnswerContinuesTheWritingRequest() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.reply(GuidePresentation(kind: .clarification, text: "Who is it for?")))
        world.agent.enqueue(.reply(FakeWritingWorld.draft("Hi Martin")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "write a greeting", skill: nil))
        await waitUntil("no clarification") { coordinator.clarification != nil }
        XCTAssertTrue(coordinator.canRefine)
        coordinator.refine("Martin")
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.agent.turns.count, 2)
        XCTAssertEqual(world.agent.turns.last?.message, "Martin")
        XCTAssertEqual(world.agent.turns.last?.writing?.refinement, "Martin")
        XCTAssertNil(world.agent.turns.last?.writing?.previousDraft)
        XCTAssertEqual(world.applyCalls.first?.text, "Hi Martin")
        XCTAssertEqual(world.agentsMade, 1, "the answer stays in the same provider conversation")
    }

    // F8
    func testFailureBeforeAProposalStaysVisibleWithRetry() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.fail(AskError.incompleteTurn))
        world.agent.enqueue(.reply(FakeWritingWorld.draft("second try")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "w", skill: nil))
        await waitUntil("no failure") { coordinator.canRetry }
        XCTAssertEqual(coordinator.phase, .review)
        XCTAssertNotNil(coordinator.notice)
        coordinator.retry()
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.applyCalls.first?.text, "second try")
        XCTAssertFalse(coordinator.canRetry)
    }

    // F9
    func testAttachedReferenceMaterialReachesTheProvider() async throws {
        let world = FakeWritingWorld()
        world.agent.enqueue(.reply(FakeWritingWorld.draft("Thanks!")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.write(instruction: "reply to this email", skill: nil), reference: "Can we meet Friday?")
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.agent.turns.first?.writing?.reference, "Can we meet Friday?")
        XCTAssertNil(world.agent.turns.first?.writing?.source)
    }

    // Paste fallback: apps without a verified adapter paste on explicit request and never claim read-back.
    func testPasteOnlyDestinationPastesAutomaticallyAndReportsUnverified() async throws {
        let base = FakeWritingWorld.field(kind: .vscodeEditor)
        let target = TextTargetSnapshot(kind: .vscodeEditor, applicationName: "Code", bundleIdentifier: "com.microsoft.VSCode",
                                        processIdentifier: base.processIdentifier, windowIdentifier: 7, paneIdentity: nil,
                                        selection: .caret(0)!, contentRevision: "", pasteOnly: true)
        let world = FakeWritingWorld(primary: target)
        world.applyResult = .acknowledged(WritingAppliedEdit(targetToken: target.token, insertedRange: .caret(0)!, insertedText: "x",
                                                             replacedText: "", postRevision: ""))
        let saved = try snippet(world, body: "line one\nline two")
        let coordinator = await world.makeCoordinator()
        coordinator.start(.snippet(saved))
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.events, ["keyRelease", "closeComposer", "restoreFocus", "apply"])
        XCTAssertEqual(world.applyCalls.count, 1)
        XCTAssertEqual(world.applyCalls.first?.text, "line one\nline two")
        XCTAssertEqual(coordinator.notice, "Pasted at the cursor")
        XCTAssertNil(coordinator.lastEdit, "no Restore original without read-back")
    }

    // Copy-and-paste rewrite in an app without a verified adapter: copy the selection, paste the rewrite over it.
    func testPasteOnlyRewriteCopiesTheSelectionAndPastesTheReplacement() async throws {
        let target = TextTargetSnapshot(kind: .textField, applicationName: "Notes", bundleIdentifier: "com.apple.Notes",
                                        processIdentifier: FakeWritingWorld.pid, windowIdentifier: 7, paneIdentity: nil,
                                        selection: .caret(0)!, contentRevision: "", pasteOnly: true)
        let world = FakeWritingWorld(primary: target)
        world.sourceText = "teh qiuck fox"
        world.applyResult = .acknowledged(WritingAppliedEdit(targetToken: target.token, insertedRange: .caret(0)!, insertedText: "x",
                                                             replacedText: "", postRevision: ""))
        world.agent.enqueue(.reply(FakeWritingWorld.draft("the quick fox")))
        let coordinator = await world.makeCoordinator(provider: .claude, executable: true)
        coordinator.start(.rewrite(instruction: "fix", skill: nil))
        await waitUntil("not finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.readSourceCalls, 1)
        XCTAssertEqual(world.agent.turns.first?.writing?.source, "teh qiuck fox")
        XCTAssertEqual(world.applyCalls.first?.text, "the quick fox")
        XCTAssertEqual(coordinator.notice, "Replaced the selection — ⌘Z in the app undoes it")
    }
}
