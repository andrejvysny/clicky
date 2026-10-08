import Foundation

nonisolated public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { if case .object(let value) = self { return value[key] ?? .null }; return .null }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    public var bool: Bool { if case .bool(let value) = self { return value }; return false }
    public var integer: Int? { if case .number(let value) = self { return Int(exactly: value) }; return nil }
}

nonisolated public struct JSONLineFramer {
    private var buffer = Data()
    public let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 4 * 1024 * 1024) { self.maximumLineBytes = maximumLineBytes }

    public mutating func append(_ chunk: Data) throws -> [JSONValue] {
        buffer.append(chunk)
        var messages: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard line.count <= maximumLineBytes else { throw AskError.protocolFailure("Agent message exceeds the protocol limit.") }
            if !line.isEmpty { messages.append(try JSONDecoder().decode(JSONValue.self, from: Data(line))) }
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= maximumLineBytes else { throw AskError.protocolFailure("Agent message exceeds the protocol limit.") }
        return messages
    }

    public mutating func finish() throws -> [JSONValue] {
        guard !buffer.isEmpty else { return [] }
        return try append(Data([10]))
    }
}

nonisolated public enum AgentProtocol {
    public static func claudeArguments(session: AgentSession?) -> [String] {
        // Text-only turns expose no execution/edit tools and keep normal provider authentication.
        // --strict-mcp-config without --mcp-config: user MCP servers/connectors could otherwise act outside this text client.
        var arguments = ["--print", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--include-partial-messages", "--tools", "", "--strict-mcp-config"]
        if let session { arguments += ["--resume", session.identifier] }
        return arguments
    }

    // Apps/plugins off and approvals routed to the client (which declines) so Codex connectors cannot act outside this text client.
    public static func codexArguments() -> [String] {
        ["app-server", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "approvals_reviewer=\"user\"", "--listen", "stdio://"]
    }

    public static func claudePrompt(_ text: String, image: PNGImageAttachment? = nil) -> JSONValue {
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        if let image {
            content.append(.object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string(image.mediaType), "data": .string(image.data.base64EncodedString()),
            ])]))
        }
        return .object(["type": .string("user"), "session_id": .string(""), "parent_tool_use_id": .null, "message": .object(["role": .string("user"), "content": .array(content)])])
    }

    public static func claudeEvents(_ message: JSONValue, directory: String, streamedText: Bool) throws -> [AgentEvent] {
        switch message["type"].string {
        case "system":
            if message["subtype"].string == "init", let identifier = message["session_id"].string {
                return [.session(AgentSession(provider: .claude, identifier: identifier, workingDirectory: directory))]
            }
        case "stream_event":
            let delta = message["event"]["delta"]
            if delta["type"].string == "text_delta", let text = delta["text"].string { return [.textDelta(text)] }
        case "result":
            if message["is_error"].bool { throw AskError.protocolFailure("Claude could not complete this turn. Check its sign-in, limits, and permissions in your terminal.") }
            var events: [AgentEvent] = []
            if !streamedText, let text = message["result"].string { events.append(.textDelta(text)) }
            if let identifier = message["session_id"].string { events.append(.session(AgentSession(provider: .claude, identifier: identifier, workingDirectory: directory))) }
            events.append(.completed)
            return events
        default: break
        }
        return []
    }

    public static func rpc(identifier: Int, method: String, params: JSONValue) -> JSONValue {
        .object(["id": .number(Double(identifier)), "method": .string(method), "params": params])
    }
}
