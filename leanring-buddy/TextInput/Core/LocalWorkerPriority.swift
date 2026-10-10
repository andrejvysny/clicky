import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Worker scheduling class for contention tests. CPU scheduling only: GPU/ANE fairness is not implied.
nonisolated public enum LocalWorkerPriority: String, Sendable, CaseIterable {
    case foregroundProtected = "foreground-protected"
    case standard = "default"

    /// Sets the process nice value (10 or 0). False when the system refuses (e.g. lowering nice without privilege).
    public func apply(to pid: Int32) -> Bool {
        let nice: Int32 = self == .foregroundProtected ? 10 : 0
        #if canImport(Darwin)
        return setpriority(PRIO_PROCESS, id_t(pid), nice) == 0
        #else
        return setpriority(__priority_which_t(PRIO_PROCESS.rawValue), id_t(pid), nice) == 0
        #endif
    }
}
