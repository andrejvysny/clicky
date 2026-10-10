import ClickyCore
import Foundation

/// The only writer of stdout. Everything else the worker says goes to `Diagnostics` (stderr).
final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: (Data) -> Bool

    /// Default sink writes whole frames to file descriptor 1 and reports failure (e.g. the host closed the pipe).
    init(sink: @escaping (Data) -> Bool = WorkerOutput.writeToStandardOutput) { self.sink = sink }

    /// Returns false when the frame could not be encoded (over the protocol limit) or written.
    @discardableResult
    func send(_ event: LocalWorkerEvent) -> Bool {
        guard let data = try? LocalWorkerFrame(event).encoded() else { return false }
        lock.lock(); defer { lock.unlock() }
        return sink(data)
    }

    static func writeToStandardOutput(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(1, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Content-free stderr lines: lifecycle and error categories only; never prompts, transcripts, or user file paths.
enum Diagnostics {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("clicky-local-worker: " + message + "\n").utf8))
    }
}

/// Cooperative cancellation shared between the server and a running engine call.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
