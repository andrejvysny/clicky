import CSandbox
import ClickyCore
import Foundation
import Metal
import MLX

// Entry point: sandbox first, then serve the private wire protocol on stdin/stdout until EOF or the host dies.
// stdout carries frames only; stderr carries content-free diagnostics.

setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

guard let options = WorkerOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
    Diagnostics.log(WorkerOptions.usage)
    _exit(64)
}

// The worker never needs the network: models are local files verified by the host.
var networkDenied = false
if options.sandbox {
    var sandboxError: UnsafeMutablePointer<CChar>?
    if clicky_deny_network(&sandboxError) == 0 {
        networkDenied = true
    } else {
        Diagnostics.log("network sandbox unavailable")
        clicky_sandbox_free_error(sandboxError)
    }
}

if options.role == .inference, let metallib = WorkerMemory.metallibURL {
    // Explicit path before the first MLX call, so the bundle's Resources copy is found too.
    GPU.metallib = metallib
    Memory.cacheLimit = options.gpuCacheMegabytes * 1024 * 1024
    if let limit = options.memoryLimitMegabytes { Memory.memoryLimit = limit * 1024 * 1024 }
}

let metalDeviceName = MTLCreateSystemDefaultDevice()?.name
let workerOutput = WorkerOutput(sink: { data in
    if WorkerOutput.writeToStandardOutput(data) { return true }
    _exit(1) // The host closed the pipe: nobody is left to serve.
})

if options.selfTest {
    Task {
        let passed = await SelfTest.run(role: options.role, networkDenied: networkDenied, metalDevice: metalDeviceName)
        Diagnostics.log(passed ? "ok" : "self-test failed")
        _exit(passed ? 0 : 1)
    }
    dispatchMain()
}

let server = WorkerServer(role: options.role, output: workerOutput, networkDenied: networkDenied, metalDevice: metalDeviceName, terminate: { _exit($0) })
let (commandStream, commandContinuation) = AsyncStream.makeStream(of: LocalWorkerFrame<LocalWorkerCommand>.self)

// Blocking reader on its own thread; frames reach the actor in arrival order through the stream.
Thread.detachNewThread {
    var framer = LocalWorkerFramer<LocalWorkerCommand>()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty {
            if framer.hasPartialFrame { Task { await server.connectionFailed(LocalWorkerError(.invalidMessage, "Truncated frame."), exit: 65) } }
            else { commandContinuation.finish() }
            return
        }
        do {
            for frame in try framer.append(chunk) { commandContinuation.yield(frame) }
        } catch let error as LocalWorkerError {
            Task { await server.connectionFailed(error, exit: 65) }
            return
        } catch {
            Task { await server.connectionFailed(LocalWorkerError(.invalidMessage, "Undecodable frame."), exit: 65) }
            return
        }
    }
}

// Never outlive the host: a reparented process (launchd adopts orphans) exits within two seconds.
let originalParent = getppid()
Thread.detachNewThread {
    while true {
        sleep(2)
        let parent = getppid()
        if parent == 1 || parent != originalParent { _exit(0) }
    }
}

Task {
    for await frame in commandStream { await server.handle(frame) }
    await server.shutdown() // stdin reached EOF
}

dispatchMain()
