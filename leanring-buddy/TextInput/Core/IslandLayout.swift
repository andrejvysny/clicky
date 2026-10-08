import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry of the notch-anchored island, in AppKit (bottom-left origin) points.
nonisolated public enum IslandLayout {
    /// Each wing beside the notch.
    public static let wingWidth: CGFloat = 60
    /// Width of the black tab on displays without a notch.
    public static let tabWidth: CGFloat = 120
    public static let replyWidth: CGFloat = 420
    public static let askWidth: CGFloat = 460

    /// Compact footprint: 60 pt wings around the notch, or a 120 pt tab without one.
    public static func compactWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth > 0 ? notchWidth + 2 * wingWidth : tabWidth
    }

    /// Gap kept empty in the header row so nothing is drawn under the camera housing.
    public static func centerGap(notchWidth: CGFloat) -> CGFloat {
        notchWidth > 0 ? notchWidth : 10
    }

    /// Top-centered frame hanging from the top edge of `screen`, never wider than the screen.
    public static func frame(screen: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let clampedWidth = min(width, screen.width)
        return CGRect(x: (screen.midX - clampedWidth / 2).rounded(), y: screen.maxY - height,
                      width: clampedWidth, height: height)
    }
}
