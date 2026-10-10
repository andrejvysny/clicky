import ClickyCore
import Darwin
import Foundation
import MLX

enum WorkerMemory {
    /// Where `mlx.metallib` lives: next to the executable (development build), or in the app's
    /// `Contents/Resources` when the worker runs from `Contents/Helpers` — a code-signed Helpers directory may hold
    /// only signed code, so the bundle keeps the data file in Resources. Touching any MLX allocator or kernel
    /// without it makes MLX exit the process, so every MLX call is gated on this.
    static let metallibURL: URL? = {
        guard let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        return ["mlx.metallib", "Resources/mlx.metallib", "../Resources/mlx.metallib"]
            .map { directory.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    static var metallibAvailable: Bool { metallibURL != nil }

    /// phys_footprint and the lifetime peak come from the kernel ledger; MLX numbers come from MLX's allocator
    /// and exclude Core ML allocations (so Parakeet/Whisper show up only in the footprint).
    static func report(includeMLX: Bool) -> LocalMemoryReport {
        let mlx = includeMLX && metallibAvailable
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        let peak = status == KERN_SUCCESS ? UInt64(bitPattern: info.ledger_phys_footprint_peak) : nil
        return LocalMemoryReport(
            physicalFootprintBytes: footprint, peakPhysicalFootprintBytes: peak,
            mlxActiveBytes: mlx ? UInt64(max(0, Memory.activeMemory)) : nil, mlxPeakBytes: mlx ? UInt64(max(0, Memory.peakMemory)) : nil,
            mlxCacheBytes: mlx ? UInt64(max(0, Memory.cacheMemory)) : nil)
    }
}
