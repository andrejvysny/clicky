import Foundation
// Darwin Foundation does not re-export CGRect geometry members to this module.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public enum PopupPlacement {
    public static func frame(pointer: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, size.width), visibleFrame.width)
        let height = min(max(1, size.height), visibleFrame.height)
        var origin = CGPoint(x: pointer.x + 18, y: pointer.y - height - 12)
        if origin.x + width > visibleFrame.maxX { origin.x = pointer.x - width - 18 }
        if origin.y < visibleFrame.minY { origin.y = pointer.y + 12 }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - height))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Ghost input beside the blue companion, matching the original companion bubble offset:
    /// the companion sits 35 pt right / 25 pt below the pointer and its bubbles start 10 pt right
    /// of it, vertically centered 18 pt lower. Flips left/above near display edges.
    public static func besideCompanion(pointer: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, size.width), visibleFrame.width)
        let height = min(max(1, size.height), visibleFrame.height)
        var origin = CGPoint(x: pointer.x + 45, y: pointer.y - 43 - height / 2)
        if origin.x + width > visibleFrame.maxX { origin.x = pointer.x - width - 18 }
        if origin.y < visibleFrame.minY { origin.y = pointer.y + 12 }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - height))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
