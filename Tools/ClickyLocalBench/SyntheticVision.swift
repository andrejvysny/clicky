#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
import ClickyCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic synthetic screenshots: no binary fixtures live in Git, the seed fixes layout, labels and colors.
enum SyntheticVision {
    static let width = 1280, height = 800
    static let labels = ["Save", "Cancel", "Open", "Export", "Share", "Delete", "Search", "Settings", "Refresh", "Upload"]

    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    struct Button { let label: String; let rect: CGRect; let hue: CGFloat }

    static func cases(count: Int, seed: UInt64) throws -> [LocalGenerationCase] {
        try (0..<count).map { index in
            var generator = Generator(state: seed &+ UInt64(index) &* 7919)
            let buttons = layout(&generator)
            let target = buttons[generator.int(0...(buttons.count - 1))]
            let png = try render(buttons)
            let question = "Find the button labeled \"\(target.label)\". " + LocalGrounding.instruction(label: target.label)
            let box = LocalVisionBox(label: target.label, x: target.rect.minX, y: target.rect.minY, width: target.rect.width, height: target.rect.height)
            return LocalGenerationCase(id: "synthetic-\(seed)-\(index)", messages: [
                LocalChatMessage(role: .system, text: "You locate user-interface elements in screenshots and answer with JSON only."),
                LocalChatMessage(role: .user, text: question)], image: png, expectedBox: box, imageWidth: width, imageHeight: height)
        }
    }

    static func layout(_ generator: inout Generator) -> [Button] {
        let total = generator.int(3...5)
        var names = labels
        var buttons: [Button] = []
        var attempts = 0
        while buttons.count < total, attempts < 500 {
            attempts += 1
            let buttonWidth = generator.int(140...220), buttonHeight = generator.int(48...72)
            let rect = CGRect(x: generator.int(40...(width - buttonWidth - 40)), y: generator.int(60...(height - buttonHeight - 40)),
                              width: buttonWidth, height: buttonHeight)
            if buttons.contains(where: { $0.rect.insetBy(dx: -24, dy: -24).intersects(rect) }) { continue }
            let label = names.remove(at: generator.int(0...(names.count - 1)))
            buttons.append(Button(label: label, rect: rect, hue: CGFloat(generator.int(0...359)) / 360))
        }
        return buttons
    }

    static func render(_ buttons: [Button]) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CLIError("Could not create a bitmap context.")
        }
        // Flip to a top-left origin so rectangles match the coordinates the model is asked for.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
        for button in buttons {
            let color = platformColor(hue: button.hue)
            context.setFillColor(color)
            context.fill(button.rect)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, button.label as CFString, attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: button.rect.midX - bounds.width / 2, y: button.rect.midY + bounds.height / 3)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw CLIError("Could not render the fixture.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CLIError("PNG encoder unavailable.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CLIError("PNG encoding failed.") }
        return data as Data
    }

    /// Dark enough for white labels: fixed saturation and brightness, seeded hue.
    private static func platformColor(hue: CGFloat) -> CGColor {
        let c: CGFloat = 0.55 * 0.8, h = hue * 6
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m: CGFloat = 0.55 - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
#endif
