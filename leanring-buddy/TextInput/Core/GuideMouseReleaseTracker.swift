import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Some native global mouse-up events omit clickCount; only a scoped matching press may supply it.
nonisolated public struct GuideMouseReleaseTracker: Sendable {
    private struct Press: Sendable {
        let button: Int
        let count: Int
        let timestamp: Double
    }

    public let target: CGRect
    private var press: Press?
    public var pressedButton: Int? { press?.button }

    public init(target: CGRect) { self.target = target }

    @discardableResult
    public mutating func began(button: Int, count: Int, point: CGPoint, timestamp: Double) -> Bool {
        cancel()
        guard button == 0 || button == 1, count > 0, timestamp.isFinite,
              point.x.isFinite, point.y.isFinite, target.contains(point) else { return false }
        press = Press(button: button, count: count, timestamp: timestamp)
        return true
    }

    public mutating func released(button: Int, count: Int, point: CGPoint, timestamp: Double) -> Int? {
        defer { cancel() }
        guard let press, press.button == button, count >= 0, timestamp.isFinite,
              timestamp > press.timestamp, point.x.isFinite, point.y.isFinite,
              target.contains(point) else { return nil }
        if count == 0 { return press.count }
        return count == press.count ? count : nil
    }

    /// A drag, scope change or stopped observer cannot contribute a later click release.
    public mutating func cancel() { press = nil }
}
