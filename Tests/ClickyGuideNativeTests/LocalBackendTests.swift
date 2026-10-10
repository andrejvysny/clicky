import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// Model text the test supplies in order, as the on-device worker would return it.
private final class LocalModelScript: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var requests: [LocalInferenceRequest] = []
    init(_ replies: [String]) { self.replies = replies }

    var client: LocalInferenceClient {
        { [self] request in
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return replies.isEmpty ? "" : replies.removeFirst()
        }
    }
    var sent: [LocalInferenceRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// The production coordinators over the real `LocalMLXAgent`, with scripted model text instead of MLX.
@MainActor
final class LocalBackendTests: XCTestCase {
    // The harness capture is 64 × 48 px; these grid boxes map to its step target and evidence rectangles.
    private let stepBox = "[156.25, 208.34, 343.75, 375]"
    private let evidenceBox = "[468.75, 416.67, 781.25, 833.33]"

    func testWalkthroughStepVerificationAndNextStepWithoutExecutable() async throws {
        let model = LocalModelScript([
            #"{"presentation": {"kind": "guide_step", "text": "Click Settings", "target": "# + stepBox + #", "action": {"kind": "click"}, "outcome": {"description": "Settings panel is open"}, "milestone": "Open Settings", "plan": ["Open Settings"], "goalChecks": ["Settings panel is open"]}}"#,
            #"{"presentation": {"kind": "verification_result", "text": "Opened", "matches": true, "outcomeState": "confirmed", "evidence": "Panel title visible", "evidenceTarget": "# + evidenceBox + #"}}"#,
            #"{"presentation": {"kind": "guide_step", "text": "Click Apply", "target": [468.75, 625, 625, 791.67], "action": {"kind": "click"}, "outcome": {"description": "Changes are applied"}, "milestone": "Apply", "plan": ["Apply"], "goalChecks": ["Settings panel is open"]}}"#,
        ])
        let harness = GuideHarness(localModel: model.client)
        XCTAssertNil(harness.controller.executable)
        try harness.controller.ask("Open the fixture settings", target: harness.screen.target)
        await waitUntil("first step") { harness.controller.task?.phase == .waiting }
        XCTAssertNil(harness.controller.error)
        XCTAssertEqual(harness.shownTargets.count, 1)
        XCTAssertNotNil(model.sent[0].image, "on-device planning carries the shared window up front")

        harness.click(at: CGPoint(x: 15, y: 14), time: 10)
        await harness.clock.advance(1)
        await waitUntil("next step") { harness.controller.task?.step?.text == "Click Apply" }
        XCTAssertEqual(harness.controller.task?.milestones.map(\.completion), [.verified])
        XCTAssertEqual(model.sent.count, 3)
        XCTAssertTrue(model.sent.allSatisfy { $0.messages.first?.text == LocalPrompt.guide })
    }

    func testMalformedReplyGetsOneRepairThenNeedsAttention() async throws {
        let model = LocalModelScript(["I think you should click it", "still not json"])
        let harness = GuideHarness(localModel: model.client)
        try harness.controller.ask("What is this?", target: harness.screen.target)
        await waitUntil("error shown") { harness.controller.error != nil }
        XCTAssertEqual(model.sent.count, 2)
        XCTAssertFalse(harness.controller.isBusy)
        XCTAssertTrue(harness.shownTargets.isEmpty)
    }

    func testWritingDraftIsGeneratedAndAppliedWithoutExecutable() async throws {
        let model = LocalModelScript([#"{"presentation": {"kind": "writing_draft", "text": "Hello,\n  Anna", "subject": null}}"#])
        let world = FakeWritingWorld()
        world.localModel = model.client
        let coordinator = await world.makeCoordinator(provider: .local, executable: false)
        coordinator.start(.write(instruction: "greet Anna", skill: nil))
        await waitUntil("finished") { coordinator.phase == .finished }
        XCTAssertEqual(world.applyCalls.first?.text, "Hello,\n  Anna")
        XCTAssertEqual(coordinator.proposal?.provenance, .generated(provider: .local, skillID: nil, skillRevision: nil))
        XCTAssertEqual(model.sent.first?.messages.first?.text, LocalPrompt.writing)
    }
}
