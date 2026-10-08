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
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "Here", captureID: UUID()).validate())
        XCTAssertThrowsError(try GuidePresentation(kind: .annotation, text: "Here", captureID: UUID(), target: rect,
                                                   action: GuideAction(kind: .click)).validate())
        XCTAssertTrue(GuideRequestPurpose.sideQuestion.permits(.annotation))
        XCTAssertFalse(GuideRequestPurpose.verification.permits(.annotation))
    }

    func testExplanationMayEchoCaptureID() {
        XCTAssertNoThrow(try GuidePresentation(kind: .explanation, text: "It is Terminal.", captureID: UUID()).validate())
    }
}
