import ClickyCore
import Foundation

/// Command-line options. The host launches the worker directly, so parsing is strict: anything unknown is fatal.
struct WorkerOptions {
    var role: LocalWorkerRole
    var gpuCacheMegabytes = 512
    var memoryLimitMegabytes: Int?
    var sandbox = true
    var selfTest = false

    static let usage = "usage: clicky-local-worker --role inference|speech [--gpu-cache-mb N] [--memory-limit-mb N] [--no-sandbox] [--self-test]"

    static func parse(_ arguments: [String]) -> WorkerOptions? {
        var role: LocalWorkerRole?
        var options = WorkerOptions(role: .inference)
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--role":
                guard let raw = value(), let parsed = LocalWorkerRole(rawValue: raw) else { return nil }
                role = parsed
            case "--gpu-cache-mb":
                guard let raw = value(), let number = Int(raw), number >= 0 else { return nil }
                options.gpuCacheMegabytes = number
            case "--memory-limit-mb":
                guard let raw = value(), let number = Int(raw), number > 0 else { return nil }
                options.memoryLimitMegabytes = number
            case "--no-sandbox": options.sandbox = false
            case "--self-test": options.selfTest = true
            default: return nil
            }
            index += 1
        }
        guard let role else { return nil }
        options.role = role
        return options
    }
}

