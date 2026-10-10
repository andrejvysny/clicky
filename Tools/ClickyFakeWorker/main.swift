import ClickyCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Scripted stand-in for the local inference worker: speaks LocalWorkerProtocol on stdin/stdout with deterministic
// behaviors so host-side connection tests never need models, Metal or network.

signal(SIGPIPE, SIG_IGN)

final class FakeWorker: @unchecked Sendable {
    let role: LocalWorkerRole
    let behavior: String
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var session = ""
    private var seen: Set<UUID> = []
    private var canceled: Set<UUID> = []

    init(role: LocalWorkerRole, behavior: String) { self.role = role; self.behavior = behavior }

    func send(_ event: LocalWorkerEvent) {
        guard let data = try? LocalWorkerFrame(event).encoded() else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    func sendRaw(_ data: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    func run() {
        var framer = LocalWorkerFramer<LocalWorkerCommand>()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { exit(0) }
            guard let frames = try? framer.append(chunk) else { exit(2) }
            for frame in frames { handle(frame.message, payload: frame.payload) }
        }
    }

    private var supportedKinds: [LocalModelKind] { LocalModelKind.allCases.filter { $0.role == role } }

    private func handle(_ command: LocalWorkerCommand, payload: Data) {
        switch command {
        case .hello(_, _, let session):
            stateLock.lock(); self.session = session; stateLock.unlock()
            let version = behavior == "badVersion" ? 999 : LocalWorkerProtocol.version
            send(.ready(session: session, readiness: LocalWorkerReadiness(
                protocolVersion: version, role: role, processIdentifier: getpid(), runtime: ["fake": "1"],
                metalDevice: nil, networkDenied: false, supportedKinds: supportedKinds)))
            afterHandshake(session)
        case .shutdown:
            exit(0)
        case .cancel(let request):
            stateLock.lock(); canceled.insert(request); stateLock.unlock()
        case .load(let request, _, _):
            guard begin(request) else { return }
            send(.progress(session: session, request: request, stage: "loading", fraction: 0.5))
            send(.completed(session: session, request: request, text: "loaded", metrics: LocalRunMetrics(totalMilliseconds: 1)))
        case .unload(let request, _), .clearCaches(let request):
            guard begin(request) else { return }
            send(.completed(session: session, request: request, text: "ok", metrics: LocalRunMetrics(totalMilliseconds: 1)))
        case .memory(let request):
            guard begin(request) else { return }
            send(.memory(session: session, request: request, report: LocalMemoryReport(physicalFootprintBytes: 1234)))
        case .transcribe(let request, _, let sampleCount, _):
            guard begin(request) else { return }
            guard payload.count == sampleCount * 2 else {
                send(.failed(session: session, request: request, error: LocalWorkerError(.invalidMessage, "Payload size mismatch.")))
                return
            }
            send(.completed(session: session, request: request, text: "samples=\(sampleCount)", metrics: LocalRunMetrics(totalMilliseconds: 1)))
        case .generate(let request, _, _, _, _):
            guard begin(request) else { return }
            generate(request)
        }
    }

    private func afterHandshake(_ session: String) {
        switch behavior {
        case "wrongSession":
            send(.accepted(session: "other-session", request: UUID()))
        case "garbage":
            sendRaw(Data("this is not a frame at all".utf8))
        case "unknownRequest":
            send(.completed(session: session, request: UUID(), text: "?", metrics: LocalRunMetrics(totalMilliseconds: 1)))
        default: break
        }
    }

    private func begin(_ request: UUID) -> Bool {
        stateLock.lock()
        let inserted = seen.insert(request).inserted
        stateLock.unlock()
        if !inserted { send(.failed(session: session, request: request, error: LocalWorkerError(.duplicateRequest, "Request id reused."))) }
        return inserted
    }

    private func isCanceled(_ request: UUID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return canceled.contains(request)
    }

    private func generate(_ request: UUID) {
        let session = self.session
        switch behavior {
        case "hangGenerate":
            return
        case "crashOnGenerate":
            send(.accepted(session: session, request: request))
            exit(3)
        case "duplicateTerminal":
            send(.accepted(session: session, request: request))
            let metrics = LocalRunMetrics(totalMilliseconds: 1)
            send(.completed(session: session, request: request, text: "x", metrics: metrics))
            send(.completed(session: session, request: request, text: "x", metrics: metrics))
            send(.delta(session: session, request: request, text: "late"))
            return
        default: break
        }
        Thread.detachNewThread { [self] in
            send(.accepted(session: session, request: request))
            for piece in ["a", "b", "c"] {
                Thread.sleep(forTimeInterval: 0.02)
                if isCanceled(request) { send(.canceled(session: session, request: request)); return }
                send(.delta(session: session, request: request, text: piece))
            }
            if isCanceled(request) { send(.canceled(session: session, request: request)); return }
            send(.completed(session: session, request: request, text: "abc", metrics: LocalRunMetrics(totalMilliseconds: 60)))
        }
    }
}

var role = LocalWorkerRole.inference
var behavior = "normal"
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--role": if let value = arguments.next(), let parsed = LocalWorkerRole(rawValue: value) { role = parsed }
    case "--behavior": if let value = arguments.next() { behavior = value }
    default: break
    }
}
FakeWorker(role: role, behavior: behavior).run()
