import XCTest
@testable import ClickyCore

final class LocalWorkerProtocolTests: XCTestCase {
    private let session = "s1"

    private func event(_ request: UUID = UUID()) -> LocalWorkerEvent { .delta(session: "s1", request: request, text: "hi") }

    private func rawFrame(header: Data, payloadLength: Int = 0, headerLength: Int? = nil, magic: [UInt8] = LocalWorkerProtocol.magic) -> Data {
        var data = Data(magic)
        data.append(contentsOf: LocalWorkerFrame<LocalWorkerEvent>.bigEndianBytes(UInt32(headerLength ?? header.count)))
        data.append(contentsOf: LocalWorkerFrame<LocalWorkerEvent>.bigEndianBytes(UInt32(payloadLength)))
        data.append(header)
        return data
    }

    // MARK: Framer

    func testByteByByteSplitDecodesOneFrame() throws {
        let message = event()
        let data = try LocalWorkerFrame(message, payload: Data([1, 2, 3])).encoded()
        var framer = LocalWorkerFramer<LocalWorkerEvent>()
        var frames: [LocalWorkerFrame<LocalWorkerEvent>] = []
        for byte in data { frames += try framer.append(Data([byte])) }
        XCTAssertEqual(frames, [LocalWorkerFrame(message, payload: Data([1, 2, 3]))])
        XCTAssertFalse(framer.hasPartialFrame)
    }

    func testMultipleFramesInOneChunkAndTrailingPartial() throws {
        let a = event(), b = event()
        var data = try LocalWorkerFrame(a).encoded()
        data.append(try LocalWorkerFrame(b, payload: Data(repeating: 7, count: 100)).encoded())
        let third = try LocalWorkerFrame(event()).encoded()
        data.append(third.prefix(5))
        var framer = LocalWorkerFramer<LocalWorkerEvent>()
        let frames = try framer.append(data)
        XCTAssertEqual(frames.map(\.message), [a, b])
        XCTAssertEqual(frames[1].payload.count, 100)
        XCTAssertTrue(framer.hasPartialFrame)
    }

    func testPayloadRoundTripWithLargeBinary() throws {
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        let data = try LocalWorkerFrame(LocalWorkerCommand.memory(request: UUID()), payload: payload).encoded()
        var framer = LocalWorkerFramer<LocalWorkerCommand>()
        XCTAssertEqual(try framer.append(data).first?.payload, payload)
    }

    func testBadMagicIsRejected() {
        var framer = LocalWorkerFramer<LocalWorkerEvent>()
        let data = rawFrame(header: Data("{}".utf8), magic: Array("NOPE".utf8))
        XCTAssertThrowsError(try framer.append(data)) { XCTAssertEqual(($0 as? LocalWorkerError)?.code, .invalidMessage) }
    }

    func testOversizedHeaderAndPayloadAreRejectedBeforeBuffering() {
        var headerFramer = LocalWorkerFramer<LocalWorkerEvent>()
        let oversizedHeader = rawFrame(header: Data(), headerLength: LocalWorkerProtocol.maximumHeaderBytes + 1)
        XCTAssertThrowsError(try headerFramer.append(oversizedHeader)) { XCTAssertEqual(($0 as? LocalWorkerError)?.code, .inputTooLarge) }
        var payloadFramer = LocalWorkerFramer<LocalWorkerEvent>()
        let oversizedPayload = rawFrame(header: Data("{}".utf8), payloadLength: LocalWorkerProtocol.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try payloadFramer.append(oversizedPayload)) { XCTAssertEqual(($0 as? LocalWorkerError)?.code, .inputTooLarge) }
    }

    func testOversizedPayloadCannotBeEncoded() {
        let frame = LocalWorkerFrame(LocalWorkerCommand.shutdown, payload: Data(count: LocalWorkerProtocol.maximumPayloadBytes + 1))
        XCTAssertThrowsError(try frame.encoded()) { XCTAssertEqual(($0 as? LocalWorkerError)?.code, .inputTooLarge) }
    }

    func testUndecodableHeaderIsRejected() {
        var framer = LocalWorkerFramer<LocalWorkerEvent>()
        XCTAssertThrowsError(try framer.append(rawFrame(header: Data("not json".utf8)))) {
            XCTAssertEqual(($0 as? LocalWorkerError)?.code, .invalidMessage)
        }
    }

    // MARK: Ledger

    func testDuplicateRegisterIsRejectedWhilePendingAndAfterFinish() {
        var ledger = LocalWorkerLedger(session: session)
        let id = UUID()
        XCTAssertTrue(ledger.register(id))
        XCTAssertFalse(ledger.register(id))
        _ = ledger.classify(.completed(session: session, request: id, text: "", metrics: LocalRunMetrics(totalMilliseconds: 1)))
        XCTAssertFalse(ledger.register(id))
    }

    func testEventsAfterTerminalAreStale() {
        var ledger = LocalWorkerLedger(session: session)
        let id = UUID()
        XCTAssertTrue(ledger.register(id))
        XCTAssertEqual(ledger.classify(event(id)), .deliver(terminal: false))
        let done = LocalWorkerEvent.completed(session: session, request: id, text: "", metrics: LocalRunMetrics(totalMilliseconds: 1))
        XCTAssertEqual(ledger.classify(done), .deliver(terminal: true))
        XCTAssertEqual(ledger.classify(done), .stale)
        XCTAssertEqual(ledger.classify(event(id)), .stale)
        XCTAssertTrue(ledger.pendingRequests.isEmpty)
    }

    func testViolationsForOtherSessionUnknownRequestAndSecondReady() {
        var ledger = LocalWorkerLedger(session: session)
        let id = UUID()
        XCTAssertTrue(ledger.register(id))
        guard case .violation = ledger.classify(.delta(session: "other", request: id, text: "")) else { return XCTFail("session") }
        guard case .violation = ledger.classify(event(UUID())) else { return XCTFail("unknown request") }
        let readiness = LocalWorkerReadiness(protocolVersion: 1, role: .inference, processIdentifier: 1, runtime: [:],
                                             metalDevice: nil, networkDenied: false, supportedKinds: [])
        guard case .violation = ledger.classify(.ready(session: session, readiness: readiness)) else { return XCTFail("second ready") }
    }

    func testRequestlessFailureIsTerminalDelivery() {
        var ledger = LocalWorkerLedger(session: session)
        XCTAssertEqual(ledger.classify(.failed(session: session, request: nil, error: LocalWorkerError(.internalError, "x"))), .deliver(terminal: true))
    }

    func testAbandonMakesLaterEventsStaleAndFailAllReturnsPendingOnce() {
        var ledger = LocalWorkerLedger(session: session)
        let abandoned = UUID(), a = UUID(), b = UUID()
        XCTAssertTrue(ledger.register(abandoned) && ledger.register(a) && ledger.register(b))
        ledger.abandon(abandoned)
        XCTAssertEqual(ledger.classify(event(abandoned)), .stale)
        XCTAssertEqual(Set(ledger.failAll()), [a, b])
        XCTAssertTrue(ledger.failAll().isEmpty)
        XCTAssertEqual(ledger.classify(event(a)), .stale)
        XCTAssertFalse(ledger.register(a))
    }
}
