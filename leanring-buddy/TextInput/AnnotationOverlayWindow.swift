// Window setup and per-display geometry adapted from adammcarter/annotate, MIT License (see THIRD_PARTY_NOTICES.md).
import AppKit
import QuartzCore

/// Global top-left Core Graphics points <-> AppKit screens.
@MainActor
enum AnnotationScreens {
    /// The primary display's height anchors the flip between AppKit (y-up) and global top-left (y-down).
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    static func topLeftFrame(of screen: NSScreen) -> CGRect {
        flip(screen.frame)
    }

    static func topLeftVisibleFrame(of screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) }
    }

    /// Display under a global top-left point, falling back to the first display the rect touches.
    static func home(for target: CGRect) -> NSScreen? {
        let center = CGPoint(x: target.midX, y: target.midY)
        return NSScreen.screens.first { topLeftFrame(of: $0).contains(center) }
            ?? NSScreen.screens.first { topLeftFrame(of: $0).intersects(target) }
    }

    /// Window-local AppKit rect (y-up) for a global top-left rect shown on `screen`.
    static func localRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let frame = topLeftFrame(of: screen)
        return CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func flip(_ appKitRect: CGRect) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryHeight - appKitRect.maxY, width: appKitRect.width, height: appKitRect.height)
    }
}

/// One borderless, transparent panel per display. Every property keeps it invisible to input and window
/// management so an annotation never interrupts the work it annotates.
final class AnnotationOverlayWindow: NSPanel {
    let canvasView: AnnotationCanvasView

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        canvasView = AnnotationCanvasView(frame: NSRect(origin: .zero, size: contentRect.size))
        super.init(contentRect: contentRect, styleMask: styleMask, backing: bufferingType, defer: flag)
        // Above open menus so a mark on a menu item is not hidden by the menu.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        canvasView.autoresizingMask = [.width, .height]
        contentView = canvasView
        orderOut(nil)
    }

    convenience init(screen: NSScreen) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-backed transparent canvas; mark layers and label views are its children.
final class AnnotationCanvasView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func clear() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.removeAllAnimations()
        layer?.opacity = 1
        subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Label card and value pill views, sized before placement.
@MainActor
enum AnnotationLabelViews {
    static let maxLabelWidth: CGFloat = 260
    private static let cardPadding = NSSize(width: 12, height: 8)

    static func card(text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold).rounded()
        field.textColor = .white
        field.maximumNumberOfLines = 3
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = false
        let textWidth = maxLabelWidth - cardPadding.width * 2
        field.preferredMaxLayoutWidth = textWidth
        let fit = field.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        let textSize = NSSize(width: min(ceil(fit.width), textWidth), height: ceil(fit.height))

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: textSize.width + cardPadding.width * 2,
                                                    height: textSize.height + cardPadding.height * 2))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        field.frame = NSRect(origin: NSPoint(x: cardPadding.width, y: cardPadding.height), size: textSize)
        card.addSubview(field)
        return card
    }

    static func pill(text: String, color: NSColor) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingMiddle
        let width = min(ceil(field.intrinsicContentSize.width), maxLabelWidth - 20)
        let height = ceil(field.intrinsicContentSize.height)
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: width + 20, height: height + 8))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = color.cgColor
        pill.layer?.cornerRadius = pill.frame.height / 2
        field.frame = NSRect(x: 10, y: 4, width: width, height: height)
        pill.addSubview(field)
        return pill
    }
}

private extension NSFont {
    func rounded() -> NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
