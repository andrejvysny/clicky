import Foundation

/// RGBA pixels of one comparison rectangle, decoded in memory for freshness checks and never persisted.
nonisolated public struct GuidePixels: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init?(width: Int, height: Int, rgba: Data) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// Appearance comparison for locating and the target guard: tolerates antialiasing, caret and subpixel noise
    /// but not a changed control. The rectangle is split into `tile`-pixel tiles; a pixel differs when any RGB
    /// channel moves more than `channel`, a tile differs when more than `fraction` of its pixels differ, and the
    /// images look alike only when no tile differs, so a small decisive change (a checkmark) is never diluted by
    /// a large rectangle. Never evidence of success; evidence acceptance stays exact.
    public func looksLike(_ other: GuidePixels, tile: Int = 12, channel: Int = 32, fraction: Double = 0.08) -> Bool {
        guard width == other.width, height == other.height else { return false }
        return rgba.withUnsafeBytes { mine in
            other.rgba.withUnsafeBytes { theirs in
                for tileY in stride(from: 0, to: height, by: tile) {
                    for tileX in stride(from: 0, to: width, by: tile) {
                        let maxX = min(tileX + tile, width), maxY = min(tileY + tile, height)
                        var differing = 0
                        for y in tileY..<maxY {
                            for x in tileX..<maxX {
                                let offset = (y * width + x) * 4
                                for channelOffset in 0..<3
                                where abs(Int(mine[offset + channelOffset]) - Int(theirs[offset + channelOffset])) > channel {
                                    differing += 1; break
                                }
                            }
                        }
                        if Double(differing) > fraction * Double((maxX - tileX) * (maxY - tileY)) { return false }
                    }
                }
                return true
            }
        }
    }
}
