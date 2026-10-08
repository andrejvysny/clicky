import XCTest
@testable import ClickyCore

final class AttachmentTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZrR8AAAAASUVORK5CYII=")!

    private func target(window: UInt32 = 12) -> WindowCaptureTarget {
        WindowCaptureTarget(processIdentifier: 123, windowIdentifier: window, applicationIdentifier: "test.app", applicationName: "Test App")
    }

    private func image(window: UInt32 = 12) throws -> PNGImageAttachment {
        try PNGImageAttachment(data: Self.png, context: ScreenContextIdentity(applicationIdentifier: "test.app", windowIdentifier: window, displayIdentifier: 1, capturedAt: Date()))
    }

    func testPNGDimensionsAndRejectsTruncatedOversizedAndUnsafeDimensions() throws {
        let png = try image()
        XCTAssertEqual(png.pixelWidth, 1)
        XCTAssertEqual(png.pixelHeight, 1)
        let prefixed = Data([0, 0, 0]) + Self.png
        let sliced = try PNGImageAttachment(data: prefixed.dropFirst(3))
        XCTAssertEqual(sliced.pixelWidth, 1)
        XCTAssertThrowsError(try PNGImageAttachment(data: Data(Self.png.dropLast())))
        XCTAssertThrowsError(try PNGImageAttachment(data: Data(repeating: 0, count: PNGImageAttachment.maximumBytes + 1))) { error in
            XCTAssertEqual(error as? AttachmentError, .imageTooLarge)
        }
        var oversizedDimensions = Self.png
        oversizedDimensions.replaceSubrange(16..<20, with: [0, 0, 16, 1])
        XCTAssertThrowsError(try PNGImageAttachment(data: oversizedDimensions))
    }

    func testCaptureRequiresTargetAndRejectsMismatchedWindow() throws {
        var state = WindowAttachmentState()
        XCTAssertThrowsError(try state.beginCapture())
        state.beginPresentation(target: target())
        let lease = try state.beginCapture()
        XCTAssertThrowsError(try state.beginCapture())
        XCTAssertFalse(state.accept(try image(window: 13), lease: lease))
        XCTAssertNil(state.attachment)
        XCTAssertTrue(state.accept(try image(), lease: lease))
        XCTAssertNotNil(state.attachment)
    }

    func testDismissAndNewPresentationCannotAcceptOldCapture() throws {
        var state = WindowAttachmentState()
        state.beginPresentation(target: target())
        let old = try state.beginCapture()
        state.endPresentation()
        XCTAssertFalse(state.accept(try image(), lease: old))
        state.beginPresentation(target: target())
        let current = try state.beginCapture()
        XCTAssertFalse(state.accept(try image(), lease: old))
        XCTAssertFalse(state.fail(lease: old))
        XCTAssertEqual(state.pending, current)
        XCTAssertTrue(state.accept(try image(), lease: current))
    }

    func testDiscardInvalidatesPendingCaptureAndRemovesSnapshot() throws {
        var state = WindowAttachmentState()
        state.beginPresentation(target: target())
        let canceled = try state.beginCapture()
        state.discard()
        XCTAssertFalse(state.accept(try image(), lease: canceled))
        let retry = try state.beginCapture()
        XCTAssertTrue(state.accept(try image(), lease: retry))
        state.discard()
        XCTAssertNil(state.attachment)
        XCTAssertNotNil(state.target)
    }

    func testClaudeImageBlockPreservesPromptAndDoesNotSerializeContext() throws {
        let attachment = try image()
        let prompt = "  číselný_path\n    x = 1"
        let message = AgentProtocol.claudePrompt(prompt, image: attachment)
        let content = message["message"]["content"].array
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"].string, prompt)
        XCTAssertEqual(content[1]["source"]["media_type"].string, "image/png")
        XCTAssertEqual(Data(base64Encoded: content[1]["source"]["data"].string!), Self.png)
        XCTAssertEqual(content[1]["context"], .null)
        XCTAssertEqual(AgentProtocol.claudePrompt(prompt)["message"]["content"].array.count, 1)
    }

    func testCodexImageIsDataURLAndOnlyIncludedInAttachedTurn() throws {
        let attached = AskRequest(text: "question", workingDirectory: "/tmp", image: try image())
        var conversation = CodexConversation(request: attached)
        let start: JSONValue = .object(["id": .number(3), "result": .object(["thread": .object(["id": .string("thread")])])])
        let input = try conversation.receive(start).outgoing[0]["params"]["input"].array
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[1]["type"].string, "image")
        XCTAssertEqual(input[1]["url"].string, "data:image/png;base64," + Self.png.base64EncodedString())
        var next = CodexConversation(request: AskRequest(text: "next", workingDirectory: "/tmp", session: AgentSession(provider: .codex, identifier: "thread", workingDirectory: "/tmp")))
        XCTAssertEqual(try next.receive(start).outgoing[0]["params"]["input"].array.count, 1)
    }
}
