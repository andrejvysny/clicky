import Foundation

/// Content-free counters and latency samples for walkthrough cost and responsiveness.
/// Never holds prompts, replies, screenshots, AX values or keystrokes.
nonisolated public struct GuideMetrics: Equatable, Sendable {
    public enum Counter: String, CaseIterable, Sendable {
        case attempts, captures, providerTurns, localConfirmations, visionChecks, appWaits
        case relocations, recoveries, goalChecks, uncertainties, manualAcknowledgements
    }
    public enum Latency: String, CaseIterable, Sendable { case firstInstruction, acknowledgement, verification, nextStep, cancellation }

    public private(set) var counts: [Counter: Int] = [:]
    private var samples: [Latency: [Double]] = [:]
    static let sampleLimit = 512

    public init() {}

    public mutating func count(_ counter: Counter) { counts[counter, default: 0] += 1 }
    public subscript(_ counter: Counter) -> Int { counts[counter] ?? 0 }

    public mutating func sample(_ latency: Latency, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var values = samples[latency] ?? []
        if values.count >= Self.sampleLimit { values.removeFirst() }
        values.append(seconds); samples[latency] = values
    }

    /// Nearest-rank percentile, e.g. 0.5 or 0.95; nil without samples.
    public func percentile(_ latency: Latency, _ fraction: Double) -> Double? {
        guard let values = samples[latency]?.sorted(), !values.isEmpty else { return nil }
        let rank = Int((fraction * Double(values.count)).rounded(.up))
        return values[min(max(rank, 1), values.count) - 1]
    }

    /// One line of counts and P50/P95 milliseconds for unified logging or test output.
    public var summary: String {
        let counted = Counter.allCases.map { "\($0.rawValue)=\(self[$0])" }
        let timed = Latency.allCases.compactMap { latency -> String? in
            guard let p50 = percentile(latency, 0.5), let p95 = percentile(latency, 0.95) else { return nil }
            return "\(latency.rawValue)_ms=\(Int(p50 * 1000))/\(Int(p95 * 1000))"
        }
        return (counted + timed).joined(separator: " ")
    }
}
