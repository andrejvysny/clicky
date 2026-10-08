import XCTest
@testable import ClickyCore

final class GuideAgentTests: XCTestCase {
    private func make(_ provider: AgentProvider, timeout: UInt64 = 2_000_000_000) throws -> (GuideAgentSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-guide-test-" + UUID().uuidString)
        let profile = try GuideAgentProfile(provider: provider, root: root, taskID: UUID())
        let fixture = Bundle.module.url(forResource: "guide-agent", withExtension: "py", subdirectory: "Fixtures")!
        let executable = root.appendingPathComponent("fixture")
        let script = "#!/bin/sh\nexec /usr/bin/env python3 '" + fixture.path + "' \"$@\"\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (GuideAgentSession(profile: profile, executable: executable, validateProfile: false, timeoutNanoseconds: timeout), root)
    }
    func testPersistentTurnsBothProvidersAndNoDiskTranscript() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let (agent, root) = try make(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = try await agent.turn(GuideAgentTurn(message: "Unicode Ž 🤖"))
            let second = try await agent.turn(GuideAgentTurn(message: "second"))
            XCTAssertEqual(first.text, "turn 1: Unicode Ž 🤖")
            XCTAssertEqual(second.text, "turn 2: second")
            let id = await agent.identifier(); XCTAssertNotNil(id)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            XCTAssertFalse(files.contains { $0.pathExtension == "jsonl" })
            await agent.close()
        }
    }
    func testInvalidOutputClosesSessionAndNeverRetries() async throws {
        let (agent, root) = try make(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await agent.turn(GuideAgentTurn(message: "bad-schema")); XCTFail("Invalid output accepted") } catch {}
        do { _ = try await agent.turn(GuideAgentTurn(message: "retry")); XCTFail("Closed session reused") } catch {}
        await agent.close()
    }
    func testTurnTimeoutDoesNotAffectIdleWaiting() async throws {
        let (agent, root) = try make(.claude, timeout: 1_000_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await agent.turn(GuideAgentTurn(message: "first"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let second = try await agent.turn(GuideAgentTurn(message: "second"))
        XCTAssertEqual(second.text, "turn 2: second")
        do { _ = try await agent.turn(GuideAgentTurn(message: "hang")); XCTFail("Timeout missing") } catch {}
        await agent.close()
    }
    func testCancelBlockedTurnAndDuplicateSubmission() async throws {
        let (agent, root) = try make(.codex)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await agent.turn(GuideAgentTurn(message: "hang")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        do { _ = try await agent.turn(GuideAgentTurn(message: "duplicate")); XCTFail("Duplicate accepted") }
        catch { XCTAssertEqual(error as? AskError, .busy) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Canceled turn completed") } catch {}
        await agent.close()
    }
    func testCrashRequiresExplicitFreshSessionWithoutReplay() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let (agent, root) = try make(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await agent.turn(GuideAgentTurn(message: "first"))
            do { _ = try await agent.turn(GuideAgentTurn(message: "exit")); XCTFail("Crash accepted") } catch {}
            do { _ = try await agent.turn(GuideAgentTurn(message: "replay")); XCTFail("Lost process silently restarted") } catch {}
            await agent.close()
            let (fresh, freshRoot) = try make(provider)
            defer { try? FileManager.default.removeItem(at: freshRoot) }
            let recovered = try await fresh.turn(GuideAgentTurn(message: "Explicit recovery with current task context", purpose: .recovery))
            XCTAssertEqual(recovered.text, "turn 1: Explicit recovery with current task context")
            await fresh.close()
        }
    }
    func testStaleProviderResultsCannotCompleteAnotherTurn() async throws {
        for provider in [AgentProvider.claude, .codex] {
            let (agent, root) = try make(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await agent.turn(GuideAgentTurn(message: "first"))
            let result = try await agent.turn(GuideAgentTurn(message: "stale-reply"))
            XCTAssertEqual(result.text, "turn 2: stale-reply")
            await agent.close()
        }
    }
}
