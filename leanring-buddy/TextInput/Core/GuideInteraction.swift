import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public struct GuideInteractionMatcher: Sendable {
    public let action: GuideAction
    public let target: CGRect
    private var lastTimestamp: Double = -.infinity
    public init(action: GuideAction, target: CGRect) { self.action = action; self.target = target }
    public mutating func mouse(button: Int, count: Int, point: CGPoint, timestamp: Double) -> Bool {
        guard timestamp > lastTimestamp, target.contains(point) else { return false }
        let matches: Bool
        switch action.kind {
        case .click: matches = button == 0 && count == 1
        case .right_click: matches = button == 1 && count == 1
        case .double_click: matches = button == 0 && count == 2
        default: matches = false
        }
        if matches { lastTimestamp = timestamp }
        return matches
    }
    public mutating func key(code: UInt16, modifiers: UInt64, timestamp: Double, repeated: Bool) -> Bool {
        guard !repeated, timestamp > lastTimestamp, action.kind == .key || action.kind == .field_commit,
              code == action.keyCode, modifiers == action.modifiers else { return false }
        lastTimestamp = timestamp; return true
    }
}
