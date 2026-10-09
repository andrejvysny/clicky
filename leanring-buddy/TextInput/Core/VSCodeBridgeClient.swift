import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Client for the opt-in Clicky Bridge extension. One connection per request over a unix socket in a 0700
/// directory; the token file is read per call. Never logs text or the token.
nonisolated public struct VSCodeBridgeClient: Sendable {
    public static let maximumResponseBytes = 1_048_576
    public let directory: URL
    public let timeout: TimeInterval

    public init(directory: URL, timeout: TimeInterval = 0.4) {
        self.directory = directory; self.timeout = timeout
    }

    private var tokenURL: URL { directory.appendingPathComponent("token") }

    public func tokenExists() -> Bool { FileManager.default.fileExists(atPath: tokenURL.path) }

    /// Creates the directory (0700) and an atomically renamed 0600 token of 64 random hex characters.
    public static func createToken(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        let temporary = directory.appendingPathComponent(".token-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw VSCodeBridgeError.unavailable }
        let bytes = Array(token.utf8)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
        close(descriptor)
        guard written == bytes.count,
              rename(temporary.path, directory.appendingPathComponent("token").path) == 0 else {
            unlink(temporary.path)
            throw VSCodeBridgeError.unavailable
        }
    }

    public static func removeToken(directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("token"))
    }

    /// Sockets named `vscode-<digits>.sock`, sorted by name.
    public func sockets() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { Self.isSocketName($0) }.sorted().map { directory.appendingPathComponent($0) }
    }

    static func isSocketName(_ name: String) -> Bool {
        guard name.hasPrefix("vscode-"), name.hasSuffix(".sock") else { return false }
        let digits = name.dropFirst("vscode-".count).dropLast(".sock".count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func call(socket: URL, method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { throw VSCodeBridgeError.unavailable }
        let id = UUID().uuidString
        let request = try VSCodeBridgeWire.encodeRequest(id: id, token: token, method: method, params: params)
        let path = socket.path, seconds = timeout
        let line = try await Task.detached {
            try Self.exchange(path: path, request: request, timeout: seconds)
        }.value
        do { return try VSCodeBridgeWire.decodeResponse(line, expectingID: id) }
        catch VSCodeBridgeError.protocolViolation { throw VSCodeBridgeError.timedOut } // written, reply unusable
    }

    public func state(socket: URL) async throws -> VSCodeBridgeState {
        try VSCodeBridgeWire.decode(VSCodeBridgeState.self, from: try await call(socket: socket, method: "state", params: [:]))
    }

    public func readRange(socket: URL, uri: String, version: Int, range: UTF16Range) async throws -> String {
        let result = try await call(socket: socket, method: "readRange", params: [
            "uri": .string(uri), "version": .number(Double(version)),
            "start": .number(Double(range.location)), "end": .number(Double(range.end)),
        ])
        guard let text = result["text"].string else { throw VSCodeBridgeError.protocolViolation }
        return text
    }

    /// `requireSelection`: the bridge applies only while the active editor's single selection is exactly `range`
    /// (forward writes); a restore of Clicky's own inserted text passes false.
    public func replaceRange(socket: URL, uri: String, version: Int, range: UTF16Range,
                             text: String, expected: String, requireSelection: Bool = false) async throws -> VSCodeReplaceResult {
        let result = try await call(socket: socket, method: "replaceRange", params: [
            "uri": .string(uri), "version": .number(Double(version)),
            "start": .number(Double(range.location)), "end": .number(Double(range.end)),
            "text": .string(text), "expected": .string(expected), "requireSelection": .bool(requireSelection),
        ])
        return try VSCodeBridgeWire.decode(VSCodeReplaceResult.self, from: result)
    }

    public func insertTerminal(socket: URL, terminalID: Int, text: String) async throws {
        let result = try await call(socket: socket, method: "insertTerminal", params: [
            "terminalId": .number(Double(terminalID)), "text": .string(text),
        ])
        guard result["sent"].bool else { throw VSCodeBridgeError.protocolViolation }
    }

    /// The one focused window; if none is focused (Quick Ask may hold key focus), the window that gained
    /// focus most recently, only when strictly later than every other. Several focused or a tie gives nil.
    public func focusedWindow() async -> (socket: URL, state: VSCodeBridgeState)? {
        let all = await withTaskGroup(of: (URL, VSCodeBridgeState)?.self) { group in
            for socket in sockets() {
                group.addTask { (try? await state(socket: socket)).map { (socket, $0) } }
            }
            var states: [(URL, VSCodeBridgeState)] = []
            for await item in group { if let item { states.append(item) } }
            return states
        }
        let focused = all.filter { $0.1.focused }
        if focused.count > 1 { return nil }
        if let only = focused.first { return (socket: only.0, state: only.1) }
        let ranked = all.sorted { $0.1.focusedAt > $1.1.focusedAt }
        guard let best = ranked.first, best.1.focusedAt > 0,
              ranked.count == 1 || ranked[1].1.focusedAt < best.1.focusedAt else { return nil }
        return (socket: best.0, state: best.1)
    }
}

#if canImport(Darwin)
nonisolated extension VSCodeBridgeClient {
    /// Blocking connect, send one line, read one line (bounded by byte count, per-call timeout and an overall deadline).
    static func exchange(path: String, request: Data, timeout: TimeInterval) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw VSCodeBridgeError.unavailable }
        defer { close(descriptor) }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        for option in [SO_SNDTIMEO, SO_RCVTIMEO] {
            setsockopt(descriptor, SOL_SOCKET, option, &interval, socklen_t(MemoryLayout<timeval>.size))
        }
        try connectSocket(descriptor, path: path)
        try sendAll(descriptor, request)
        return try readLine(descriptor, deadline: Date().addingTimeInterval(timeout))
    }

    private static func connectSocket(_ descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw VSCodeBridgeError.unavailable }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
                target[bytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw errno == EAGAIN || errno == ETIMEDOUT ? VSCodeBridgeError.timedOut : .unavailable }
    }

    private static func sendAll(_ descriptor: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            while sent < data.count {
                let count = send(descriptor, buffer.baseAddress! + sent, data.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw errno == EAGAIN ? VSCodeBridgeError.timedOut : .unavailable }
                sent += count
            }
        }
    }

    private static func readLine(_ descriptor: Int32, deadline: Date) throws -> Data {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if Date() > deadline { throw VSCodeBridgeError.timedOut }
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw VSCodeBridgeError.timedOut
            }
            if count == 0 { throw VSCodeBridgeError.timedOut }
            collected.append(chunk, count: count)
            if let newline = collected.firstIndex(of: 10) { return collected.prefix(upTo: newline) }
            if collected.count > maximumResponseBytes { throw VSCodeBridgeError.timedOut }
        }
    }
}
#else
nonisolated extension VSCodeBridgeClient {
    static func exchange(path: String, request: Data, timeout: TimeInterval) throws -> Data {
        throw VSCodeBridgeError.unavailable
    }
}
#endif
