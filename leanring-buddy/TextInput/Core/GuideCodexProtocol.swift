import Foundation

nonisolated public struct GuideCodexProtocol: Sendable {
    public private(set) var threadID: String?
    public private(set) var turnID: String?
    private var nextID = 1
    private var requests: [Int: String] = [:]
    private var disabledServers: [String: JSONValue] = [:]
    private var disabledSkills: [JSONValue] = []
    private var candidateThreadID: String?
    public var disabledSkillPaths: [String] { disabledSkills.compactMap { $0["path"].string } }
    private let directory: String
    private let contract: AgentContract
    public init(directory: String, contract: AgentContract = .guide) { self.directory = directory; self.contract = contract }

    public mutating func initialize() -> JSONValue {
        rpc("initialize", .object(["clientInfo": .object(["name": .string("clicky"), "version": .string("0.2.0")]),
                                   "capabilities": .object(["experimentalApi": .bool(false)])]))
    }

    /// Codex accepts effort per turn; the audited profile default stays `low`.
    public mutating func startTurn(input: [JSONValue], effort: AskEffort = .low, purpose: GuideRequestPurpose = .planning) throws -> JSONValue {
        guard let threadID else { throw AskError.incompleteTurn }
        turnID = nil
        return rpc("turn/start", .object(["threadId": .string(threadID), "input": .array(input),
                                          "model": .string(GuideAgentProfile.codexModel), "effort": .string(effort.rawValue),
                                          "outputSchema": GuideContract.responseSchema(for: purpose)]))
    }

    public mutating func receive(_ message: JSONValue) throws -> [JSONValue] {
        if message["error"] != .null { throw AskError.protocolFailure("Codex rejected Clicky's guide protocol. Check GPT-6 Luna access, CLI version and managed policy.") }
        if message["method"].string != nil, message["id"] != .null { return [deny(message)] }
        guard let id = message["id"].integer, let method = requests.removeValue(forKey: id) else { return [] }
        let result = message["result"]
        switch method {
        case "initialize":
            return [.object(["method": .string("initialized")]), rpc("account/read", .object([:]))]
        case "account/read":
            guard result["account"]["type"].string == "chatgpt" else {
                throw AskError.protocolFailure("Sign in to Clicky's isolated Codex profile using Sign in in Settings, then retry.")
            }
            return [rpc("config/read", .object(["cwd": .string(directory), "includeLayers": .bool(false)]))]
        case "config/read":
            return try receiveConfiguration(result)
        case "skills/list":
            return try receiveSkills(result)
        case "thread/start":
            guard result["instructionSources"] == .array([]), let id = result["thread"]["id"].string,
                  result["thread"]["ephemeral"].bool else {
                throw AskError.protocolFailure("Codex did not establish a clean in-memory thread.")
            }
            candidateThreadID = id
            return [rpc("experimentalFeature/list", .object(["threadId": .string(id), "limit": .number(200)]))]
        case "experimentalFeature/list":
            try auditRuntimeFeatures(result)
            guard let id = candidateThreadID else { throw AskError.incompleteTurn }
            candidateThreadID = nil; threadID = id
        case "turn/start":
            guard let id = result["turn"]["id"].string else { throw AskError.incompleteTurn }
            turnID = id
        default: break
        }
        return []
    }

    private mutating func receiveConfiguration(_ result: JSONValue) throws -> [JSONValue] {
        guard case .object = result["config"] else { throw AskError.protocolFailure("Codex did not report effective configuration.") }
        try audit(result["config"])
        if case .object(let servers) = result["config"]["mcp_servers"] {
            disabledServers = servers.mapValues { _ in .object(["enabled": .bool(false)]) }
        }
        return [rpc("skills/list", .object(["cwds": .array([.string(directory)]), "forceReload": .bool(true)]))]
    }

    private mutating func receiveSkills(_ result: JSONValue) throws -> [JSONValue] {
        guard case .array = result["data"] else { throw AskError.protocolFailure("Codex did not return skill diagnostics.") }
        for entry in result["data"].array {
            guard case .array = entry["skills"], case .array = entry["errors"] else {
                throw AskError.protocolFailure("Codex did not return complete skill source diagnostics.")
            }
            for skill in entry["skills"].array {
                guard let path = skill["path"].string else { throw AskError.protocolFailure("Codex returned an unreadable skill source.") }
                disabledSkills.append(.object(["path": .string(path), "enabled": .bool(false)]))
            }
            if !entry["errors"].array.isEmpty { throw AskError.protocolFailure("Codex could not audit its skill sources.") }
        }
        return [rpc("thread/start", threadParams())]
    }

    public func accepts(_ message: JSONValue) -> Bool {
        let params = message["params"]
        guard params["threadId"].string == threadID else { return false }
        let incoming = params["turnId"].string ?? params["turn"]["id"].string
        return incoming == turnID && turnID != nil
    }

    private mutating func rpc(_ method: String, _ params: JSONValue) -> JSONValue {
        let id = nextID; nextID += 1; requests[id] = method
        return AgentProtocol.rpc(identifier: id, method: method, params: params)
    }

    private func threadParams() -> JSONValue {
        .object(["cwd": .string(directory), "ephemeral": .bool(true), "sandbox": .string("read-only"),
                 "model": .string(GuideAgentProfile.codexModel),
                 "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
                 "baseInstructions": .string(contract.prompt),
                 "developerInstructions": .string("Only emit the Clicky presentation schema. No tools or desktop actions."),
                 "config": .object(["mcp_servers": .object(disabledServers), "skills": .object(["config": .array(disabledSkills)])])])
    }

    private func audit(_ config: JSONValue) throws {
        for (key, literal) in GuideAgentProfile.codexOverrides.sorted(by: { $0.key < $1.key }) {
            let expected = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
            let actual = key.split(separator: ".").reduce(config) { $0[String($1)] }
            guard actual == expected else {
                // The path is an owned constant, never an arbitrary provider setting or value.
                throw AskError.protocolFailure("Codex isolation audit failed (configuration_mismatch at $.\(key)). Select a supported CLI and clean profile, then Retry explicitly.")
            }
        }
    }

    private func auditRuntimeFeatures(_ result: JSONValue) throws {
        guard case .object(let fields) = result, case .array(let features) = fields["data"], fields["nextCursor"] == .null else {
            throw AskError.protocolFailure("Codex did not return complete runtime feature diagnostics.")
        }
        let expected = GuideAgentProfile.codexOverrides.filter { $0.key.hasPrefix("features.") }
        for (key, literal) in expected.sorted(by: { $0.key < $1.key }) {
            let name = String(key.dropFirst(9))
            let matching = features.filter { $0["name"].string == name }
            guard matching.count == 1, let feature = matching.first,
                  feature["stage"].string != nil, case .bool(let enabled) = feature["enabled"] else {
                throw AskError.protocolFailure("Codex runtime isolation audit failed (missing_feature at $.\(key)). Select a supported CLI, then Retry explicitly.")
            }
            // Audit only owned restrictions; unrelated UI feature defaults are not capability grants.
            if enabled != (literal == "true") {
                throw AskError.protocolFailure("Codex runtime isolation audit failed (feature_mismatch at $.\(key)). This CLI does not honor Clicky's capability restrictions. Use Local preview or another supported backend.")
            }
        }
    }

    private func deny(_ message: JSONValue) -> JSONValue {
        let method = message["method"].string ?? ""
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            return .object(["id": message["id"], "result": .object(["decision": .string("decline")])])
        }
        return .object(["id": message["id"], "error": .object(["code": .number(-32601), "message": .string("Clicky guide tools are unavailable.")])])
    }
}
