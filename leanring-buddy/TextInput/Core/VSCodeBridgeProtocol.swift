import Foundation

/// Editor/terminal snapshot returned by the VS Code bridge `state` method. Offsets are UTF-16 code units.
nonisolated public struct VSCodeBridgeState: Codable, Equatable, Sendable {
    public struct Selection: Codable, Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let active: Int
        public init(start: Int, end: Int, active: Int) { self.start = start; self.end = end; self.active = active }
    }

    public struct Editor: Codable, Equatable, Sendable {
        public let uri: String
        public let version: Int
        public let eol: String
        public let languageId: String
        public let selections: [Selection]
        public let isUntitled: Bool
        public init(uri: String, version: Int, eol: String, languageId: String, selections: [Selection], isUntitled: Bool) {
            self.uri = uri; self.version = version; self.eol = eol; self.languageId = languageId
            self.selections = selections; self.isUntitled = isUntitled
        }
    }

    public struct Terminal: Codable, Equatable, Sendable {
        public let id: Int?
        public let name: String
        public let shellIntegration: Bool
        public let busy: Bool
        public let shell: String?
        /// `ready`, `busy` or `unknown`; readiness is unknown until the bridge observed a shell-integration
        /// event for this terminal. Absent (older bridge) means unknown.
        public let readiness: String?
        public init(id: Int?, name: String, shellIntegration: Bool, busy: Bool, shell: String?, readiness: String? = nil) {
            self.id = id; self.name = name; self.shellIntegration = shellIntegration; self.busy = busy; self.shell = shell
            self.readiness = readiness
        }
        public var isReady: Bool { shellIntegration && !busy && readiness == "ready" }
    }

    public let focused: Bool
    /// Epoch milliseconds of the window's latest focus gain; 0 if it never had focus.
    public let focusedAt: Double
    public let editor: Editor?
    public let terminal: Terminal?
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focused = try container.decode(Bool.self, forKey: .focused)
        focusedAt = try container.decodeIfPresent(Double.self, forKey: .focusedAt) ?? 0
        editor = try container.decodeIfPresent(Editor.self, forKey: .editor)
        terminal = try container.decodeIfPresent(Terminal.self, forKey: .terminal)
    }
    private enum CodingKeys: String, CodingKey { case focused, focusedAt, editor, terminal }

    public init(focused: Bool, focusedAt: Double = 0, editor: Editor?, terminal: Terminal?) {
        self.focused = focused; self.focusedAt = focusedAt; self.editor = editor; self.terminal = terminal
    }
}

nonisolated public struct VSCodeReplaceResult: Codable, Equatable, Sendable {
    public let applied: Bool
    public let verified: Bool?
    public let normalizedLineEndings: Bool?
    public let version: Int?
    public let start: Int?
    public let end: Int?
    public init(applied: Bool, verified: Bool? = nil, normalizedLineEndings: Bool? = nil,
                version: Int? = nil, start: Int? = nil, end: Int? = nil) {
        self.applied = applied; self.verified = verified; self.normalizedLineEndings = normalizedLineEndings
        self.version = version; self.start = start; self.end = end
    }

    /// What the document holds after the edit: VS Code converts inserted line endings to a CRLF document's
    /// EOL (every LF, or existing CRLF, becomes CRLF), which the bridge reports as `normalizedLineEndings`.
    public func insertedText(requested text: String) -> String {
        guard normalizedLineEndings == true else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }
}

nonisolated public enum VSCodeBridgeError: Error, Equatable, Sendable {
    /// Failure before the request was written (no token, no socket, connect or send failure): safe to retry.
    case unavailable
    /// Failure after the request was written (no, closed, oversized or invalid reply): the effect is unknown.
    case timedOut
    case protocolViolation
    /// The extension's error code, for example `stale`, `busy` or `unauthorized`.
    case remote(String)
}

nonisolated public enum VSCodeBridgeWire {
    public static let version = 1

    /// One JSON line (with trailing newline) holding the token. Callers must never log it.
    public static func encodeRequest(id: String, token: String, method: String, params: [String: JSONValue]) throws -> Data {
        let envelope: JSONValue = .object([
            "v": .number(Double(version)), "id": .string(id), "token": .string(token),
            "method": .string(method), "params": .object(params),
        ])
        var data = try JSONEncoder().encode(envelope)
        data.append(10)
        return data
    }

    /// Checks version and id, returns the result, or throws `.remote(code)` for an error response.
    public static func decodeResponse(_ line: Data, expectingID id: String) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object = value, value["v"].integer == version,
              value["id"].string == id else { throw VSCodeBridgeError.protocolViolation }
        guard case .bool(let ok) = value["ok"] else { throw VSCodeBridgeError.protocolViolation }
        if ok { return value["result"] }
        throw VSCodeBridgeError.remote(value["error"].string ?? "unknown")
    }

    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw VSCodeBridgeError.protocolViolation }
    }
}
