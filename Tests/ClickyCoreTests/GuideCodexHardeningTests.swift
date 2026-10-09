import XCTest
@testable import ClickyCore

final class GuideCodexHardeningTests: XCTestCase {
    private func reply(_ request: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["id": request["id"], "result": result])
    }

    private func configurationRequest(_ protocolState: inout GuideCodexProtocol) throws -> JSONValue {
        let initialize = protocolState.initialize()
        let account = try protocolState.receive(reply(initialize, .object([:]))).last!
        return try protocolState.receive(reply(account, .object(["account": .object(["type": .string("chatgpt")])]))).first!
    }

    private func setting(_ path: ArraySlice<String>, value: JSONValue, into object: JSONValue) -> JSONValue {
        guard let key = path.first else { return value }
        var fields: [String: JSONValue]
        if case .object(let existing) = object { fields = existing } else { fields = [:] }
        fields[key] = setting(path.dropFirst(), value: value, into: fields[key] ?? .null)
        return .object(fields)
    }

    private func cleanConfiguration() throws -> JSONValue {
        var result: JSONValue = .object([:])
        for (key, literal) in GuideAgentProfile.codexOverrides {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
            result = setting(key.split(separator: ".").map(String.init)[...], value: value, into: result)
        }
        return result
    }

    func testExactAuditedVersionsRejectPrefixesSuffixesAndDrift() {
        for version in ["0.160.1"] {
            XCTAssertTrue(GuideAgentProfile.supports("codex-cli " + version + "\n", provider: .codex))
        }
        for output in ["codex-cli 0.162.0", "codex-cli 0.162.1", "codex-cli 0.162.0-dev", "codex-cli 0.162.00",
                       "codex-cli 0.163.0", "codex-cli 0.162.0 extra", "0.162.0"] {
            XCTAssertFalse(GuideAgentProfile.supports(output, provider: .codex))
        }
    }

    func testUnauditedModelToolsGiveActionableVersionFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-unsupported-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try GuideAgentProfile(provider: .codex, root: root, taskID: UUID())
        let executable = root.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.162.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try profile.validate(executable: executable)) {
            XCTAssertTrue($0.localizedDescription.contains("cannot establish no-tools isolation for Codex 0.162.0"))
            XCTAssertTrue($0.localizedDescription.contains("Use Claude or Local preview"))
            XCTAssertFalse($0.localizedDescription.contains("0.160.1"))
        }
        XCTAssertFalse(profile.arguments.contains("include_apply_patch_tool=false"))
    }

    func testEveryOverrideMustMatchBeforeSkillOrThreadDiscovery() throws {
        let clean = try cleanConfiguration()
        for key in GuideAgentProfile.codexOverrides.keys.sorted() {
            var state = GuideCodexProtocol(directory: "/fixture")
            let request = try configurationRequest(&state)
            let changed = setting(key.split(separator: ".").map(String.init)[...], value: .null, into: clean)
            XCTAssertThrowsError(try state.receive(reply(request, .object(["config": changed])))) {
                XCTAssertTrue($0.localizedDescription.contains("configuration_mismatch at $." + key))
            }
            XCTAssertNil(state.threadID)
        }
    }

    func testCleanDiagnosticsDisableEveryDiscoveredSkillAndMCPServer() throws {
        var state = GuideCodexProtocol(directory: "/fixture")
        let request = try configurationRequest(&state)
        var config = try cleanConfiguration()
        config = setting(["mcp_servers"][...], value: .object(["inherited": .object(["command": .string("forbidden")])]), into: config)
        let skills = try state.receive(reply(request, .object(["config": config]))).first!
        let thread = try state.receive(reply(skills, .object(["data": .array([
            .object(["skills": .array([.object(["path": .string("/fixture/skill")])]), "errors": .array([])]),
        ])]))).first!
        XCTAssertEqual(thread["params"]["config"]["mcp_servers"]["inherited"]["enabled"], .bool(false))
        XCTAssertEqual(thread["params"]["config"]["skills"]["config"].array.first?["enabled"], .bool(false))
        XCTAssertEqual(thread["params"]["ephemeral"], .bool(true))
        XCTAssertThrowsError(try state.receive(reply(thread, .object([
            "thread": .object(["id": .string("fixture"), "ephemeral": .bool(true)]),
            "instructionSources": .array([.object([:])]),
        ]))))
        XCTAssertNil(state.threadID)
    }

    func testMissingSkillDiagnosticsFailClosed() throws {
        for entry in [JSONValue.object([:]), .object(["skills": .array([])]),
                      .object(["skills": .array([]), "errors": .array([.object([:])])])] {
            var state = GuideCodexProtocol(directory: "/fixture")
            let request = try configurationRequest(&state)
            let skills = try state.receive(reply(request, .object(["config": cleanConfiguration()]))).first!
            XCTAssertThrowsError(try state.receive(reply(skills, .object(["data": .array([entry])]))))
            XCTAssertNil(state.threadID)
        }
    }

    func testRuntimeContradictionRejectsThreadBeforeAnyTurn() throws {
        for mode in ["clean", "contradiction", "missing", "incomplete"] {
            var state = GuideCodexProtocol(directory: "/fixture")
            let config = try configurationRequest(&state)
            let skills = try state.receive(reply(config, .object(["config": cleanConfiguration()]))).first!
            let thread = try state.receive(reply(skills, .object(["data": .array([])]))).first!
            let runtime = try state.receive(reply(thread, .object([
                "thread": .object(["id": .string("fixture"), "ephemeral": .bool(true)]), "instructionSources": .array([]),
            ]))).first!
            XCTAssertNil(state.threadID)
            XCTAssertThrowsError(try state.startTurn(input: []))
            var features = GuideAgentProfile.codexOverrides.filter { $0.key.hasPrefix("features.") }.map { key, value in
                JSONValue.object(["name": .string(String(key.dropFirst(9))), "stage": .string("stable"), "enabled": .bool(value == "true")])
            }
            if mode == "contradiction", let index = features.firstIndex(where: { $0["name"].string == "unified_exec" }) {
                features[index] = .object(["name": .string("unified_exec"), "stage": .string("stable"), "enabled": .bool(true)])
            }
            if mode == "missing" { features = [] }
            let result: JSONValue = .object(["data": .array(features), "nextCursor": mode == "incomplete" ? .string("cursor") : .null])
            if mode == "clean" {
                XCTAssertNoThrow(try state.receive(reply(runtime, result)))
                XCTAssertEqual(state.threadID, "fixture")
            } else {
                XCTAssertThrowsError(try state.receive(reply(runtime, result)))
                XCTAssertNil(state.threadID)
            }
        }
    }
}
