import XCTest
import Foundation
@testable import ClickyCore
#if canImport(Darwin)
import Darwin
#endif

final class VSCodeBridgeTests: XCTestCase {
    func testRequestEncodingIsOneLineWithTokenAndVersion() throws {
        let data = try VSCodeBridgeWire.encodeRequest(id: "i1", token: "tok", method: "state", params: ["a": .string("x\ny")])
        XCTAssertEqual(data.last, 10)
        XCTAssertEqual(data.filter { $0 == 10 }.count, 1)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["v"].integer, 1)
        XCTAssertEqual(value["token"].string, "tok")
        XCTAssertEqual(value["method"].string, "state")
        XCTAssertEqual(value["params"]["a"].string, "x\ny")
    }

    func testReplaceReceiptRecordsCRLFNormalizedText() {
        let normalized = VSCodeReplaceResult(applied: true, verified: true, normalizedLineEndings: true, version: 2, start: 0, end: 4)
        XCTAssertEqual(normalized.insertedText(requested: "a\nb"), "a\r\nb")
        XCTAssertEqual(normalized.insertedText(requested: "a\r\nb\n😀"), "a\r\nb\r\n😀")
        XCTAssertEqual(VSCodeReplaceResult(applied: true, normalizedLineEndings: false).insertedText(requested: "a\nb"), "a\nb")
    }

    func testTerminalReadinessIsUnknownUnlessReported() throws {
        let legacy = VSCodeBridgeState.Terminal(id: 1, name: "zsh", shellIntegration: true, busy: false, shell: "zsh")
        XCTAssertFalse(legacy.isReady)
        let ready = VSCodeBridgeState.Terminal(id: 1, name: "zsh", shellIntegration: true, busy: false, shell: "zsh", readiness: "ready")
        XCTAssertTrue(ready.isReady)
        let unknown = VSCodeBridgeState.Terminal(id: 1, name: "zsh", shellIntegration: true, busy: false, shell: "zsh", readiness: "unknown")
        XCTAssertFalse(unknown.isReady)
    }

    func testResponseDecoding() throws {
        let ok = Data(#"{"v":1,"id":"a","ok":true,"result":{"sent":true}}"#.utf8)
        XCTAssertTrue(try VSCodeBridgeWire.decodeResponse(ok, expectingID: "a")["sent"].bool)
        let bad = Data(#"{"v":1,"id":"a","ok":false,"error":"stale"}"#.utf8)
        XCTAssertThrowsError(try VSCodeBridgeWire.decodeResponse(bad, expectingID: "a")) {
            XCTAssertEqual($0 as? VSCodeBridgeError, .remote("stale"))
        }
        XCTAssertThrowsError(try VSCodeBridgeWire.decodeResponse(ok, expectingID: "b")) {
            XCTAssertEqual($0 as? VSCodeBridgeError, .protocolViolation)
        }
        let wrongVersion = Data(#"{"v":2,"id":"a","ok":true,"result":{}}"#.utf8)
        XCTAssertThrowsError(try VSCodeBridgeWire.decodeResponse(wrongVersion, expectingID: "a"))
        XCTAssertThrowsError(try VSCodeBridgeWire.decodeResponse(Data("garbage".utf8), expectingID: "a"))
    }

    func testStateAndReplaceResultDecode() throws {
        let json = #"{"focused":true,"focusedAt":1234.5,"editor":{"uri":"file:///a","version":3,"eol":"lf","languageId":"swift","selections":[{"start":1,"end":2,"active":2}],"isUntitled":false},"terminal":{"id":null,"name":"zsh","shellIntegration":true,"busy":false,"shell":null}}"#
        let state = try JSONDecoder().decode(VSCodeBridgeState.self, from: Data(json.utf8))
        XCTAssertEqual(state.editor?.selections.first?.active, 2)
        XCTAssertEqual(state.focusedAt, 1234.5)
        XCTAssertNil(state.terminal?.id)
        XCTAssertNil(state.terminal?.shell)
        let result = try JSONDecoder().decode(VSCodeReplaceResult.self, from: Data(#"{"applied":false}"#.utf8))
        XCTAssertFalse(result.applied)
        XCTAssertNil(result.version)
    }

    func testSocketNameMatching() {
        XCTAssertTrue(VSCodeBridgeClient.isSocketName("vscode-123.sock"))
        XCTAssertFalse(VSCodeBridgeClient.isSocketName("vscode-.sock"))
        XCTAssertFalse(VSCodeBridgeClient.isSocketName("vscode-12a.sock"))
        XCTAssertFalse(VSCodeBridgeClient.isSocketName("token"))
    }

    func testExtensionSourceGuards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tools/clicky-vscode-bridge/extension.js"), encoding: .utf8)
        XCTAssertFalse(source.contains("executeCommand"))
        XCTAssertFalse(source.contains("child_process"))
        XCTAssertFalse(source.contains("tasks."))
        let calls = source.components(separatedBy: "sendText(").dropFirst()
        XCTAssertFalse(calls.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"^[^,()]+,\s*false\s*\)"#)
        for call in calls {
            XCTAssertNotNil(pattern.firstMatch(in: call, range: NSRange(call.startIndex..., in: call)), "sendText must pass literal false")
        }
    }
}

#if canImport(Darwin)
extension VSCodeBridgeTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vb" + String(UInt32.random(in: 0...99999)))
        try VSCodeBridgeClient.createToken(directory: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTokenLifecycle() throws {
        let dir = try makeDirectory()
        let client = VSCodeBridgeClient(directory: dir)
        XCTAssertTrue(client.tokenExists())
        let token = try String(contentsOf: dir.appendingPathComponent("token"), encoding: .utf8)
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("token").path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int ?? 0) & 0o777, 0o600)
        VSCodeBridgeClient.removeToken(directory: dir)
        XCTAssertFalse(client.tokenExists())
    }

    func testCallSendsOneLineWithTokenAndParsesResponse() async throws {
        let dir = try makeDirectory()
        let token = try String(contentsOf: dir.appendingPathComponent("token"), encoding: .utf8)
        let server = try FakeBridgeServer(path: dir.appendingPathComponent("vscode-1.sock").path) { line in
            let request = try? JSONDecoder().decode(JSONValue.self, from: line)
            XCTAssertEqual(request?["token"].string, token)
            XCTAssertEqual(request?["method"].string, "insertTerminal")
            let id = request?["id"].string ?? ""
            return Data(#"{"v":1,"id":"\#(id)","ok":true,"result":{"sent":true}}"#.utf8)
        }
        defer { server.stop() }
        let client = VSCodeBridgeClient(directory: dir, timeout: 2)
        try await client.insertTerminal(socket: client.sockets()[0], terminalID: 5, text: "ls | cat")
        XCTAssertEqual(server.receivedLines, 1)
    }

    func testRemoteErrorMismatchedIDAndTimeout() async throws {
        let dir = try makeDirectory()
        let errorServer = try FakeBridgeServer(path: dir.appendingPathComponent("vscode-2.sock").path) { line in
            let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"].string ?? ""
            return Data(#"{"v":1,"id":"\#(id)","ok":false,"error":"busy"}"#.utf8)
        }
        let wrongID = try FakeBridgeServer(path: dir.appendingPathComponent("vscode-3.sock").path) { _ in
            Data(#"{"v":1,"id":"other","ok":true,"result":{}}"#.utf8)
        }
        let silent = try FakeBridgeServer(path: dir.appendingPathComponent("vscode-4.sock").path) { _ in nil }
        defer { errorServer.stop(); wrongID.stop(); silent.stop() }
        let client = VSCodeBridgeClient(directory: dir, timeout: 0.3)
        let sockets = client.sockets()
        do { _ = try await client.state(socket: sockets[0]); XCTFail() } catch { XCTAssertEqual(error as? VSCodeBridgeError, .remote("busy")) }
        do { _ = try await client.state(socket: sockets[1]); XCTFail() } catch { XCTAssertEqual(error as? VSCodeBridgeError, .timedOut) }
        do { _ = try await client.state(socket: sockets[2]); XCTFail() } catch { XCTAssertEqual(error as? VSCodeBridgeError, .timedOut) }
    }

    func testConnectFailureBeforeWriteIsUnavailable() async throws {
        let dir = try makeDirectory()
        let client = VSCodeBridgeClient(directory: dir, timeout: 0.3)
        do { _ = try await client.state(socket: dir.appendingPathComponent("vscode-99.sock")); XCTFail() }
        catch { XCTAssertEqual(error as? VSCodeBridgeError, .unavailable) }
        let state = try JSONDecoder().decode(VSCodeBridgeState.self, from: Data(#"{"focused":false,"editor":null,"terminal":null}"#.utf8))
        XCTAssertEqual(state.focusedAt, 0)
    }

    func testFocusedWindowPicksSingleFocusedSocket() async throws {
        let dir = try makeDirectory()
        @Sendable func state(_ focused: Bool, _ at: Int) -> String {
            #"{"focused":\#(focused),"focusedAt":\#(at),"editor":null,"terminal":null}"#
        }
        func server(_ name: String, focused: Bool, at: Int = 0) throws -> FakeBridgeServer {
            try FakeBridgeServer(path: dir.appendingPathComponent(name).path) { line in
                let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"].string ?? ""
                return Data(#"{"v":1,"id":"\#(id)","ok":true,"result":\#(state(focused, at))}"#.utf8)
            }
        }
        let a = try server("vscode-10.sock", focused: false)
        let b = try server("vscode-11.sock", focused: true)
        defer { a.stop(); b.stop() }
        let client = VSCodeBridgeClient(directory: dir, timeout: 2)
        let found = await client.focusedWindow()
        XCTAssertEqual(found?.socket.lastPathComponent, "vscode-11.sock")

        let c = try server("vscode-12.sock", focused: true)
        defer { c.stop() }
        let ambiguous = await client.focusedWindow()
        XCTAssertNil(ambiguous)
    }

    func testFocusedWindowFallsBackToLatestFocusGain() async throws {
        let dir = try makeDirectory()
        func server(_ name: String, at: Int) throws -> FakeBridgeServer {
            try FakeBridgeServer(path: dir.appendingPathComponent(name).path) { line in
                let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"].string ?? ""
                return Data(#"{"v":1,"id":"\#(id)","ok":true,"result":{"focused":false,"focusedAt":\#(at),"editor":null,"terminal":null}}"#.utf8)
            }
        }
        let never = try server("vscode-20.sock", at: 0)
        let old = try server("vscode-21.sock", at: 100)
        let recent = try server("vscode-22.sock", at: 200)
        defer { never.stop(); old.stop(); recent.stop() }
        let client = VSCodeBridgeClient(directory: dir, timeout: 2)
        let found = await client.focusedWindow()
        XCTAssertEqual(found?.socket.lastPathComponent, "vscode-22.sock")

        let tie = try server("vscode-23.sock", at: 200)
        defer { tie.stop() }
        let tied = await client.focusedWindow()
        XCTAssertNil(tied)
    }

    func testFocusedWindowNilWhenNeverFocused() async throws {
        let dir = try makeDirectory()
        let a = try FakeBridgeServer(path: dir.appendingPathComponent("vscode-30.sock").path) { line in
            let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"].string ?? ""
            return Data(#"{"v":1,"id":"\#(id)","ok":true,"result":{"focused":false,"focusedAt":0,"editor":null,"terminal":null}}"#.utf8)
        }
        defer { a.stop() }
        let none = await VSCodeBridgeClient(directory: dir, timeout: 2).focusedWindow()
        XCTAssertNil(none)
    }
}

/// Accepts connections on a unix socket on a background thread; reads one line and answers with `handler`'s data.
final class FakeBridgeServer: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var lines = 0
    private var running = true
    var receivedLines: Int { lock.lock(); defer { lock.unlock() }; return lines }

    init(path: String, handler: @escaping @Sendable (Data) -> Data?) throws {
        self.path = path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(bytes.count < capacity, "socket path too long")
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
                target[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw VSCodeBridgeError.unavailable }
        let listener = descriptor
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                serve(client, handler)
            }
        }
    }

    private func serve(_ client: Int32, _ handler: (Data) -> Data?) {
        defer { close(client) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(10) {
            let count = recv(client, &chunk, chunk.count, 0)
            if count <= 0 { return }
            data.append(chunk, count: count)
        }
        lock.lock(); lines += data.filter { $0 == 10 }.count; lock.unlock()
        guard var reply = handler(data.prefix(upTo: data.firstIndex(of: 10)!)) else {
            usleep(1_000_000) // silent server: hold the connection open past the client timeout
            return
        }
        reply.append(10)
        _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
#endif
