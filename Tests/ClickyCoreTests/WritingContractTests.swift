import XCTest
@testable import ClickyCore

final class WritingContractTests: XCTestCase {
    private func target(_ kind: WritingTargetKind = .textField, selection: UTF16Range = .caret(4)!,
                        blocked: WritingBlockReason? = nil) -> TextTargetSnapshot {
        TextTargetSnapshot(kind: kind, applicationName: "Fixture", bundleIdentifier: "com.example", processIdentifier: 42,
                           windowIdentifier: 7, paneIdentity: nil, selection: selection, contentRevision: "63", blockedReason: blocked)
    }
    private let generated = WritingProvenance.generated(provider: .claude, skillID: nil, skillRevision: nil)

    func testWriteAndSnippetAutoInsertOnlyAtAnEmptyCaret() {
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: target(), text: "Hi", provenance: generated), .automatic)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: target(), text: "Hi", provenance: .snippet(id: UUID(), revision: 1)), .automatic)
        let selected = target(selection: UTF16Range(location: 0, length: 5)!)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: selected, text: "Hi", provenance: generated), .review(replacesSelection: true))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: selected, text: "Hi", provenance: .snippet(id: UUID(), revision: 1)),
                       .review(replacesSelection: true))
    }

    func testRewriteNeverAutoAppliesAndPreviewNeverApplies() {
        let selected = target(selection: UTF16Range(location: 0, length: 5)!)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .rewrite, target: selected, text: "x", provenance: generated), .review(replacesSelection: true))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .rewrite, target: target(), text: "x", provenance: generated), .previewOnly(.noSelection))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: target(), text: "x", provenance: .preview), .previewOnly(.previewBackend))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: nil, text: "x", provenance: generated), .previewOnly(.noTarget))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: target(blocked: .secureField), text: "x", provenance: generated),
                       .previewOnly(.secureField))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .draft, target: target(), text: "", provenance: generated), .previewOnly(.emptyText))
    }

    func testTerminalAcceptsOnlySingleLinePrintableText() {
        let terminal = target(.terminal)
        let snippet = WritingProvenance.snippet(id: UUID(), revision: 1)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "docker compose logs --follow --tail 200", provenance: snippet), .automatic)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "echo \"$(date)\" | tr 'a' `b`; x && y", provenance: snippet), .automatic)
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "ls\n", provenance: snippet), .previewOnly(.terminalMultiline))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "a\r\nb", provenance: snippet), .previewOnly(.terminalMultiline))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "a\tb", provenance: snippet), .previewOnly(.terminalControlCharacters))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .snippet, target: terminal, text: "a\u{1B}[201~b", provenance: snippet), .previewOnly(.terminalControlCharacters))
        XCTAssertEqual(WritingApplyPlan.decide(intent: .rewrite, target: terminal, text: "a", provenance: generated), .previewOnly(.selectionInTerminalHistory))
    }

    func testTerminalHazards() {
        XCTAssertEqual(TerminalPayload.classify("printf 'a\\nb'"), .singleLine, "literal backslash-n is not a newline")
        XCTAssertEqual(TerminalPayload.classify("a\u{2028}b"), .multiline)
        XCTAssertEqual(TerminalPayload.classify("a\u{85}b"), .multiline)
        XCTAssertEqual(TerminalPayload.classify("a\u{0}b"), .unsafe([.controlCharacter]))
        XCTAssertEqual(TerminalPayload.classify("a\u{7F}"), .unsafe([.controlCharacter]))
        XCTAssertEqual(TerminalPayload.classify(""), .unsafe([.empty]))
        XCTAssertEqual(TerminalPayload.classify("ťžčô 😀 e\u{301}"), .singleLine)
    }

    func testUTF16RangesRespectSurrogatesAndCombiningMarks() throws {
        let text = "a😀e\u{301}ť"
        XCTAssertEqual(text.utf16.count, 6)
        let emoji = try XCTUnwrap(UTF16Range(location: 1, length: 2)?.range(in: text))
        XCTAssertEqual(String(text[emoji]), "😀")
        XCTAssertNil(UTF16Range(location: 2, length: 1)?.range(in: text), "splits a surrogate pair")
        XCTAssertNil(UTF16Range(location: 0, length: 7)?.range(in: text))
        XCTAssertNil(UTF16Range(location: -1, length: 1))
        XCTAssertEqual(UTF16Range(location: 3, length: 0)!.replaced(by: "😀x"), UTF16Range(location: 3, length: 3))
    }

    func testExactSourceRejectsMismatchAndOversize() throws {
        XCTAssertNoThrow(try ExactSource(text: "  keep \n", range: UTF16Range(location: 2, length: 8)!))
        XCTAssertThrowsError(try ExactSource(text: "abc", range: UTF16Range(location: 0, length: 4)!))
        let large = String(repeating: "a", count: ExactSource.maximumUTF16 + 1)
        XCTAssertThrowsError(try ExactSource(text: large, range: UTF16Range(location: 0, length: large.utf16.count)!)) {
            XCTAssertEqual($0 as? WritingContractError, .sourceTooLarge)
        }
    }

    func testTargetChangesAreClassified() {
        let original = target()
        XCTAssertNil(original.change(comparedWith: target()))
        XCTAssertEqual(original.change(comparedWith: nil), .targetUnavailable)
        XCTAssertEqual(original.change(comparedWith: target(selection: .caret(5)!)), .selectionChanged)
        let otherWindow = TextTargetSnapshot(kind: .textField, applicationName: "Fixture", bundleIdentifier: "com.example", processIdentifier: 42,
                                             windowIdentifier: 8, paneIdentity: nil, selection: .caret(4)!, contentRevision: "63")
        XCTAssertEqual(original.change(comparedWith: otherWindow), .targetChanged)
        let edited = TextTargetSnapshot(kind: .textField, applicationName: "Fixture", bundleIdentifier: "com.example", processIdentifier: 42,
                                        windowIdentifier: 7, paneIdentity: nil, selection: .caret(4)!, contentRevision: "64")
        XCTAssertEqual(original.change(comparedWith: edited), .contentChanged)
    }

    func testClaimsAreAtMostOncePerRevision() {
        var claims = WritingApplyClaims()
        let operation = UUID()
        XCTAssertTrue(claims.claim(operationID: operation, revision: 1))
        XCTAssertFalse(claims.claim(operationID: operation, revision: 1))
        XCTAssertTrue(claims.claim(operationID: operation, revision: 2))
    }

    func testWritingPurposeAcceptsOnlyDraftsAndClarifications() throws {
        XCTAssertEqual(GuideContract.allowedKinds(for: .writing), [.clarification, .writing_draft])
        for purpose in [GuideRequestPurpose.planning, .sideQuestion, .verification, .continuation, .recovery, .oneOffContext] {
            XCTAssertFalse(GuideContract.allowedKinds(for: purpose).contains(.writing_draft))
        }
        let draft = Data(#"{"presentation":{"kind":"writing_draft","text":"Hello,\n\n  indented\n","subject":" Internship "}}"#.utf8)
        let parsed = try GuidePresentation.parseResponse(draft, purpose: .writing)
        XCTAssertEqual(try WritingReply(parsed), .draft(text: "Hello,\n\n  indented\n", subject: "Internship"))
        let step = Data(#"{"presentation":{"kind":"explanation","text":"x"}}"#.utf8)
        XCTAssertThrowsError(try GuidePresentation.parseResponse(step, purpose: .writing)) { XCTAssertTrue($0 is GuideWrongPurpose) }
        XCTAssertThrowsError(try GuidePresentation.parseResponse(draft, purpose: .planning)) { XCTAssertTrue($0 is GuideWrongPurpose) }
        let extra = Data(#"{"presentation":{"kind":"writing_draft","text":"x","subject":null,"target":null}}"#.utf8)
        XCTAssertThrowsError(try GuidePresentation.parseResponse(extra, purpose: .writing))
        let blank = Data(#"{"presentation":{"kind":"writing_draft","text":" \n","subject":null}}"#.utf8)
        XCTAssertThrowsError(try GuidePresentation.parseResponse(blank, purpose: .writing))
    }

    func testOversizedDraftIsRejected() {
        let text = String(repeating: "a", count: WritingPrompt.maximumDraftBytes + 1)
        let data = try! JSONEncoder().encode(JSONValue.object(["presentation": .object(["kind": .string("writing_draft"), "text": .string(text), "subject": .null])]))
        XCTAssertThrowsError(try GuidePresentation.parseResponse(data, purpose: .writing))
    }

    func testHostRequestCarriesWritingPayloadAndVersion() throws {
        let payload = WritingHostPayload(operation: .rewrite, source: "  exact\tsource\n", destination: .textField)
        let turn = GuideAgentTurn(message: "/shorten", purpose: .writing, writing: payload)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: Data(turn.text.utf8))
        XCTAssertEqual(encoded["protocolVersion"], .string(WritingPrompt.promptVersion))
        XCTAssertEqual(encoded["writing"]["source"], .string("  exact\tsource\n"))
        XCTAssertEqual(encoded["writing"]["operation"], .string("rewrite"))
        XCTAssertEqual(encoded["allowedKinds"], .array([.string("clarification"), .string("writing_draft")]))
        let guide = try JSONDecoder().decode(JSONValue.self, from: Data(GuideAgentTurn(message: "x").text.utf8))
        XCTAssertEqual(guide["writing"], .null)
        XCTAssertEqual(guide["protocolVersion"], .string(GuideContract.promptVersion))
    }

    func testWritingProfileLaunchesWithWritingPromptAndSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try GuideAgentProfile(provider: .claude, root: root, taskID: UUID(), contract: .writing)
        XCTAssertEqual(try String(contentsOf: profile.promptFile, encoding: .utf8), WritingPrompt.prompt)
        let schemaIndex = try XCTUnwrap(profile.arguments.firstIndex(of: "--json-schema"))
        let schema = profile.arguments[schemaIndex + 1]
        XCTAssertTrue(schema.contains("writing_draft"))
        XCTAssertFalse(schema.contains(#""enum":["guide_step"]"#), "guide kinds are not offered to writing")
        XCTAssertTrue(profile.arguments.contains("--disable-slash-commands"))
        let guide = try GuideAgentProfile(provider: .claude, root: root, taskID: UUID())
        let guideSchema = guide.arguments[try XCTUnwrap(guide.arguments.firstIndex(of: "--json-schema")) + 1]
        XCTAssertFalse(guideSchema.contains("writing_draft"))
        XCTAssertTrue(guideSchema.contains(#""enum":["guide_step"]"#))
        var codex = GuideCodexProtocol(directory: root.path, contract: .writing)
        _ = codex.initialize()
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(GuideContract.responseSchema(for: .writing)), as: UTF8.self).contains("subject"))
    }

    func testBuiltInActionInstructions() {
        XCTAssertNotNil(WritingActionInstruction.instruction(for: "fix", argument: ""))
        XCTAssertNil(WritingActionInstruction.instruction(for: "translate", argument: "  "))
        XCTAssertTrue(WritingActionInstruction.instruction(for: "translate", argument: "Slovak")!.contains("Slovak"))
    }
}
