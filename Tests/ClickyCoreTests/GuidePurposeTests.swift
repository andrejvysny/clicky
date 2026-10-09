import XCTest
@testable import ClickyCore

final class GuidePurposeTests: XCTestCase {
    private func fields(kind: GuidePresentation.Kind) -> [String: JSONValue] {
        guard case .object(let properties) = GuideContract.schema["properties"] else { return [:] }
        var fields = properties.mapValues { _ in JSONValue.null }
        fields["kind"] = .string(kind.rawValue); fields["text"] = .string("Fixture")
        return fields
    }

    private func capture() throws -> GuideCaptureContext {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!
        let image = try PNGImageAttachment(data: bytes,
            context: ScreenContextIdentity(applicationIdentifier: "fixture", windowIdentifier: 7, displayIdentifier: 2, capturedAt: Date()),
            capturedRegion: CGRect(x: 0, y: 0, width: 100, height: 50))
        let target = WindowCaptureTarget(processIdentifier: 5, windowIdentifier: 7, applicationIdentifier: "fixture", applicationName: "Fixture")
        var task = GuideTaskState(goal: "Fixture goal"); task.authorize(target)
        return try GuideCaptureContext(image: image, target: target, task: task)
    }

    private func session(_ provider: AgentProvider) throws -> (GuideAgentSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-purpose-" + UUID().uuidString)
        let profile = try GuideAgentProfile(provider: provider, root: root, taskID: UUID())
        let fixture = Bundle.module.url(forResource: "guide-agent", withExtension: "py", subdirectory: "Fixtures")!
        let executable = root.appendingPathComponent("fixture")
        try Data(("#!/bin/sh\nexec /usr/bin/env python3 '" + fixture.path + "' \"$@\"\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (GuideAgentSession(profile: profile, executable: executable, validateProfile: false), root)
    }

    func testEveryPurposeSchemaMatchesOwnedKindPermissions() {
        for purpose in [GuideRequestPurpose.planning, .verification, .sideQuestion, .continuation, .recovery, .oneOffContext] {
            let allowed = GuideContract.schema(for: purpose)["properties"]["kind"]["enum"].array.compactMap(\.string)
            for kind in GuideContract.allowedKinds(for: .planning) + [.verification_result] {
                XCTAssertEqual(allowed.contains(kind.rawValue), purpose.permits(kind))
            }
        }
    }

    func testVerificationAndSideQuestionRejectProgressKindsBeforeNormalization() throws {
        for kind in [GuidePresentation.Kind.guide_step, .task_completed, .explanation, .context_request] {
            XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields(kind: kind))), purpose: .verification)) {
                XCTAssertTrue($0.localizedDescription.contains("wrong_purpose at $.kind"))
                XCTAssertTrue($0.localizedDescription.contains("kind=" + kind.rawValue + ", purpose=verification"))
            }
        }
        for kind in [GuidePresentation.Kind.guide_step, .task_completed, .verification_result] {
            XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields(kind: kind))), purpose: .sideQuestion))
        }
    }

    func testFalseVerificationRemainsValidAndCannotCarryStepFields() throws {
        var value = fields(kind: .verification_result)
        value["captureID"] = .string(UUID().uuidString); value["matches"] = .bool(false); value["outcomeState"] = .string("unknown")
        value["evidence"] = .string("Intended value is not visible")
        value["evidenceTarget"] = .object(["x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])
        XCTAssertEqual(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(value)), purpose: .verification).matches, false)
        value["action"] = .object(["kind": .string("click"), "keyCode": .null, "modifiers": .null])
        XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(value)), purpose: .verification)) {
            XCTAssertTrue($0.localizedDescription.contains("wrong_type at $.action"))
        }
        value["action"] = .null; value["matches"] = .null
        XCTAssertThrowsError(try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(value)), purpose: .verification))
    }

    func testHostVerificationContractNamesExclusiveOutputAndHostAdvancement() throws {
        let turn = GuideAgentTurn(message: "Check committed value", context: try capture(), purpose: .verification)
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(turn.text.utf8))
        XCTAssertEqual(request["allowedKinds"], .array([.string("verification_result")]))
        XCTAssertTrue(request["responseContract"].string?.contains("matches=false if uncertain") == true)
        XCTAssertTrue(request["responseContract"].string?.contains("Never choose a next step or task_completed") == true)
        XCTAssertTrue(request["responseContract"].string?.contains("host decides advancement") == true)
    }

    func testBothProviderSessionsPreserveConversationAcrossVerification() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let (agent, root) = try session(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await agent.turn(GuideAgentTurn(message: "planning"))
            let identifier = await agent.identifier()
            let context = try capture()
            let verdict = try await agent.turn(GuideAgentTurn(message: "verification-false", context: context, purpose: .verification))
            XCTAssertEqual(verdict.matches, false); XCTAssertEqual(verdict.captureID, context.captureID)
            let continuation = try await agent.turn(GuideAgentTurn(message: "continue", purpose: .continuation))
            XCTAssertEqual(continuation.text, "turn 3: continue")
            let currentIdentifier = await agent.identifier()
            XCTAssertEqual(identifier, currentIdentifier)
            await agent.close()
        }
    }

    func testWrongPurposeClosesBothProvidersWithoutReplay() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let (agent, root) = try session(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await agent.turn(GuideAgentTurn(message: "wrong-purpose", purpose: .verification))
                XCTFail("Wrong kind accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("wrong_purpose at $.kind"))
            }
            do { _ = try await agent.turn(GuideAgentTurn(message: "replay")); XCTFail("Closed session reused") }
            catch { XCTAssertEqual(error as? AskError, .incompleteTurn) }
            await agent.close()
        }
    }

    func testBothTransportsRequireStepOutcomeFromTheirActualWireSchema() async throws {
        for provider in [AgentProvider.claude, .codex] {
            for message in ["valid-step", "missing-outcome", "null-outcome"] {
                let (agent, root) = try session(provider)
                defer { try? FileManager.default.removeItem(at: root) }
                let turn = GuideAgentTurn(message: message, context: try capture())
                if message == "valid-step" {
                    let step = try await agent.turn(turn)
                    XCTAssertEqual(step.kind, .guide_step); XCTAssertEqual(step.outcome?.description, "Fixture panel opens")
                } else {
                    do { _ = try await agent.turn(turn); XCTFail("Invalid step accepted") }
                    catch { XCTAssertTrue(error.localizedDescription.contains("at $.outcome"), error.localizedDescription) }
                    do { _ = try await agent.turn(turn); XCTFail("Failed request replayed") }
                    catch { XCTAssertEqual(error as? AskError, .incompleteTurn) }
                }
                await agent.close()
            }
        }
    }
}
