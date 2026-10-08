import Foundation
// Darwin Foundation does not re-export CGRect geometry members to this module.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Screenshot pixel sizing that keeps model-returned coordinates accurate.
nonisolated public enum CaptureSizing {
    /// Claude downsizes larger images, which would shift returned coordinates, so we never send more than this.
    public static let maximumLongSide: CGFloat = 1568
    public static let maximumPixels: CGFloat = 1_150_000

    public static func pixelSize(forPointSize size: CGSize, backingScale: CGFloat) -> CGSize {
        let width = max(size.width, 1), height = max(size.height, 1)
        let ratio = min(max(1, backingScale), maximumLongSide / max(width, height), (maximumPixels / (width * height)).squareRoot())
        return CGSize(width: max(1, (width * ratio).rounded(.down)), height: max(1, (height * ratio).rounded(.down)))
    }
}

nonisolated public enum PointTarget: Equatable, Sendable {
    case point(x: Int, y: Int, label: String)
    case box(x: Int, y: Int, width: Int, height: Int, label: String)

    public var label: String {
        switch self {
        case .point(_, _, let label), .box(_, _, _, _, let label): return label
        }
    }
}

nonisolated public enum ScreenPointing {
    private static let tagPattern = try! NSRegularExpression(pattern: #"\[(POINT|BOX):([^\]\n]{1,120})\]"#)
    private static let tagStarts = ["[POINT:", "[BOX:"]

    public static func instruction(imageWidth: Int, imageHeight: Int) -> String {
        "Clicky screen pointing: the attached screenshot is \(imageWidth)×\(imageHeight) pixels with the origin at the top-left. If showing the user a specific on-screen element would help, end your reply with exactly one tag: [POINT:x,y:label] for a spot, or [BOX:x,y,width,height:label] for an element's bounds, using integer pixel coordinates in this screenshot and a 1-4 word label. If pointing would not help, end with [POINT:none]. Never mention or explain the tag."
    }

    public static func parse(_ reply: String) -> (text: String, target: PointTarget?) {
        let source = reply as NSString
        let matches = tagPattern.matches(in: reply, range: NSRange(location: 0, length: source.length))
        var target: PointTarget?
        for match in matches {
            let kind = source.substring(with: match.range(at: 1))
            let body = source.substring(with: match.range(at: 2))
            if let parsed = parseBody(kind: kind, body: body) { target = parsed.target }
        }
        var text = removingTags(from: reply)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (text, target)
    }

    public static func visibleStreamingText(_ partial: String) -> String {
        var text = removingTags(from: partial)
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "[") {
            let tail = text[open...]
            if !tail.contains("]"), tagStarts.contains(where: { $0.hasPrefix(tail) || tail.hasPrefix($0) }) {
                text = String(text[..<open])
                break
            }
            searchStart = text.index(after: open)
        }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    public static func screenRect(for target: PointTarget, imagePixelSize: CGSize, capturedRegion: CGRect) -> CGRect? {
        let width = imagePixelSize.width, height = imagePixelSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              capturedRegion.origin.x.isFinite, capturedRegion.origin.y.isFinite,
              capturedRegion.width.isFinite, capturedRegion.height.isFinite,
              capturedRegion.width > 0, capturedRegion.height > 0 else { return nil }
        let toleranceX = width * 0.02, toleranceY = height * 0.02
        func inside(_ x: Int, _ y: Int) -> Bool {
            CGFloat(x) >= -toleranceX && CGFloat(x) <= width + toleranceX && CGFloat(y) >= -toleranceY && CGFloat(y) <= height + toleranceY
        }
        func clamp(_ value: Int, _ upper: CGFloat) -> CGFloat { min(max(CGFloat(value), 0), upper) }
        let scaleX = capturedRegion.width / width, scaleY = capturedRegion.height / height
        switch target {
        case .point(let x, let y, _):
            guard inside(x, y) else { return nil }
            let centerX = capturedRegion.minX + clamp(x, width) * scaleX
            let centerY = capturedRegion.minY + clamp(y, height) * scaleY
            return CGRect(x: centerX - 22, y: centerY - 22, width: 44, height: 44)
        case .box(let x, let y, let boxWidth, let boxHeight, _):
            guard boxWidth > 0, boxHeight > 0, inside(x, y), inside(x + boxWidth, y + boxHeight) else { return nil }
            let minX = clamp(x, width), minY = clamp(y, height)
            let maxX = clamp(x + boxWidth, width), maxY = clamp(y + boxHeight, height)
            var rect = CGRect(x: capturedRegion.minX + minX * scaleX, y: capturedRegion.minY + minY * scaleY,
                              width: (maxX - minX) * scaleX, height: (maxY - minY) * scaleY)
            let expandedWidth = max(rect.width, 16), expandedHeight = max(rect.height, 16)
            rect = CGRect(x: rect.midX - expandedWidth / 2, y: rect.midY - expandedHeight / 2, width: expandedWidth, height: expandedHeight)
            let clipped = rect.intersection(capturedRegion)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
    }

    private static func removingTags(from text: String) -> String {
        tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    private static func parseBody(kind: String, body: String) -> (target: PointTarget?, valid: Bool)? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if kind == "POINT", trimmed == "none" { return (nil, true) }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ",", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        let rawLabel = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let label = String(rawLabel.prefix(40))
        let values = numbers.compactMap { $0 }
        guard values.count == numbers.count else { return nil }
        if kind == "POINT", values.count == 2 { return (.point(x: values[0], y: values[1], label: label), true) }
        if kind == "BOX", values.count == 4, values[2] > 0, values[3] > 0 {
            return (.box(x: values[0], y: values[1], width: values[2], height: values[3], label: label), true)
        }
        return nil
    }
}
