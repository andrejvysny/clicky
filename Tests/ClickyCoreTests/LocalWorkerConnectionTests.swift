import XCTest
@testable import ClickyCore

final class LocalWorkerConnectionTests: XCTestCase {
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var exits: [LocalWorkerExit] = []
        func record(_ exit: LocalWorkerExit) { lock.lock(); exits.append(exit); lock.unlock() }
        var all: [LocalWorkerExit] { lock.lock(); defer { lock.unlock() }; return exits }
        func first(timeout: TimeInterval = 4) async -> LocalWorkerExit? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let value = all.first { return value }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    private var workerURL: URL {
        Bundle(for: LocalWorkerConnectionTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clicky-fake-worker")
    }

    private func make(_ behavior: String = "normal", role: LocalWorkerRole = .inference, cancelGrace: TimeInterval = 3,
                      handshakeTimeout: TimeInterval = 4, box: ExitBox = ExitBox()) -> (LocalWorkerConnection, ExitBox) {
        let connection = LocalWorkerConnection(
            executable: workerURL, role: role, arguments: ["--role", role.rawValue, "--behavior", behavior], environment: [:],
            handshakeTimeout: handshakeTimeout, cancelGrace: cancelGrace, onExit: { box.record($0) })
        addTeardownBlock { connection.terminate() }
        return (connection, box)
    }

    private func generate(_ id: UUID = UUID()) -> LocalWorkerCommand {
        .generate(request: id, modelIdentifier: "m", messages: [LocalChatMessage(role: .user, text: "hi")],
                  parameters: LocalGenerationParameters(), hasImage: false)
    }

    private func collect(_ stream: AsyncThrowingStream<LocalWorkerEvent, Error>) async -> (events: [LocalWorkerEvent], error: Error?) {
        var events: [LocalWorkerEvent] = []
        do { for try await event in stream { events.append(event) } } catch { return (events, error) }
        return (events, nil)
    }

    func testHandshakeReportsReadinessAndShutdownIsRequested() async throws {
        let (connection, box) = make(role: .speech)
        let readiness = try await connection.start()
        XCTAssertEqual(readiness.role, .speech)
        XCTAssertEqual(readiness.protocolVersion, LocalWorkerProtocol.version)
        XCTAssertEqual(readiness.runtime, ["fake": "1"])
        XCTAssertEqual(Set(readiness.supportedKinds), [.parakeetCoreML, .whisperKit])
        XCTAssertEqual(connection.readiness, readiness)
        XCTAssertTrue(connection.isRunning)
        connection.shutdown()
        let exit = await box.first()
        XCTAssertEqual(exit, .requested)
        XCTAssertFalse(connection.isRunning)
        XCTAssertEqual(box.all.count, 1)
    }

    func testGenerateStreamsDeltasAndOneCompletion() async throws {
        let (connection, _) = make()
        _ = try await connection.start()
        let id = UUID()
        let result = await collect(connection.request(generate(id)))
        XCTAssertNil(result.error)
        let deltas = result.events.compactMap { event -> String? in if case .delta(_, _, let text) = event { return text }; return nil }
        XCTAssertEqual(deltas, ["a", "b", "c"])
        let completions = result.events.compactMap { event -> (String, Double)? in
            if case .completed(_, _, let text, let metrics) = event { return (text, metrics.totalMilliseconds) }; return nil
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.0, "abc")
        XCTAssertGreaterThan(completions.first?.1 ?? 0, 0)
        XCTAssertTrue(result.events.allSatisfy { $0.request == id })
    }

    func testLoadAndMemoryRequests() async throws {
        let (connection, _) = make()
        _ = try await connection.start()
        let model = LocalModelReference(identifier: "m", revision: "r", kind: .mlxLLM, directory: "/nonexistent", fingerprint: "f")
        let load = await collect(connection.request(.load(request: UUID(), model: model, warmUp: false)))
        XCTAssertNil(load.error)
        guard case .progress = load.events.first, case .completed(_, _, let text, _) = load.events.last else { return XCTFail("load events") }
        XCTAssertEqual(text, "loaded")
        let memory = await collect(connection.request(.memory(request: UUID())))
        XCTAssertNil(memory.error)
        guard case .memory(_, _, let report) = memory.events.last else { return XCTFail("memory event") }
        XCTAssertEqual(report.physicalFootprintBytes, 1234)
    }

    func testCancelEndsStreamWithCancellationError() async throws {
        let (connection, box) = make()
        _ = try await connection.start()
        let id = UUID()
        let stream = connection.request(generate(id))
        connection.cancel(id)
        let result = await collect(stream)
        XCTAssertTrue(result.error is CancellationError)
        XCTAssertTrue(connection.isRunning)
        XCTAssertTrue(box.all.isEmpty)
        connection.cancel(id)  // finished request: no-op
        connection.cancel(UUID())
    }

    func testHangingWorkerIsTerminatedAfterCancelGrace() async throws {
        let (connection, box) = make("hangGenerate", cancelGrace: 0.3)
        _ = try await connection.start()
        let id = UUID()
        let stream = connection.request(generate(id))
        connection.cancel(id)
        let result = await collect(stream)
        XCTAssertEqual((result.error as? LocalWorkerError)?.code, .workerUnavailable)
        let exit = await box.first()
        XCTAssertEqual(exit, .unresponsive)
        XCTAssertEqual(box.all.count, 1)
    }

    func testCrashFailsPendingRequestOnceWithWorkerUnavailable() async throws {
        let (connection, box) = make("crashOnGenerate")
        _ = try await connection.start()
        let result = await collect(connection.request(generate()))
        XCTAssertEqual((result.error as? LocalWorkerError)?.code, .workerUnavailable)
        let exit = await box.first()
        XCTAssertEqual(exit, .crashed(3))
        let after = await collect(connection.request(generate()))
        XCTAssertEqual((after.error as? LocalWorkerError)?.code, .workerUnavailable)
    }

    func testDuplicateTerminalAndLateEventsAreDroppedAndConnectionStaysUsable() async throws {
        let (connection, box) = make("duplicateTerminal")
        _ = try await connection.start()
        let first = UUID()
        let one = await collect(connection.request(generate(first)))
        XCTAssertNil(one.error)
        XCTAssertEqual(one.events.filter { if case .completed = $0 { return true }; return false }.count, 1)
        let second = UUID()
        let two = await collect(connection.request(generate(second)))
        XCTAssertNil(two.error)
        XCTAssertTrue(two.events.allSatisfy { $0.request == second })
        XCTAssertEqual(two.events.filter { if case .completed = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(connection.isRunning)
        XCTAssertTrue(box.all.isEmpty)
    }

    func testProtocolViolationsTerminateTheWorker() async throws {
        for behavior in ["wrongSession", "garbage", "unknownRequest"] {
            let (connection, box) = make(behavior)
            _ = try await connection.start()
            let exit = await box.first()
            guard case .protocolViolation = exit else { return XCTFail("\(behavior): \(String(describing: exit))") }
            let after = await collect(connection.request(generate()))
            XCTAssertEqual((after.error as? LocalWorkerError)?.code, .workerUnavailable, behavior)
        }
    }

    func testBadVersionFailsStartWithProtocolMismatch() async {
        let (connection, box) = make("badVersion")
        do {
            _ = try await connection.start()
            XCTFail("start must throw")
        } catch {
            XCTAssertEqual((error as? LocalWorkerError)?.code, .protocolMismatch)
        }
        let exit = await box.first()
        guard case .protocolViolation = exit else { return XCTFail("exit \(String(describing: exit))") }
        XCTAssertNil(connection.readiness)
    }

    func testHandshakeTimeoutAndMissingExecutable() async {
        let silent = LocalWorkerConnection(executable: URL(fileURLWithPath: "/bin/sleep"), role: .inference, arguments: ["30"],
                                           environment: [:], handshakeTimeout: 0.3)
        do { _ = try await silent.start(); XCTFail("start must throw") }
        catch { XCTAssertEqual((error as? LocalWorkerError)?.code, .timedOut) }
        silent.terminate()
        let missing = LocalWorkerConnection(executable: URL(fileURLWithPath: "/nonexistent/worker"), role: .inference, environment: [:])
        do { _ = try await missing.start(); XCTFail("start must throw") }
        catch { XCTAssertEqual((error as? LocalWorkerError)?.code, .workerUnavailable) }
    }

    func testDuplicateRequestIdAndNonRequestCommandsAreRejectedLocally() async throws {
        let (connection, _) = make()
        _ = try await connection.start()
        let id = UUID()
        let first = await collect(connection.request(generate(id)))
        XCTAssertNil(first.error)
        let duplicate = await collect(connection.request(generate(id)))
        XCTAssertEqual((duplicate.error as? LocalWorkerError)?.code, .duplicateRequest)
        XCTAssertTrue(duplicate.events.isEmpty)
        let shutdown = await collect(connection.request(.shutdown))
        XCTAssertEqual((shutdown.error as? LocalWorkerError)?.code, .invalidMessage)
        let cancel = await collect(connection.request(.cancel(request: id)))
        XCTAssertEqual((cancel.error as? LocalWorkerError)?.code, .invalidMessage)
        XCTAssertTrue(connection.isRunning)
    }

    func testTranscribeValidatesPayloadSize() async throws {
        let (connection, _) = make(role: .speech)
        _ = try await connection.start()
        let good = await collect(connection.request(.transcribe(request: UUID(), modelIdentifier: "m", sampleCount: 4, language: "en"),
                                                    payload: Data(count: 8)))
        XCTAssertNil(good.error)
        guard case .completed(_, _, let text, _) = good.events.last else { return XCTFail("completion") }
        XCTAssertEqual(text, "samples=4")
        let bad = await collect(connection.request(.transcribe(request: UUID(), modelIdentifier: "m", sampleCount: 4, language: "en"),
                                                   payload: Data(count: 3)))
        XCTAssertEqual((bad.error as? LocalWorkerError)?.code, .invalidMessage)
        XCTAssertTrue(connection.isRunning)
    }

    func testTerminateFailsPendingOnceAndLaterRequestsAreRefused() async throws {
        let (connection, box) = make("hangGenerate")
        _ = try await connection.start()
        let stream = connection.request(generate())
        connection.terminate()
        let result = await collect(stream)
        XCTAssertEqual((result.error as? LocalWorkerError)?.code, .workerUnavailable)
        let later = await collect(connection.request(generate()))
        XCTAssertEqual((later.error as? LocalWorkerError)?.code, .workerUnavailable)
        let exit = await box.first()
        XCTAssertEqual(exit, .requested)
        XCTAssertEqual(box.all.count, 1)
    }

    func testConsumerDroppingStreamAbandonsRequestWithoutBreakingConnection() async throws {
        let (connection, box) = make()
        _ = try await connection.start()
        var stream: AsyncThrowingStream<LocalWorkerEvent, Error>? = connection.request(generate())
        var iterator = stream!.makeAsyncIterator()
        _ = try await iterator.next()
        stream = nil
        _ = stream
        let next = await collect(connection.request(generate()))
        XCTAssertNil(next.error)
        XCTAssertTrue(connection.isRunning)
        XCTAssertTrue(box.all.isEmpty)
    }

    func testCancelledConsumerOfHangingWorkerIsTerminatedAfterGrace() async throws {
        let (connection, box) = make("hangGenerate", cancelGrace: 0.3)
        _ = try await connection.start()
        let stream = connection.request(generate())
        let consumer = Task { for try await _ in stream {} }
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        let exit = await box.first()
        XCTAssertEqual(exit, .unresponsive)
        XCTAssertEqual(box.all.count, 1)
    }

    func testCancelledConsumerOfResponsiveWorkerKeepsConnection() async throws {
        let (connection, box) = make(cancelGrace: 0.4)
        _ = try await connection.start()
        let stream = connection.request(generate())
        let consumer = Task { for try await _ in stream {} }
        try await Task.sleep(nanoseconds: 25_000_000)
        consumer.cancel()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(connection.isRunning)
        XCTAssertTrue(box.all.isEmpty)
        let next = await collect(connection.request(generate()))
        XCTAssertNil(next.error)
    }
}
