import Foundation

public enum PopupPlacement {
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
}
