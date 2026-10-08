import Foundation

nonisolated public struct CodexConversation {
    public private(set) var threadIdentifier: String?
    public private(set) var turnIdentifier: String?
    public private(set) var completed = false
    private let request: AskRequest
    private var receivedText = false

    public init(request: AskRequest) { self.request = request }

    public var initialize: JSONValue {
        AgentProtocol.rpc(identifier: 1, method: "initialize", params: .object([
            "clientInfo": .object(["name": .string("clicky"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(false)]),
        ]))
    }

    public mutating func receive(_ message: JSONValue) throws -> (outgoing: [JSONValue], events: [AgentEvent]) {
        if message["error"] != .null {
            throw AskError.protocolFailure("Codex rejected the request. Check its version, sign-in, and project configuration in your terminal.")
        }
        if let method = message["method"].string, message["id"] != .null {
            // The first release is conversational: tool execution never receives hidden approval.
            let result: JSONValue
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                result = .object(["decision": .string("decline")])
            case "execCommandApproval", "applyPatchApproval":
                result = .object(["decision": .string("denied")])
            default:
                return ([.object(["id": message["id"], "error": .object(["code": .number(-32601), "message": .string("This Clicky text client does not support this request.")])])], [.status("An agent tool request is unavailable in text-only mode.")])
            }
            return ([.object(["id": message["id"], "result": result])], [.status("An agent action was declined. Use the official CLI for actions requiring approval.")])
        }
        switch message["id"].integer {
        case 1:
            return ([.object(["method": .string("initialized")]), AgentProtocol.rpc(identifier: 2, method: "account/read", params: .object([:]))], [])
        case 2:
            guard message["result"]["account"] != .null else { throw AskError.authenticationRequired }
            return ([AgentProtocol.rpc(identifier: 5, method: "config/read", params: .object(["includeLayers": .bool(false), "cwd": .string(request.workingDirectory)]))], [])
        case 5:
            // Per-server disable is the only override that survives Codex's table merge; fail closed if config is unreadable.
            guard case .object(let config) = message["result"]["config"] else { throw AskError.protocolFailure("Codex did not report its configuration, so Clicky could not disable its tools.") }
            var params: [String: JSONValue] = [
                "cwd": .string(request.workingDirectory), "sandbox": .string("read-only"),
                "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
            ]
            if case .object(let servers)? = config["mcp_servers"], !servers.isEmpty {
                params["config"] = .object(["mcp_servers": .object(Dictionary(uniqueKeysWithValues: servers.keys.sorted().map { ($0, JSONValue.object(["enabled": .bool(false)])) }))])
            }
            let resume = request.session?.provider == .codex
            if resume, let session = request.session { params["threadId"] = .string(session.identifier) }
            return ([AgentProtocol.rpc(identifier: 3, method: resume ? "thread/resume" : "thread/start", params: .object(params))], [])
        case 3:
            guard let identifier = message["result"]["thread"]["id"].string else { throw AskError.protocolFailure("Codex did not return a thread ID.") }
            threadIdentifier = identifier
            let prompt: JSONValue = .object(["type": .string("text"), "text": .string(request.text)])
            var input = [prompt]
            if let image = request.image {
                input.append(.object(["type": .string("image"), "url": .string(image.dataURL)]))
                if image.capturedRegion != nil {
                    input.append(.object(["type": .string("text"), "text": .string(ScreenPointing.instruction(imageWidth: image.pixelWidth, imageHeight: image.pixelHeight))]))
                }
            }
            return ([AgentProtocol.rpc(identifier: 4, method: "turn/start", params: .object(["threadId": .string(identifier), "input": .array(input)]))], [.session(AgentSession(provider: .codex, identifier: identifier, workingDirectory: request.workingDirectory))])
        case 4:
            guard let identifier = message["result"]["turn"]["id"].string else { throw AskError.protocolFailure("Codex did not return a turn ID.") }
            turnIdentifier = identifier
        default: break
        }
        let params = message["params"]
        if let incomingThread = params["threadId"].string, incomingThread != threadIdentifier { return ([], []) }
        if let incomingTurn = params["turnId"].string, let turnIdentifier, incomingTurn != turnIdentifier { return ([], []) }
        switch message["method"].string {
        case "item/agentMessage/delta":
            if let delta = params["delta"].string { receivedText = true; return ([], [.textDelta(delta)]) }
        case "item/completed":
            let item = params["item"]
            if !receivedText, item["type"].string == "agentMessage", let text = item["text"].string { return ([], [.textDelta(text)]) }
        case "turn/completed":
            if let completedTurn = params["turn"]["id"].string, let turnIdentifier, completedTurn != turnIdentifier { return ([], []) }
            if params["turn"]["status"].string == "failed" { throw AskError.protocolFailure("Codex could not complete this turn. Check the official CLI for details.") }
            if params["turn"]["status"].string == "interrupted" { throw CancellationError() }
            completed = true
            return ([], [.completed])
        default: break
        }
        return ([], [])
    }
}
