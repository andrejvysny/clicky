import ClickyCore
import Foundation

/// In-process handshake and protocol checks that need no model, GPU or network (for CI).
enum SelfTest {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var codes: [Int32] = []
        func append(_ chunk: Data) -> Bool { lock.lock(); data.append(chunk); lock.unlock(); return true }
        func exit(_ code: Int32) { lock.lock(); codes.append(code); lock.unlock() }
        var exitCodes: [Int32] { lock.lock(); defer { lock.unlock() }; return codes }
        func events() -> [LocalWorkerEvent] {
            lock.lock(); defer { lock.unlock() }
            var framer = LocalWorkerFramer<LocalWorkerEvent>()
            return ((try? framer.append(data)) ?? []).map(\.message)
        }
    }

    static func run(role: LocalWorkerRole, networkDenied: Bool, metalDevice: String?) async -> Bool {
        func makeServer() -> (WorkerServer, Recorder) {
            let recorder = Recorder()
            let server = WorkerServer(
                role: role, output: WorkerOutput(sink: recorder.append), networkDenied: networkDenied,
                metalDevice: metalDevice, terminate: { recorder.exit($0) })
            return (server, recorder)
        }
        func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }
        let wrongRole: LocalWorkerRole = role == .inference ? .speech : .inference

        // Wrong role in hello: protocolMismatch and exit code 2.
        let (mismatched, mismatchLog) = makeServer()
        await mismatched.handle(LocalWorkerFrame(.hello(protocolVersion: LocalWorkerProtocol.version, role: wrongRole, session: "s0")))
        guard mismatchLog.exitCodes == [2], case .failed(_, nil, let mismatch)? = mismatchLog.events().first, mismatch.code == .protocolMismatch else { return false }

        // Happy path: ready, memory, unsupported command for this role, duplicate id, busy never reached, unknown cancel ignored.
        let (server, log) = makeServer()
        let memoryRequest = UUID(), wrongKind = UUID()
        await server.handle(LocalWorkerFrame(.hello(protocolVersion: LocalWorkerProtocol.version, role: role, session: "s1")))
        await server.handle(LocalWorkerFrame(.memory(request: memoryRequest)))
        await server.handle(LocalWorkerFrame(.memory(request: memoryRequest)))
        await server.handle(LocalWorkerFrame(.cancel(request: UUID())))
        if role == .inference {
            await server.handle(LocalWorkerFrame(.transcribe(request: wrongKind, modelIdentifier: "x", sampleCount: 1, language: "en"), payload: Data([0, 0])))
        } else {
            await server.handle(LocalWorkerFrame(.generate(request: wrongKind, modelIdentifier: "x", messages: [LocalChatMessage(role: .user, text: "hi")], parameters: LocalGenerationParameters(), hasImage: false)))
        }
        await settle()
        let events = log.events()
        guard events.count == 4, log.exitCodes.isEmpty else { return false }
        guard case .ready("s1", let readiness) = events[0], readiness.role == role, readiness.protocolVersion == LocalWorkerProtocol.version,
              readiness.supportedKinds == LocalModelKind.supported(by: role), readiness.runtime["worker"] == "1" else { return false }
        guard case .memory("s1", memoryRequest, let report) = events[1], report.physicalFootprintBytes > 0 else { return false }
        guard case .failed("s1", memoryRequest?, let duplicate) = events[2], duplicate.code == .duplicateRequest else { return false }
        guard case .failed("s1", wrongKind?, let unsupported) = events[3], unsupported.code == .unsupported else { return false }

        // Input limits are enforced before queueing.
        let (limits, limitLog) = makeServer()
        let oversized = UUID()
        await limits.handle(LocalWorkerFrame(.hello(protocolVersion: LocalWorkerProtocol.version, role: role, session: "s2")))
        if role == .inference {
            var parameters = LocalGenerationParameters()
            parameters.maximumTokens = LocalWorkerProtocol.maximumOutputTokens + 1
            await limits.handle(LocalWorkerFrame(.generate(request: oversized, modelIdentifier: "x", messages: [LocalChatMessage(role: .user, text: "hi")], parameters: parameters, hasImage: false)))
            await settle()
            guard case .failed("s2", oversized?, let tooLarge)? = limitLog.events().last, tooLarge.code == .inputTooLarge else { return false }
        }
        return true
    }
}
