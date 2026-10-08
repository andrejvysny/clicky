import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

nonisolated public final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    // Darwin's waitUntilExit spins the caller's run loop and can miss the exit wakeup on
    // cooperative-pool threads; the termination handler always fires once the child exits.
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false
    private var inputClosed = false

    public init(executable: URL, arguments: [String], workingDirectory: String, environment: [String: String]? = nil,
                onExit: (@Sendable () -> Void)? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AskError.missingExecutable(executable.lastPathComponent) }
        var directoryExists: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &directoryExists), directoryExists.boolValue else { throw AskError.invalidDirectory }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [exited] _ in onExit?(); exited.signal() }
    }

    public func start() throws -> AsyncThrowingStream<JSONValue, Error> {
        lock.lock()
        do {
            guard !stopped else { throw CancellationError() }
            try process.run()
            lock.unlock()
        } catch { lock.unlock(); throw error }
        // Drain concurrently, without retaining or logging potentially sensitive provider output.
        Task.detached { [self] in
            while !errors.fileHandleForReading.availableData.isEmpty {}
        }
        return AsyncThrowingStream { continuation in
            let reader = Task.detached { [self] in
                do {
                    var framer = JSONLineFramer()
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        for message in try framer.append(chunk) { continuation.yield(message) }
                    }
                    for message in try framer.finish() { continuation.yield(message) }
                    waitForExit()
                    if !isStopped && process.terminationStatus != 0 { throw AskError.processFailed(process.terminationStatus) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { [weak self] _ in reader.cancel(); self?.stop() }
        }
    }

    public func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !inputClosed else { throw CancellationError() }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
    }

    // Blocks the detached reader exactly like its pipe reads; never called on the main actor.
    private func waitForExit() { exited.wait() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
        if process.isRunning {
            process.terminate()
            let runningProcess = process
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if runningProcess.isRunning { kill(runningProcess.processIdentifier, SIGKILL) }
            }
        }
        lock.unlock()
    }

    deinit { stop() }
}

nonisolated public final class ManagedAgentRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: AgentProcess?

    public init() {}

    public func cancel() {
        lock.lock()
        let process = activeProcess
        activeProcess = nil
        lock.unlock()
        process?.stop()
    }

    public func stream(provider: AgentProvider, executable: URL?, request: AskRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = AgentProcessCancellation()
            let task = Task.detached { [self] in
                var process: AgentProcess?
                do {
                    try Task.checkCancellation()
                    if provider == .preview {
                        continuation.yield(.status("Local preview — no AI request was made."))
                        continuation.yield(.textDelta("Quick Ask received your text:\n\n" + request.text))
                        if let image = request.image {
                            continuation.yield(.textDelta("\n\nImage attached: \(image.pixelWidth) × \(image.pixelHeight) pixels. Preview does not analyze images."))
                        }
                        continuation.yield(.completed)
                        continuation.finish()
                        return
                    }
                    guard let executable else { throw AskError.missingExecutable(provider.rawValue) }
                    let arguments = provider == .claude ? AgentProtocol.claudeArguments(session: request.session) : AgentProtocol.codexArguments()
                    let agentProcess = try AgentProcess(executable: executable, arguments: arguments, workingDirectory: request.workingDirectory)
                    process = agentProcess
                    cancellation.install(agentProcess)
                    try Task.checkCancellation()
                    try self.claim(agentProcess)
                    defer { self.release(agentProcess) }
                    let messages = try agentProcess.start()
                    let timeout = Task.detached {
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        if !Task.isCancelled { agentProcess.stop() }
                    }
                    defer { timeout.cancel(); agentProcess.stop() }
                    var codex = CodexConversation(request: request)
                    try agentProcess.send(provider == .claude ? AgentProtocol.claudePrompt(request.text, image: request.image) : codex.initialize)
                    if provider == .claude { agentProcess.closeInput() }
                    var streamedText = false
                    var completed = false
                    for try await message in messages {
                        try Task.checkCancellation()
                        let events: [AgentEvent]
                        if provider == .claude {
                            events = try AgentProtocol.claudeEvents(message, directory: request.workingDirectory, streamedText: streamedText)
                        } else {
                            let result = try codex.receive(message)
                            for outgoing in result.outgoing { try agentProcess.send(outgoing) }
                            events = result.events
                        }
                        for event in events {
                            if case .textDelta = event { streamedText = true }
                            if case .completed = event { completed = true }
                            continuation.yield(event)
                        }
                        if provider == .codex && completed { break }
                    }
                    guard completed else { throw AskError.incompleteTurn }
                    // Free the runner before finishing so an immediate next turn is not rejected as busy.
                    timeout.cancel()
                    agentProcess.stop()
                    self.release(agentProcess)
                    continuation.finish()
                } catch {
                    if let process { process.stop(); self.release(process) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel(); cancellation.cancel() }
        }
    }

    private func claim(_ process: AgentProcess) throws {
        lock.lock(); defer { lock.unlock() }
        guard activeProcess == nil else { throw AskError.busy }
        activeProcess = process
    }

    private func release(_ process: AgentProcess) {
        lock.lock(); defer { lock.unlock() }
        if activeProcess === process { activeProcess = nil }
    }
}

nonisolated final class AgentProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: AgentProcess?
    private var canceled = false

    func install(_ process: AgentProcess) {
        lock.lock()
        self.process = process
        let shouldStop = canceled
        lock.unlock()
        if shouldStop { process.stop() }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let process = process
        lock.unlock()
        process?.stop()
    }
}
