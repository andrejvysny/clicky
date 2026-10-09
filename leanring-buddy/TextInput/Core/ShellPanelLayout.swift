import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated public enum ShellPanelLayout {
    public static func isValid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy { $0.isFinite }
            && frame.size.width > 0 && frame.size.height > 0
    }

    public static func height(measured: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, measured.isFinite && measured > 0 ? measured : minimum))
    }

    /// Limit growth to the room below the original top, keeping the composer stationary.
    public static func anchoredFrame(_ frame: CGRect, top: CGFloat, visibleFrame: CGRect) -> CGRect {
        let top = min(visibleFrame.maxY, max(visibleFrame.minY + 1, top))
        let height = min(frame.height, top - visibleFrame.minY)
        return CGRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}
