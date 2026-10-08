import XCTest
@testable import ClickyCore

final class ProtocolTests: XCTestCase {
    func testFramingSplitUnicodeAndFinalLine() throws {
        var framer = JSONLineFramer()
        let data = Data("{\"text\":\"číslo 👋\"}\n{\"id\":2}".utf8)
        var messages: [JSONValue] = []
        for byte in data { messages += try framer.append(Data([byte])) }
        messages += try framer.finish()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["text"].string, "číslo 👋")
        XCTAssertEqual(messages[1]["id"].integer, 2)
    }

    func testFramingRejectsOversizedAndMalformedMessages() {
        var framer = JSONLineFramer(maximumLineBytes: 8)
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: 9)))
        var malformed = JSONLineFramer()
        XCTAssertThrowsError(try malformed.append(Data("invalid\n".utf8)))
    }

    func testClaudeArgumentsKeepPermissionsAndPromptOffCommandLine() {
        let session = AgentSession(provider: .claude, identifier: "saved", workingDirectory: "/tmp")
        let arguments = AgentProtocol.claudeArguments(session: session)
        XCTAssertTrue(arguments.contains("--resume"))
        XCTAssertTrue(arguments.contains("saved"))
        XCTAssertFalse(arguments.contains("bypassPermissions"))
        XCTAssertFalse(arguments.contains("--bare"))
        XCTAssertEqual(arguments.suffix(2), ["--resume", "saved"])
    }

    func testClaudeFinalFallbackAvoidsDuplicateStreamingText() throws {
        let message: JSONValue = .object(["type": .string("result"), "result": .string("answer"), "is_error": .bool(false)])
        XCTAssertEqual(try AgentProtocol.claudeEvents(message, directory: "/tmp", streamedText: false), [.textDelta("answer"), .completed])
        XCTAssertEqual(try AgentProtocol.claudeEvents(message, directory: "/tmp", streamedText: true), [.completed])
    }

    func testCodexHandshakeResumeAndScopedEvents() throws {
        let request = AskRequest(text: "question", workingDirectory: "/tmp", session: AgentSession(provider: .codex, identifier: "saved", workingDirectory: "/tmp"))
        var conversation = CodexConversation(request: request)
        let initialized = try conversation.receive(.object(["id": .number(1), "result": .object([:])]))
        XCTAssertEqual(initialized.outgoing.first?["method"].string, "initialized")
        let authenticated = try conversation.receive(.object(["id": .number(2), "result": .object(["account": .object(["type": .string("chatgpt")])])]))
        XCTAssertEqual(authenticated.outgoing[0]["method"].string, "thread/resume")
        XCTAssertEqual(authenticated.outgoing[0]["params"]["sandbox"].string, "read-only")
        let started = try conversation.receive(.object(["id": .number(3), "result": .object(["thread": .object(["id": .string("saved")])])]))
        XCTAssertEqual(started.outgoing[0]["method"].string, "turn/start")
        let unrelated: JSONValue = .object(["method": .string("item/agentMessage/delta"), "params": .object(["threadId": .string("other"), "delta": .string("wrong")])])
        XCTAssertTrue(try conversation.receive(unrelated).events.isEmpty)
    }

    func testCodexMissingAuthenticationAndApprovalDenial() throws {
        var conversation = CodexConversation(request: AskRequest(text: "q", workingDirectory: "/tmp"))
        XCTAssertThrowsError(try conversation.receive(.object(["id": .number(2), "result": .object(["account": .null])])) )
        let approval: JSONValue = .object(["id": .string("approval-1"), "method": .string("item/commandExecution/requestApproval")])
        let denied = try conversation.receive(approval)
        XCTAssertEqual(denied.outgoing[0]["id"].string, "approval-1")
        XCTAssertEqual(denied.outgoing[0]["result"]["decision"].string, "decline")
    }
}
