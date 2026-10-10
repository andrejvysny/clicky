import Darwin
import Foundation
#if canImport(ClickyCore)
// The SwiftPM native-test target compiles these app files against ClickyCore; the app compiles Core directly.
import ClickyCore
#endif

enum LocalMemoryPressure: String, Sendable { case normal, warning, critical }

/// Native effects the local AI runtime depends on. The app uses `.live`; native tests inject the fake worker,
/// a temporary models root and a controllable pressure stream.
struct LocalAIEnvironment {
    var workerExecutable: () -> URL?
    /// `onExit` is called once when the launched worker process ends, for any reason.
    var makeConnection: (URL, LocalWorkerRole, @escaping @Sendable (LocalWorkerExit) -> Void) -> LocalWorkerConnection
    var modelsRoot: URL
    var benchmarksRoot: URL
    var catalog: [LocalModelCatalogEntry]
    /// Monotonic seconds; drives idle unload only.
    var now: () -> TimeInterval
    var physicalMemory: UInt64
    var memoryPressure: () -> AsyncStream<LocalMemoryPressure>
    var thermalState: () -> ProcessInfo.ThermalState
    /// The host app's own phys_footprint in bytes.
    var hostFootprint: () -> UInt64
}

extension LocalAIEnvironment {
    static let applicationSupport: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Clicky", isDirectory: true)

    static let live = LocalAIEnvironment(
        workerExecutable: {
            #if DEBUG
            if let override = ProcessInfo.processInfo.environment["CLICKY_LOCAL_WORKER"], override.hasPrefix("/") {
                return URL(fileURLWithPath: override)
            }
            #endif
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clicky-local-worker")
            return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
        },
        makeConnection: { executable, role, onExit in
            LocalWorkerConnection(executable: executable, role: role,
                                  arguments: ["--role", role.rawValue, "--gpu-cache-mb", "512"],
                                  environment: ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()],
                                  cancelGrace: 3, onExit: onExit)
        },
        modelsRoot: applicationSupport.appendingPathComponent("Models", isDirectory: true),
        benchmarksRoot: applicationSupport.appendingPathComponent("Benchmarks", isDirectory: true),
        catalog: LocalModelCatalog.entries,
        now: { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
        physicalMemory: ProcessInfo.processInfo.physicalMemory,
        memoryPressure: { liveMemoryPressure() },
        thermalState: { ProcessInfo.processInfo.thermalState },
        hostFootprint: { currentPhysicalFootprint() })

    private static func liveMemoryPressure() -> AsyncStream<LocalMemoryPressure> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler {
                let event = source.data
                continuation.yield(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

/// task_info phys_footprint of this process: what Activity Monitor calls Memory.
func currentPhysicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
