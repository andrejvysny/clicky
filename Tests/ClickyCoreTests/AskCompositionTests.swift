import XCTest
@testable import ClickyCore

final class AskCompositionTests: XCTestCase {
    func testEffortCyclesLowMediumHigh() {
        XCTAssertEqual(AskEffort.low.next, .medium)
        XCTAssertEqual(AskEffort.medium.next, .high)
        XCTAssertEqual(AskEffort.high.next, .low)
        XCTAssertEqual(AskEffort.allCases.map(\.pipCount), [1, 2, 3])
    }

    func testTypedTextOnlyIsSentUnchanged() {
        let draft = "  keep\n    indentation /tmp/a b · číslo  "
        XCTAssertEqual(AskComposition.message(draft: draft, selection: nil, snippets: []), draft)
    }

    func testSelectionAloneMeansExplainThis() throws {
        let selection = try XCTUnwrap(SelectionQuote(text: "  Promise.allSettled\nreturns results  ", applicationName: "Safari"))
        XCTAssertEqual(selection.lineCount, 2)
        let message = AskComposition.message(draft: "   ", selection: selection, snippets: [])
        XCTAssertTrue(message.hasPrefix(AskComposition.explainSelectionPrompt + "\n\nSelected text from Safari:\n```\n"))
        XCTAssertTrue(message.contains("Promise.allSettled\nreturns results\n```"))
        XCTAssertTrue(AskComposition.hasContent(draft: "", selection: selection, snippets: []))
        XCTAssertFalse(AskComposition.hasContent(draft: " \n", selection: nil, snippets: []))
    }

    func testBlankSelectionIsIgnored() {
        XCTAssertNil(SelectionQuote(text: " \n\t", applicationName: "Notes"))
    }

    func testSelectionIsBoundedOnCharacterBoundary() throws {
        let selection = try XCTUnwrap(SelectionQuote(text: String(repeating: "č", count: 10_000), applicationName: "Notes"))
        XCTAssertTrue(selection.truncated)
        XCTAssertLessThanOrEqual(selection.text.utf8.count, SelectionQuote.maximumBytes)
        XCTAssertTrue(selection.text.allSatisfy { $0 == "č" })
        let message = AskComposition.message(draft: "x", selection: selection, snippets: [])
        XCTAssertTrue(message.contains("Selected text from Notes (truncated):"))
    }

    func testSnippetKeepsTextVerbatimAndFenceCannotBeClosedByContent() {
        let code = "func a() {\n    let fence = \"```\"\n}\n\n\tindented"
        let snippet = PastedSnippet(text: code)
        let message = AskComposition.message(draft: "why", selection: nil, snippets: [snippet])
        XCTAssertEqual(message, "why\n\nPasted text:\n````\n" + code + "\n````")
        XCTAssertEqual(snippet.firstLine, "func a() {")
        XCTAssertEqual(snippet.lineCount, 5)
    }

    func testPasteCollapseThreshold() {
        XCTAssertFalse(PastedSnippet.shouldCollapse("one line only " + String(repeating: "x", count: 2000)))
        XCTAssertFalse(PastedSnippet.shouldCollapse("a\nb\nc"))
        XCTAssertTrue(PastedSnippet.shouldCollapse((1...6).map(String.init).joined(separator: "\n")))
        XCTAssertTrue(PastedSnippet.shouldCollapse("a\n" + String(repeating: "y", count: 700)))
    }

    func testClaudeProfileLaunchesWithChosenEffort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = try GuideAgentProfile(provider: .claude, root: root, taskID: UUID())
        let high = try GuideAgentProfile(provider: .claude, root: root, taskID: UUID(), effort: .high)
        func effort(_ arguments: [String]) -> String? {
            arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] }
        }
        XCTAssertEqual(effort(standard.arguments), "low")
        XCTAssertEqual(effort(high.arguments), "high")
        XCTAssertEqual(GuideAgentTurn(message: "x").effort, .low)
    }
}

final class IslandLayoutTests: XCTestCase {
    func testCompactFootprintWrapsNotchOrUsesTab() {
        XCTAssertEqual(IslandLayout.compactWidth(notchWidth: 180), 300)
        XCTAssertEqual(IslandLayout.compactWidth(notchWidth: 0), 120)
        XCTAssertEqual(IslandLayout.centerGap(notchWidth: 0), 10)
    }

    func testFrameHangsFromTopCenterOfItsScreen() {
        let secondary = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let frame = IslandLayout.frame(screen: secondary, width: 460, height: 120)
        XCTAssertEqual(frame.maxY, 1440)
        XCTAssertEqual(frame.midX, secondary.midX)
        XCTAssertEqual(IslandLayout.frame(screen: CGRect(x: 0, y: 0, width: 300, height: 600), width: 460, height: 40).width, 300)
    }
}

final class AnnotationPresentationTests: XCTestCase {
    func testAnnotationRequiresTargetAndForbidsStepFields() {
        let rect = GuideRect(CGRect(x: 1, y: 2, width: 30, height: 20))
        XCTAssertNoThrow(try GuidePresentation(kind: .annotation, text: "Here", captureID: UUID(), target: rect).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "Here", captureID: UUID()).validate(), "target required")
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "Here", captureID: UUID(), target: rect,
                                                   action: GuideAction(kind: .click)).validate())
        XCTAssertTrue(GuideRequestPurpose.sideQuestion.permits(.annotation))
        XCTAssertFalse(GuideRequestPurpose.verification.permits(.annotation))
    }

    func testExplanationMayEchoCaptureID() {
        XCTAssertNoThrow(try GuidePresentation(kind: .explanation, text: "It is Terminal.", captureID: UUID()).validate())
    }
}

final class PresentationNormalizationTests: XCTestCase {
    /// Observed from Claude Haiku 5.5: an explanation of a screenshot carrying evidence and the captureID.
    func testExplanationWithEchoedEvidenceParses() throws {
        var fields: [String: JSONValue] = ["kind": .string("explanation"), "text": .string("I can see a Terminal window."),
                                           "captureID": .string(UUID().uuidString), "evidence": .string("Capture shows a terminal")]
        for key in ["target", "crop", "action", "outcome", "matches", "evidenceTarget", "proposedGoal",
                    "mark", "label", "detail", "value", "ghost", "milestone", "plan", "goalChecks",
                    "outcomeState"] { fields[key] = .null }
        let result = try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields)))
        XCTAssertEqual(result.kind, .explanation)
        XCTAssertNil(result.evidence)
    }

    func testIrrelevantStepFieldsAreDroppedNotTrusted() {
        let rect = GuideRect(CGRect(x: 1, y: 1, width: 5, height: 5))
        let prose = GuidePresentation(kind: .clarification, text: "Answer", captureID: UUID(), target: rect,
                                      action: GuideAction(kind: .click), matches: true, mark: .arrow, detail: "x").normalized()
        XCTAssertNil(prose.target); XCTAssertNil(prose.action); XCTAssertNil(prose.matches); XCTAssertNil(prose.mark)
        XCTAssertNoThrow(try prose.validate())
        // A step still needs its own fields; normalization never invents them.
        XCTAssertThrowsError(try GuidePresentation(kind: .guide_step, text: "Click", captureID: UUID(), evidence: "x").normalized().validate())
    }
}

final class AnnotationWithoutCaptureTests: XCTestCase {
    func testAnnotationMayOmitCaptureID() {
        let rect = GuideRect(CGRect(x: 10, y: 10, width: 40, height: 20))
        XCTAssertNoThrow(try GuidePresentation(kind: .annotation, text: "Here", target: rect).validate())
    }
}

final class AnnotationMarkTests: XCTestCase {
    private let rect = GuideRect(CGRect(x: 10, y: 10, width: 40, height: 20))

    func testEveryMarkRoundTripsThroughSchema() throws {
        for mark in GuidePresentation.Mark.allCases {
            let value = GuidePresentation(kind: .annotation, text: "The Wi-Fi menu is here.", captureID: UUID(), target: rect,
                                          mark: mark, label: "Wi-Fi", value: mark == .value ? "0.02 m" : nil)
            // Models fill every schema key; JSONEncoder omits nils, so add them back as null.
            guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)),
                  case .object(let properties) = GuideContract.schema["properties"] else { return XCTFail("object") }
            for key in properties.keys where fields[key] == nil { fields[key] = .null }
            let parsed = try GuidePresentation.parse(JSONEncoder().encode(JSONValue.object(fields)))
            XCTAssertEqual(parsed.mark, mark)
            XCTAssertEqual(parsed.label, "Wi-Fi")
        }
    }

    func testLocatedExplanationBecomesAnnotation() {
        let result = GuidePresentation(kind: .explanation, text: "It is the wrench icon.", captureID: UUID(), target: rect,
                                       action: GuideAction(kind: .click), mark: .circle).normalized()
        XCTAssertEqual(result.kind, .annotation)
        XCTAssertNil(result.action)
        XCTAssertNoThrow(try result.validate())
        // Without a capture the target cannot be mapped, so prose stays prose.
        XCTAssertEqual(GuidePresentation(kind: .explanation, text: "x", target: rect).normalized().kind, .explanation)
    }

    func testInvalidMarkCombinationsAreRejected() {
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "Type", target: rect, mark: .value).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "x", target: rect, ghost: rect).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "x", target: rect, plan: ["Open"]).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "x", target: rect,
                                                   label: String(repeating: "a", count: 61)).validate())
        let step = { (plan: [String]) in
            GuidePresentation(kind: .guide_step, text: "Click", captureID: UUID(), target: self.rect,
                              action: GuideAction(kind: .click), outcome: GuideOutcome(description: "Opens"), plan: plan)
        }
        XCTAssertNoThrow(try step(["Open", "Apply"]).validate())
        XCTAssertThrowsError(try step(Array(repeating: "Open", count: 9)).validate())
    }

    func testMalformedExtrasAreDroppedNotFatal() {
        let step = GuidePresentation(kind: .guide_step, text: "Click Save", captureID: UUID(), target: rect,
                                     action: GuideAction(kind: .click), outcome: GuideOutcome(description: "Saved"),
                                     mark: .value, label: String(repeating: "a", count: 80), detail: "",
                                     ghost: GuideRect(CGRect(x: 0, y: 0, width: 0, height: 0)),
                                     plan: Array(repeating: " Open ", count: 12) + [""]).normalized()
        XCTAssertNoThrow(try step.validate())
        XCTAssertEqual(step.mark, .circle)
        XCTAssertNil(step.ghost); XCTAssertNil(step.detail)
        XCTAssertEqual(step.plan, Array(repeating: "Open", count: 8))
        XCTAssertEqual(step.label?.utf8.count, 60)
    }

    func testMarkLabelFallsBackToLeadingWords() {
        XCTAssertEqual(GuidePresentation(kind: .annotation, text: "Open the wrench icon in the Properties sidebar", target: rect).markLabel,
                       "Open the wrench icon in the…")
        XCTAssertEqual(GuidePresentation(kind: .annotation, text: "Long answer", target: rect, label: "Wrench").markLabel, "Wrench")
    }
}
