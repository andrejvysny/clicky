import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

nonisolated public enum LocalWorkerExit: Equatable, Sendable {
    /// The host asked the worker to stop (shutdown or terminate).
    case requested
    /// The worker exited by itself with this status (or was killed by this signal).
    case crashed(Int32)
    /// The worker ignored a cancel or the handshake past its deadline and was killed.
    case unresponsive
    case protocolViolation(String)
}

/// Host side of one local worker process. One launch, one session nonce, one ledger: nothing is restarted or
/// replayed automatically, and every request ends exactly once (terminal event, or `.workerUnavailable`).
nonisolated public final class LocalWorkerConnection: @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<LocalWorkerEvent, Error>.Continuation

    private let executable: URL
    private let role: LocalWorkerRole
    private let arguments: [String]
    private let environment: [String: String]
    private let handshakeTimeout: TimeInterval
    private let cancelGrace: TimeInterval
    private let onExit: (@Sendable (LocalWorkerExit) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    /// Guards all mutable state below. Never held across a pipe write or a continuation callback.
    private let lock = NSLock()
    /// Serializes frame writes; separate from `lock` so a write blocked on a full pipe cannot stall the reader.
    private let writeLock = NSLock()
    private let session = UUID().uuidString
    private var ledger: LocalWorkerLedger
    private var continuations: [UUID: Continuation] = [:]
    private var readyWaiter: CheckedContinuation<LocalWorkerReadiness, Error>?
    private var started = false
    private var running = false
    private var stopping = false
    private var exitHandled = false
    private var pendingReason: LocalWorkerExit?
    private var terminationStatus: Int32 = 0
    private var storedReadiness: LocalWorkerReadiness?
    private var inputClosed = false
    /// Requests the host canceled or abandoned that have not yet shown a terminal event; the grace timer watches them.
    private var awaitingTerminal: Set<UUID> = []

    private let tailLock = NSLock()
    private var tail = Data()
    private static let tailLimit = 4096
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(executable: URL, role: LocalWorkerRole, arguments: [String] = [], environment: [String: String],
                handshakeTimeout: TimeInterval = 15, cancelGrace: TimeInterval = 3,
                onExit: (@Sendable (LocalWorkerExit) -> Void)? = nil) {
        self.executable = executable
        self.role = role
        self.arguments = arguments
        self.environment = environment
        self.handshakeTimeout = handshakeTimeout
        self.cancelGrace = cancelGrace
        self.onExit = onExit
        self.ledger = LocalWorkerLedger(session: session)
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running && !exitHandled }
    public var readiness: LocalWorkerReadiness? { lock.lock(); defer { lock.unlock() }; return storedReadiness }

    /// Last 4 KiB of worker stderr; held in memory only and never logged.
    public var diagnosticTail: String {
        tailLock.lock(); defer { tailLock.unlock() }
        return String(decoding: tail, as: UTF8.self)
    }

    // MARK: Launch and handshake

    public func start() async throws -> LocalWorkerReadiness {
        _ = Self.ignoreBrokenPipe
        let result = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<LocalWorkerReadiness, Error>) in
            lock.lock()
            guard !started else {
                lock.unlock()
                waiter.resume(throwing: LocalWorkerError(.workerUnavailable, "Worker connection was already started."))
                return
            }
            started = true
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                exitHandled = true
                lock.unlock()
                waiter.resume(throwing: LocalWorkerError(.workerUnavailable, "Worker executable is missing."))
                return
            }
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { [weak self] finished in
                self?.recordTermination(finished.terminationStatus)
            }
            do { try process.run() } catch {
                exitHandled = true
                lock.unlock()
                waiter.resume(throwing: LocalWorkerError(.workerUnavailable, "Worker could not be launched."))
                return
            }
            running = true
            readyWaiter = waiter
            lock.unlock()
            Thread.detachNewThread { [self] in drainErrors() }
            Thread.detachNewThread { [self] in readLoop() }
            do { try write(.hello(protocolVersion: LocalWorkerProtocol.version, role: role, session: session)) }
            catch { failHandshake(LocalWorkerError(.workerUnavailable, "Worker closed its input."), reason: .crashed(0)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                self?.failHandshake(LocalWorkerError(.timedOut, "Worker did not become ready."), reason: .unresponsive)
            }
        }
        return result
    }

    private func resolveReady(_ result: Result<LocalWorkerReadiness, Error>) {
        lock.lock()
        let waiter = readyWaiter
        readyWaiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    /// Fails a still-pending handshake and stops the worker; a no-op once the handshake finished.
    private func failHandshake(_ error: LocalWorkerError, reason: LocalWorkerExit) {
        lock.lock()
        let pending = readyWaiter != nil
        lock.unlock()
        guard pending else { return }
        resolveReady(.failure(error))
        stop(reason)
    }

    // MARK: Requests

    /// Payload writes are synchronous (up to 16 MiB into the pipe): callers on the main actor must invoke this from
    /// a detached task.
    public func request(_ command: LocalWorkerCommand, payload: Data = Data()) -> AsyncThrowingStream<LocalWorkerEvent, Error> {
        guard let id = Self.requestIdentifier(command) else {
            return Self.failedStream(LocalWorkerError(.invalidMessage, "Command does not start a request."))
        }
        return AsyncThrowingStream { continuation in
            lock.lock()
            guard running, !stopping, !exitHandled, readyWaiter == nil, storedReadiness != nil else {
                lock.unlock()
                continuation.finish(throwing: LocalWorkerError(.workerUnavailable, "Worker is not running."))
                return
            }
            guard ledger.register(id) else {
                lock.unlock()
                continuation.finish(throwing: LocalWorkerError(.duplicateRequest, "Request id was already used."))
                return
            }
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.consumerLeft(id) }
            do { try write(command, payload: payload) } catch {
                lock.lock()
                let owned = continuations.removeValue(forKey: id) != nil
                if owned { ledger.abandon(id) }
                lock.unlock()
                if owned { continuation.finish(throwing: error) }
            }
        }
    }

    /// The consumer stopped listening before a terminal event: tell the worker, ignore its late output, and
    /// require it to finish the request within the cancel grace.
    private func consumerLeft(_ id: UUID) {
        lock.lock()
        let owned = continuations.removeValue(forKey: id) != nil
        if owned { ledger.abandon(id); awaitingTerminal.insert(id) }
        lock.unlock()
        guard owned else { return }
        try? write(.cancel(request: id))
        armGraceTimer(id)
    }

    public func cancel(_ request: UUID) {
        lock.lock()
        let eligible = continuations[request] != nil && !awaitingTerminal.contains(request)
        if eligible { awaitingTerminal.insert(request) }
        lock.unlock()
        guard eligible else { return }
        try? write(.cancel(request: request))
        armGraceTimer(request)
    }

    private func armGraceTimer(_ id: UUID) {
        DispatchQueue.global().asyncAfter(deadline: .now() + cancelGrace) { [weak self] in
            guard let self else { return }
            lock.lock()
            let stillAwaiting = awaitingTerminal.contains(id)
            lock.unlock()
            if stillAwaiting { stop(.unresponsive) }
        }
    }

    private static func requestIdentifier(_ command: LocalWorkerCommand) -> UUID? {
        switch command {
        case .load(let id, _, _), .unload(let id, _), .generate(let id, _, _, _, _), .transcribe(let id, _, _, _),
             .clearCaches(let id), .memory(let id):
            return id
        case .hello, .cancel, .shutdown:
            return nil
        }
    }

    private static func failedStream(_ error: Error) -> AsyncThrowingStream<LocalWorkerEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    // MARK: Stopping

    public func shutdown() {
        lock.lock()
        guard running, !stopping, !exitHandled else { lock.unlock(); return }
        stopping = true
        if pendingReason == nil { pendingReason = .requested }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.forceTerminateIfRunning() }
        writeLock.lock()
        if let data = try? LocalWorkerFrame(LocalWorkerCommand.shutdown).encoded() { try? input.fileHandleForWriting.write(contentsOf: data) }
        closeInputLocked()
        writeLock.unlock()
    }

    public func terminate() { stop(.requested) }

    /// SIGTERM now, SIGKILL after one second. The first recorded reason wins.
    private func stop(_ reason: LocalWorkerExit) {
        lock.lock()
        if pendingReason == nil { pendingReason = reason }
        stopping = true
        let live = running && !exitHandled
        lock.unlock()
        guard live else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.kill9IfRunning() }
    }

    private func forceTerminateIfRunning() {
        lock.lock()
        let live = running && !exitHandled
        lock.unlock()
        if live {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.kill9IfRunning() }
        }
    }

    private func kill9IfRunning() {
        lock.lock()
        let live = running && !exitHandled
        lock.unlock()
        if live { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: Pipes

    private func write(_ command: LocalWorkerCommand, payload: Data = Data()) throws {
        let data = try LocalWorkerFrame(command, payload: payload).encoded()
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { throw LocalWorkerError(.workerUnavailable, "Worker input is closed.") }
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw LocalWorkerError(.workerUnavailable, "Worker input is closed.") }
    }

    private func closeInputLocked() {
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
    }

    private func drainErrors() {
        while true {
            let chunk = errors.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            tailLock.lock()
            tail.append(chunk)
            if tail.count > Self.tailLimit { tail = Data(tail.suffix(Self.tailLimit)) }
            tailLock.unlock()
        }
    }

    private func recordTermination(_ status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
        exited.signal()
    }

    // MARK: Reader

    private func readLoop() {
        var framer = LocalWorkerFramer<LocalWorkerEvent>()
        var handshakeDone = false
        readLoop: while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                if framer.hasPartialFrame { stop(.protocolViolation("Truncated frame.")) }
                break
            }
            let frames: [LocalWorkerFrame<LocalWorkerEvent>]
            do { frames = try framer.append(chunk) } catch {
                failHandshake(LocalWorkerError(.protocolMismatch, "Malformed worker output."), reason: .protocolViolation("Malformed frame."))
                stop(.protocolViolation("Malformed frame."))
                break
            }
            for frame in frames {
                if !handshakeDone {
                    guard acceptReady(frame.message) else { break readLoop }
                    handshakeDone = true
                } else if !dispatch(frame.message) {
                    break readLoop
                }
            }
        }
        // EOF normally means exit; give the exit notification a moment, then force it.
        if exited.wait(timeout: .now() + 1) == .timedOut {
            stop(.protocolViolation("Worker closed its output."))
            exited.wait()
        }
        finishExit()
    }

    private func acceptReady(_ event: LocalWorkerEvent) -> Bool {
        guard case .ready(let session, let readiness) = event, session == self.session else {
            failHandshake(LocalWorkerError(.protocolMismatch, "Worker did not send a valid ready event."),
                          reason: .protocolViolation("Invalid handshake."))
            return false
        }
        guard readiness.protocolVersion == LocalWorkerProtocol.version, readiness.role == role else {
            failHandshake(LocalWorkerError(.protocolMismatch, "Worker protocol version or role differs."),
                          reason: .protocolViolation("Protocol mismatch."))
            return false
        }
        lock.lock()
        storedReadiness = readiness
        lock.unlock()
        resolveReady(.success(readiness))
        return true
    }

    /// Returns false when the connection was stopped for a violation.
    private func dispatch(_ event: LocalWorkerEvent) -> Bool {
        lock.lock()
        let disposition = ledger.classify(event)
        var continuation: Continuation?
        switch disposition {
        case .stale:
            if event.isTerminal, let request = event.request { awaitingTerminal.remove(request) }
            lock.unlock()
            return true
        case .violation(let message):
            lock.unlock()
            stop(.protocolViolation(message))
            return false
        case .deliver(let terminal):
            guard let request = event.request else {
                lock.unlock()
                stop(.protocolViolation("Worker reported a connection-level failure."))
                return false
            }
            if terminal { awaitingTerminal.remove(request) }
            continuation = terminal ? continuations.removeValue(forKey: request) : continuations[request]
            lock.unlock()
        }
        guard let continuation else { return true }
        switch event {
        case .failed(_, _, let error): continuation.finish(throwing: error)
        case .canceled: continuation.finish(throwing: CancellationError())
        case .completed, .memory: continuation.yield(event); continuation.finish()
        default: continuation.yield(event)
        }
        return true
    }

    /// Runs once, after the pipe is drained and the process has exited: fails whatever is still pending.
    private func finishExit() {
        lock.lock()
        guard !exitHandled else { lock.unlock(); return }
        exitHandled = true
        running = false
        let reason = pendingReason ?? .crashed(terminationStatus)
        _ = ledger.failAll()
        let orphans = continuations
        continuations.removeAll()
        awaitingTerminal.removeAll()
        lock.unlock()
        writeLock.lock(); closeInputLocked(); writeLock.unlock()
        resolveReady(.failure(LocalWorkerError(.workerUnavailable, "Worker exited before it was ready.")))
        for continuation in orphans.values {
            continuation.finish(throwing: LocalWorkerError(.workerUnavailable, "Worker exited."))
        }
        onExit?(reason)
    }

    deinit { if process.isRunning { process.terminate() } }
}
