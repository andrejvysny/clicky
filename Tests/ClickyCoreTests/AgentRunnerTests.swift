import XCTest
@testable import ClickyCore

final class AgentRunnerTests: XCTestCase {
    private func fixture(name: String = "agent") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(name)
        let source = Bundle.module.url(forResource: "fake-agent", withExtension: "py", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    func testRealPipesForBothProvidersAndUnicode() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let executable = try fixture()
            let runner = ManagedAgentRunner()
            let text = "  číslo 👋\n    keep indentation"
            var response = ""
            var session: AgentSession?
            var completed = false
            for try await event in runner.stream(provider: provider, executable: executable, request: AskRequest(text: text, workingDirectory: executable.deletingLastPathComponent().path)) {
                switch event {
                case .textDelta(let delta): response += delta
                case .session(let value): session = value
                case .completed: completed = true
                default: break
                }
            }
            XCTAssertEqual(response, text)
            XCTAssertEqual(session?.provider, provider)
            XCTAssertTrue(completed)
        }
    }

    func testFailureAndMissingCompletionAreNotSuccess() async throws {
        let executable = try fixture()
        for text in ["incomplete", "fail"] {
            do {
                for try await _ in ManagedAgentRunner().stream(provider: .claude, executable: executable, request: AskRequest(text: text, workingDirectory: "/tmp")) {}
                XCTFail("Failed fixture must throw")
            } catch { XCTAssertTrue(error is AskError) }
        }
    }

    func testImageStdinTransportForBothProvidersAndNoNextTurnLeak() async throws {
        let executable = try fixture()
        for provider in [AgentProvider.claude, .codex] {
            let runner = ManagedAgentRunner()
            let image = try PNGImageAttachment(data: AttachmentTests.png)
            for attached in [true, false] {
                var response = ""
                let request = AskRequest(text: "attachment-test", workingDirectory: "/tmp", image: attached ? image : nil)
                for try await event in runner.stream(provider: provider, executable: executable, request: request) {
                    if case .textDelta(let delta) = event { response += delta }
                }
                XCTAssertEqual(response, attached ? "image received: \(AttachmentTests.png.count) bytes" : "no image")
            }
        }
    }

    func testCodexAuthenticationFailureIsActionable() async throws {
        let executable = try fixture(name: "unauth-agent")
        do {
            for try await _ in ManagedAgentRunner().stream(provider: .codex, executable: executable, request: AskRequest(text: "q", workingDirectory: "/tmp")) {}
            XCTFail("Missing authentication must fail")
        } catch { XCTAssertEqual(error as? AskError, .authenticationRequired) }
    }

    func testCancelStopsBlockedProcessAndAllowsAnotherTurn() async throws {
        let executable = try fixture()
        let runner = ManagedAgentRunner()
        let task = Task {
            do {
                for try await _ in runner.stream(provider: .claude, executable: executable, request: AskRequest(text: "hang", workingDirectory: "/tmp")) {}
            } catch {}
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        runner.cancel()
        await task.value
        var text = ""
        for try await event in runner.stream(provider: .claude, executable: executable, request: AskRequest(text: "next", workingDirectory: "/tmp")) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "next")
    }
}
