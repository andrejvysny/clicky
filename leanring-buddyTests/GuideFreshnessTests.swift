import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Clicky

@MainActor
struct GuideFreshnessTests {
    @Test func changeOutsideOutcomeRegionPreservesEvidenceButChangesWholeImage() throws {
        let controller = VisualGuideController()
        let original = try image()
        let changed = try image(changedPixel: CGPoint(x: 0, y: 0))
        try #require(original.data != changed.data)
        let evidence = CGRect(x: 2, y: 2, width: 4, height: 4)
        let originalEvidence = try #require(controller.fingerprint(original, rect: evidence))
        let changedEvidence = try #require(controller.fingerprint(changed, rect: evidence))
        #expect(originalEvidence == changedEvidence)
        let fullImage = CGRect(x: 0, y: 0, width: 8, height: 8)
        let originalFullImage = try #require(controller.fingerprint(original, rect: fullImage))
        let changedFullImage = try #require(controller.fingerprint(changed, rect: fullImage))
        #expect(originalFullImage != changedFullImage)
    }

    @Test func changeInsideOutcomeRegionInvalidatesExactFingerprint() throws {
        let controller = VisualGuideController()
        let original = try image()
        let changed = try image(changedPixel: CGPoint(x: 3, y: 3))
        try #require(original.data != changed.data)
        let evidence = CGRect(x: 2, y: 2, width: 4, height: 4)
        let originalEvidence = try #require(controller.fingerprint(original, rect: evidence))
        let changedEvidence = try #require(controller.fingerprint(changed, rect: evidence))
        #expect(originalEvidence != changedEvidence)
    }

    @Test func fractionalEvidenceIncludesItsIntegralBorderPixels() throws {
        let controller = VisualGuideController()
        let original = try image()
        let changed = try image(changedPixel: CGPoint(x: 2, y: 3))
        try #require(original.data != changed.data)
        let target = GuideRect(CGRect(x: 2.5, y: 2.5, width: 3, height: 3))
        let evidence = try #require(GuidePixelMapping.evidenceComparisonRect(target, pixelWidth: 8, pixelHeight: 8))
        #expect(evidence == CGRect(x: 2, y: 2, width: 4, height: 4))
        let originalEvidence = try #require(controller.fingerprint(original, rect: evidence))
        let changedEvidence = try #require(controller.fingerprint(changed, rect: evidence))
        #expect(originalEvidence != changedEvidence)
    }

    private func image(changedPixel: CGPoint? = nil) throws -> PNGImageAttachment {
        // Explicit opaque pixels avoid NSBitmapImageRep color conversion silently producing transparent zeros.
        var pixels = [UInt8](repeating: 255, count: 8 * 8 * 4)
        if let changedPixel {
            let offset = (Int(changedPixel.y) * 8 + Int(changedPixel.x)) * 4
            for channel in 0..<3 { pixels[offset + channel] = 0 }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let bitmap = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil)
        try #require(CGImageDestinationFinalize(destination))
        return try PNGImageAttachment(data: png as Data, displayName: "Synthetic outcome evidence",
                                      capturedRegion: CGRect(x: -40, y: 120, width: 16, height: 16))
    }
}
