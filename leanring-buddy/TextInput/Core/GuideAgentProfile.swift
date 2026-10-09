import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

nonisolated public struct GuideAgentProfile: Sendable {
    public static let claudeModel = "claude-haiku-5-5"
    public static let codexModel = "gpt-6-luna"
    public static let reasoningEffort = "low"
    static let claudeVersions = ["2.1.294", "2.1.295"]
    static let codexVersions = ["0.160.1"]
    public let provider: AgentProvider
    public let workingDirectory: URL
    public let profileDirectory: URL
    public let promptFile: URL
    public let settingsFile: URL
    public let environment: [String: String]
    /// Claude fixes effort when the process starts, so it applies to the whole task session.
    public let effort: AskEffort

    public init(provider: AgentProvider, root: URL, taskID: UUID, effort: AskEffort = .low) throws {
        self.provider = provider; self.effort = effort
        profileDirectory = root.appendingPathComponent(provider.rawValue, isDirectory: true)
        workingDirectory = root.appendingPathComponent("tasks/" + taskID.uuidString, isDirectory: true)
        promptFile = workingDirectory.appendingPathComponent("guide-prompt.txt")
        settingsFile = workingDirectory.appendingPathComponent("settings.json")
        for directory in [profileDirectory, workingDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        try Data(GuideContract.prompt.utf8).write(to: promptFile, options: .atomic)
        try Data("{\"autoMemoryEnabled\":false,\"disableAllHooks\":true,\"claudeMdExcludes\":[\"**\"]}".utf8)
            .write(to: settingsFile, options: .atomic)
        var child = ProcessInfo.processInfo.environment
        // Provider overrides from the parent must not redirect subscription inference or inject context.
        for key in child.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_")
            || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("OPENAI_") { child.removeValue(forKey: key) }
        if provider == .codex { child["CODEX_HOME"] = profileDirectory.path }
        environment = child
    }

    public var arguments: [String] {
        if provider == .claude {
            let schema = String(data: try! JSONEncoder().encode(GuideContract.responseSchema), encoding: .utf8)!
            return ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--model", Self.claudeModel, "--effort", effort.rawValue,
                    "--safe-mode", "--setting-sources", "", "--settings", settingsFile.path,
                    "--system-prompt-file", promptFile.path, "--tools", "", "--strict-mcp-config",
                    "--disable-slash-commands", "--no-session-persistence", "--debug-file", "/dev/null", "--json-schema", schema]
        }
        return ["app-server", "--listen", "stdio://", "--strict-config"] + Self.codexOverrides
            .sorted(by: { $0.key < $1.key }).flatMap { ["-c", $0.key + "=" + $0.value] }
    }

    public static let codexOverrides: [String: String] = [
        "model": "\"gpt-6-luna\"", "model_reasoning_effort": "\"low\"",
        "project_doc_max_bytes": "0", "project_doc_fallback_filenames": "[]", "web_search": "\"disabled\"",
        "sandbox_mode": "\"read-only\"", "approvals_reviewer": "\"user\"",
        "features.apps": "false", "features.plugins": "false", "features.hooks": "false",
        "features.multi_agent": "false", "features.multi_agent_v2": "false",
        "features.shell_tool": "false", "features.unified_exec": "false", "features.shell_snapshot": "false",
        "features.skill_search": "false", "features.skill_mcp_dependency_install": "false",
        "features.skip_host_skill_discovery": "true", "features.image_generation": "false",
        "features.in_app_browser": "false", "features.in_app_local_automation": "false",
        "features.view_image": "false", "features.browser_use": "false", "features.browser_use_external": "false",
        "features.browser_use_full_cdp_access": "false", "features.computer_use": "false",
        "features.code_mode": "false", "features.code_mode_host": "false", "features.remote_plugin": "false",
        "features.workspace_dependencies": "false", "features.goals": "false", "features.sleep_tool": "false",
        "features.context_management": "false", "features.tool_suggest": "false",
        "memories.use_memories": "false", "memories.generate_memories": "false",
        "features.memories": "false", "analytics.enabled": "false", "feedback.enabled": "false",
    ]

    public func validate(executable: URL) throws {
        let probe = Process(); let pipe = Pipe()
        probe.executableURL = executable; probe.arguments = ["--version"]
        probe.environment = environment; probe.currentDirectoryURL = workingDirectory
        probe.standardOutput = pipe; probe.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        probe.terminationHandler = { _ in completed.signal() }
        try probe.run()
        guard completed.wait(timeout: .now() + 5) == .success else {
            probe.terminate()
            if completed.wait(timeout: .now() + 1) != .success, probe.isRunning {
                kill(probe.processIdentifier, SIGKILL)
            }
            throw AskError.protocolFailure("Agent version check timed out. Select the installed official CLI executable.")
        }
        let data = try pipe.fileHandleForReading.read(upToCount: 4096) ?? Data()
        let version = String(decoding: data, as: UTF8.self)
        guard probe.terminationStatus == 0, Self.supports(version, provider: provider) else {
            if provider == .codex, Self.reportedVersion(version, provider: provider) == "0.162.0" {
                throw AskError.protocolFailure("Clicky cannot establish no-tools isolation for Codex 0.162.0 with GPT-6 Luna. Model-required code and patch tools cannot be excluded by the audited settings. Use Claude or Local preview.")
            }
            let supported = provider == .claude ? "Claude " + Self.claudeVersions.joined(separator: ", ")
                : "Codex " + Self.codexVersions.joined(separator: ", ")
            let detected = Self.reportedVersion(version, provider: provider).map { "Installed agent \($0)" } ?? "This agent version"
            throw AskError.protocolFailure("\(detected) has not passed Clicky's isolation checks. Use \(supported), or Local preview. New CLI versions require an isolation audit; Retry never changes this gate.")
        }
        if provider == .claude { try Self.auditClaudePolicy() }
    }

    static func supports(_ output: String, provider: AgentProvider) -> Bool {
        let words = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if provider == .claude { return words.first.map(claudeVersions.contains) ?? false }
        return provider == .codex && words.count == 2 && words[0] == "codex-cli" && codexVersions.contains(words[1])
    }

    private static func reportedVersion(_ output: String, provider: AgentProvider) -> String? {
        let words = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let candidate = provider == .claude ? words.first : (words.count == 2 && words[0] == "codex-cli" ? words[1] : nil)
        guard let candidate, candidate.count <= 32, candidate.split(separator: ".").count == 3,
              candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) else { return nil }
        return candidate
    }

    public func removeTaskFiles() { try? FileManager.default.removeItem(at: workingDirectory) }
    public func disableSkills(_ paths: [String]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let entries = try paths.sorted().map { path in
            let quoted = String(decoding: try encoder.encode(path), as: UTF8.self)
            return "[[skills.config]]\npath = " + quoted + "\nenabled = false\n"
        }.joined(separator: "\n")
        try Data(entries.utf8).write(to: profileDirectory.appendingPathComponent("config.toml"), options: .atomic)
    }

    private static func auditClaudePolicy() throws {
        let base = "/Library/Application Support/ClaudeCode/"
        let dropIns = (try? FileManager.default.contentsOfDirectory(atPath: base + "managed-settings.d")) ?? []
        let paths = [base + "managed-settings.json", NSHomeDirectory() + "/.claude/remote-settings.json",
                     NSHomeDirectory() + "/.claude/managed-settings.json"]
            + dropIns.filter { $0.hasSuffix(".json") }.map { base + "managed-settings.d/" + $0 }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            try GuideClaudePolicy.auditManaged(value)
        }
        for path in ["/Library/Managed Preferences/com.anthropic.claudecode.plist", "/Library/Preferences/com.anthropic.claudecode.plist"]
            where FileManager.default.fileExists(atPath: path) {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil)
            let json = try JSONSerialization.data(withJSONObject: plist)
            try GuideClaudePolicy.auditManaged(JSONDecoder().decode(JSONValue.self, from: json))
        }
    }
}
