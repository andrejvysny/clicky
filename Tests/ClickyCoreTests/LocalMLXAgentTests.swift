import XCTest
@testable import ClickyCore

/// Replies the test supplies in order; records every request the agent sent.
private final class ScriptedLocalModel: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var requests: [LocalInferenceRequest] = []
    var delayNanoseconds: UInt64 = 0

    init(_ replies: [String]) { self.replies = replies }

    var client: LocalInferenceClient {
        { [self] request in
            lock.lock(); requests.append(request); let reply = replies.isEmpty ? "" : replies.removeFirst(); lock.unlock()
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
            return reply
        }
    }

    var sent: [LocalInferenceRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class LocalMLXAgentTests: XCTestCase {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!

    private func capture() throws -> (PNGImageAttachment, GuideCaptureContext) {
        let image = try PNGImageAttachment(data: Self.png,
            context: ScreenContextIdentity(applicationIdentifier: "fixture", windowIdentifier: 7, displayIdentifier: 2, capturedAt: Date()),
            capturedRegion: CGRect(x: 0, y: 0, width: 100, height: 50))
        let target = WindowCaptureTarget(processIdentifier: 5, windowIdentifier: 7, applicationIdentifier: "fixture", applicationName: "Fixture")
        var task = GuideTaskState(goal: "Fixture goal"); task.authorize(target)
        return (image, try GuideCaptureContext(image: image, target: target, task: task))
    }

    // MARK: Reply normalization

    func testBareObjectInProseAndFencesIsAccepted() throws {
        let output = "Sure!\n```json\n{\"kind\": \"explanation\", \"text\": \"Use {braces} \\\"quoted\\\"\"}\n```"
        let value = try LocalReply.presentation(from: output, purpose: .planning, frame: nil)
        XCTAssertEqual(value.kind, .explanation)
        XCTAssertEqual(value.text, "Use {braces} \"quoted\"")
    }

    func testGridBoxBecomesPixelsAndCaptureIDIsTheSentImage() throws {
        let capture = UUID()
        let frame = LocalReply.ImageFrame(captureID: capture, pixelWidth: 2000, pixelHeight: 1000)
        let output = #"{"presentation": {"kind": "annotation", "text": "Here is Save", "target": [100, 200, 300, 400], "mark": "circle", "label": "Save", "captureID": "made-up"}}"#
        let value = try LocalReply.presentation(from: output, purpose: .planning, frame: frame)
        XCTAssertEqual(value.captureID, capture)
        let target = try XCTUnwrap(value.target)
        XCTAssertEqual(target.x, 200, accuracy: 0.001); XCTAssertEqual(target.y, 200, accuracy: 0.001)
        XCTAssertEqual(target.width, 400, accuracy: 0.001); XCTAssertEqual(target.height, 200, accuracy: 0.001)
    }

    func testAnnotationDefaultsMarkAndLabelButNeverInventsTarget() throws {
        let frame = LocalReply.ImageFrame(captureID: UUID(), pixelWidth: 100, pixelHeight: 100)
        let marked = try LocalReply.presentation(from: #"{"kind":"annotation","text":"The blue Save button at the top","target":[0,0,10,10]}"#,
                                                 purpose: .planning, frame: frame)
        XCTAssertEqual(marked.mark, .circle)
        XCTAssertEqual(marked.label, "The blue Save button at the")
        XCTAssertThrowsError(try LocalReply.presentation(from: #"{"kind":"annotation","text":"Save","mark":"circle","label":"Save"}"#,
                                                         purpose: .planning, frame: frame))
    }

    func testInvalidBoxIsNotGuessed() throws {
        let frame = LocalReply.ImageFrame(captureID: UUID(), pixelWidth: 100, pixelHeight: 100)
        for box in ["[300, 200, 100, 400]", "[0, 0, 5000, 10]", "[1, 2, 3]"] {
            let output = #"{"kind":"annotation","text":"Save","mark":"circle","label":"Save","target":"# + box + "}"
            XCTAssertThrowsError(try LocalReply.presentation(from: output, purpose: .planning, frame: frame), box)
        }
    }

    func testGuideStepFillsNullableDecorationsAndKeyModifiers() throws {
        let frame = LocalReply.ImageFrame(captureID: UUID(), pixelWidth: 1000, pixelHeight: 1000)
        let output = #"""
        {"presentation": {"kind": "guide_step", "text": "Type the name, then press Tab", "target": [10, 10, 200, 60],
         "action": {"kind": "field_commit", "keyCode": 48}, "outcome": "The name field shows Report",
         "milestone": "Name the file", "goalChecks": ["The file is named Report"], "matches": true}}
        """#
        let value = try LocalReply.presentation(from: output, purpose: .planning, frame: frame)
        XCTAssertEqual(value.kind, .guide_step)
        XCTAssertEqual(value.action?.modifiers, 0)
        XCTAssertEqual(value.outcome?.description, "The name field shows Report")
        XCTAssertEqual(value.plan, ["Name the file"])
        XCTAssertNil(value.matches)
    }

    func testVerificationKeepsOutcomeStateAndDropsStepFields() throws {
        let capture = UUID()
        let frame = LocalReply.ImageFrame(captureID: capture, pixelWidth: 100, pixelHeight: 100)
        let output = #"{"kind":"verification_result","text":"Opened","matches":true,"outcomeState":"confirmed","evidence":"Title visible","evidenceTarget":[100,100,500,500],"target":[0,0,10,10],"plan":["x"]}"#
        let value = try LocalReply.presentation(from: output, purpose: .verification, frame: frame)
        XCTAssertEqual(value.outcomeState, .confirmed)
        XCTAssertEqual(value.captureID, capture)
        XCTAssertNil(value.target)
        XCTAssertEqual(value.evidenceTarget?.width ?? 0, 40, accuracy: 0.001)
    }

    func testBlindStepOrMarkBecomesContextRequest() throws {
        let step = #"{"kind":"guide_step","text":"Click Save","target":[1,1,5,5],"action":{"kind":"click"},"outcome":{"description":"Saved"},"milestone":"Save","plan":["Save"],"goalChecks":["Saved"]}"#
        let mark = #"{"kind":"annotation","text":"Save","target":[812,40,905,88],"mark":"circle","label":"Save"}"#
        for output in [step, mark] {
            for purpose in [GuideRequestPurpose.planning, .sideQuestion] {
                let value = try LocalReply.presentation(from: output, purpose: purpose, frame: nil)
                XCTAssertEqual(value.kind, .context_request)
                XCTAssertNil(value.target)
                XCTAssertNil(value.crop)
            }
        }
        // An image that is not a host capture (no captureID) cannot ground a step either.
        let uncaptured = LocalReply.ImageFrame(captureID: nil, pixelWidth: 100, pixelHeight: 100)
        XCTAssertEqual(try LocalReply.presentation(from: step, purpose: .planning, frame: uncaptured).kind, .context_request)
    }

    func testPurposeStillGatesKinds() {
        XCTAssertThrowsError(try LocalReply.presentation(from: #"{"kind":"explanation","text":"x"}"#, purpose: .writing, frame: nil)) {
            XCTAssertTrue($0 is GuideWrongPurpose)
        }
    }

    // MARK: Agent

    func testWritingDraftAndHistoryIsResent() async throws {
        let model = ScriptedLocalModel([#"{"presentation":{"kind":"writing_draft","text":"Hello\n  world","subject":null}}"#,
                                        #"{"presentation":{"kind":"writing_draft","text":"Hi","subject":null}}"#])
        let agent = LocalMLXAgent(contract: .writing, client: model.client)
        let payload = WritingHostPayload(operation: .draft, skill: nil, source: nil, reference: nil, surrounding: nil,
                                         destination: .none, previousDraft: nil, refinement: nil)
        let first = try await agent.turn(GuideAgentTurn(message: "Greet", purpose: .writing, writing: payload))
        XCTAssertEqual(first.text, "Hello\n  world")
        _ = try await agent.turn(GuideAgentTurn(message: "Shorter", purpose: .writing, writing: payload))
        let second = try XCTUnwrap(model.sent.last)
        XCTAssertEqual(second.messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(second.messages[0].text, LocalPrompt.writing)
        XCTAssertNil(second.image)
        XCTAssertEqual(second.parameters.maximumTokens, LocalWorkerProtocol.maximumOutputTokens)
    }

    func testOneRepairTurnThenFailure() async throws {
        let model = ScriptedLocalModel(["not json", #"{"kind":"explanation","text":"Fixed"}"#, "still bad", "bad again"])
        let agent = LocalMLXAgent(contract: .guide, client: model.client)
        let repaired = try await agent.turn(GuideAgentTurn(message: "What is this?"))
        XCTAssertEqual(repaired.text, "Fixed")
        let repair = model.sent[1].messages
        XCTAssertEqual(repair.suffix(2).map(\.role), [.assistant, .user])
        XCTAssertTrue(repair.last!.text.contains("could not be used"))
        do { _ = try await agent.turn(GuideAgentTurn(message: "Again")); XCTFail("expected failure") }
        catch let error as AskError { if case .protocolFailure = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(model.sent.count, 4)
        // Only the repaired exchange is remembered: system, its user/assistant pair, then this request and its repair.
        XCTAssertEqual(model.sent[3].messages.count, 1 + 2 + 3)
    }

    func testLatestImageIsAttachedAndAnnotationUsesItsCapture() async throws {
        let (image, context) = try capture()
        let model = ScriptedLocalModel([#"{"kind":"context_request","text":"Need the screen","crop":null}"#,
                                        #"{"kind":"annotation","text":"Here","target":[0,0,500,500],"mark":"circle","label":"Here"}"#,
                                        #"{"kind":"explanation","text":"It saves the file"}"#])
        let agent = LocalMLXAgent(contract: .guide, client: model.client)
        _ = try await agent.turn(GuideAgentTurn(message: "Where is Save?"))
        XCTAssertNil(model.sent[0].image)
        let mark = try await agent.turn(GuideAgentTurn(message: "Where is Save?", image: image, context: context))
        XCTAssertEqual(mark.captureID, context.captureID)
        XCTAssertEqual(model.sent[1].image, image.data)
        XCTAssertTrue(model.sent[1].messages.last!.text.contains("attached"))
        XCTAssertFalse(model.sent[1].messages.last!.text.contains(context.captureID.uuidString))
        _ = try await agent.turn(GuideAgentTurn(message: "What does it do?"))
        XCTAssertEqual(model.sent[2].image, image.data, "follow-ups keep seeing the latest capture")
    }

    func testDifferentCaptureWithoutImageIsNotAttached() async throws {
        let (image, context) = try capture()
        let (_, other) = try capture()
        let model = ScriptedLocalModel([#"{"kind":"explanation","text":"a"}"#, #"{"kind":"explanation","text":"b"}"#])
        let agent = LocalMLXAgent(contract: .guide, client: model.client)
        _ = try await agent.turn(GuideAgentTurn(message: "one", image: image, context: context))
        _ = try await agent.turn(GuideAgentTurn(message: "two", context: other))
        XCTAssertNil(model.sent[1].image)
    }

    func testWrongPurposeIsRememberedForTheSharedCorrection() async throws {
        let model = ScriptedLocalModel([#"{"kind":"explanation","text":"nope"}"#,
                                        #"{"kind":"writing_draft","text":"Draft","subject":null}"#])
        let agent = LocalMLXAgent(contract: .writing, client: model.client)
        let (value, corrected) = try await agent.turnAllowingOneCorrection(GuideAgentTurn(message: "Write", purpose: .writing))
        XCTAssertTrue(corrected)
        XCTAssertEqual(value.text, "Draft")
        XCTAssertEqual(model.sent[1].messages.map(\.role), [.system, .user, .assistant, .user])
    }

    func testBusyCloseAndCancellation() async throws {
        let model = ScriptedLocalModel([#"{"kind":"explanation","text":"slow"}"#])
        model.delayNanoseconds = 5_000_000_000
        let agent = LocalMLXAgent(contract: .guide, client: model.client)
        let running = Task { try await agent.turn(GuideAgentTurn(message: "slow")) }
        while model.sent.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        do { _ = try await agent.turn(GuideAgentTurn(message: "second")); XCTFail("expected busy") }
        catch let error as AskError { XCTAssertEqual(error, .busy) }
        running.cancel()
        do { _ = try await running.value; XCTFail("expected cancellation") } catch {}
        await agent.close()
        do { _ = try await agent.turn(GuideAgentTurn(message: "after")); XCTFail("closed agent reused") }
        catch let error as AskError { XCTAssertEqual(error, .incompleteTurn) }
    }

    func testTimeoutFails() async throws {
        let model = ScriptedLocalModel([#"{"kind":"explanation","text":"late"}"#])
        model.delayNanoseconds = 2_000_000_000
        let agent = LocalMLXAgent(contract: .guide, client: model.client, timeoutNanoseconds: 50_000_000)
        do { _ = try await agent.turn(GuideAgentTurn(message: "x")); XCTFail("expected timeout") }
        catch let error as AskError { if case .protocolFailure = error {} else { XCTFail("\(error)") } }
    }

    func testHistoryIsTrimmedButCurrentRequestKept() throws {
        let big = String(repeating: "a", count: 30_000)
        let conversation = [LocalChatMessage(role: .user, text: big), LocalChatMessage(role: .assistant, text: big),
                            LocalChatMessage(role: .user, text: "now")]
        let bounded = try LocalMLXAgent.bounded(system: "system", conversation: conversation)
        XCTAssertEqual(bounded.map(\.text), ["system", "now"])
        XCTAssertThrowsError(try LocalMLXAgent.bounded(system: "s", conversation: [LocalChatMessage(role: .user, text: big + big + big)]))
    }

    func testRenderedRequestDropsGeometryAndIdentifiers() throws {
        let step = try LocalReply.presentation(
            from: #"{"kind":"guide_step","text":"Click Save","target":[1,1,5,5],"action":{"kind":"click"},"outcome":{"description":"Saved"},"milestone":"Save","plan":["Save"],"goalChecks":["Saved"]}"#,
            purpose: .planning, frame: LocalReply.ImageFrame(captureID: UUID(), pixelWidth: 100, pixelHeight: 100))
        let rendered = LocalMLXAgent.compact(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(step)))
        XCTAssertEqual(rendered["target"], .null)
        XCTAssertEqual(rendered["captureID"], .null)
        XCTAssertEqual(rendered["text"], .string("Click Save"))
        XCTAssertEqual(rendered["outcome"]["description"], .string("Saved"))
        XCTAssertEqual(LocalMLXAgent.render(GuideAgentTurn(message: "Hi"), imageAttached: false).contains("\"request\":\"Hi\""), true)
    }

    func testPromptsStaySmall() {
        XCTAssertLessThan(LocalPrompt.guide.utf8.count, 6_000)
        XCTAssertLessThan(LocalPrompt.writing.utf8.count, 3_000)
    }
}
