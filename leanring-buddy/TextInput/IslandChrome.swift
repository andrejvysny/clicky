import AppKit
import SwiftUI

/// Notch geometry of one display, in points.
struct IslandMetrics: Equatable {
    var notchWidth: CGFloat = 0
    var headerHeight: CGFloat = 32

    init(notchWidth: CGFloat = 0, headerHeight: CGFloat = 32) {
        self.notchWidth = notchWidth; self.headerHeight = headerHeight
    }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            headerHeight = screen.safeAreaInsets.top
        } else {
            // Auto-hidden menu bars report no inset; keep the standard menu bar height.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            headerHeight = menuBar >= 20 ? menuBar : 24
        }
    }

    var compactWidth: CGFloat { IslandLayout.compactWidth(notchWidth: notchWidth) }
    var centerGap: CGFloat { IslandLayout.centerGap(notchWidth: notchWidth) }

    static func pointerScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }
}

/// Black island hanging from the top edge: a header row split around the notch, plus optional body.
/// No glow or shadow; a 1 pt tint appears only on states that need action.
struct IslandShell<Left: View, Right: View, Content: View>: View {
    let metrics: IslandMetrics
    let width: CGFloat
    var expanded = false
    var ring: Color? = nil
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @ViewBuilder let content: Content

    var body: some View {
        let radius: CGFloat = expanded ? 16 : 10
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) { left }.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: metrics.centerGap)
                HStack(spacing: 6) { right }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: metrics.headerHeight)
            content
        }
        .frame(width: width)
        .background(Color.black, in: shape)
        .overlay { if let ring { shape.stroke(ring.opacity(0.6), lineWidth: 1) } }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }
}

extension IslandShell where Content == EmptyView {
    init(metrics: IslandMetrics, width: CGFloat, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.init(metrics: metrics, width: width, left: left, right: right, content: { EmptyView() })
    }
}

/// Body padding shared by every expanded state.
struct IslandBody<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum IslandGlyph {
    static func ask(opacity: Double = 1) -> some View {
        Triangle().fill(ClickyChrome.ask.opacity(opacity)).frame(width: 8, height: 7).rotationEffect(.degrees(35))
    }

    static func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    /// Two lines: attached selection.
    static var selection: some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 1).fill(ClickyChrome.ask).frame(width: 10, height: 2)
            RoundedRectangle(cornerRadius: 1).fill(ClickyChrome.ask).frame(width: 7, height: 2)
        }
        .frame(width: 10)
    }

    /// A frame: the window that may be shared (outlined) or an attached screenshot (filled).
    static func window(attached: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(attached ? ClickyChrome.ask : DS.Colors.textSecondary, lineWidth: 1.2)
            .background(attached ? ClickyChrome.ask.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 2))
            .frame(width: 11, height: 8)
    }
}

/// Guide progress: verified segments green (user-confirmed outlined), current segment colored, one pending.
struct IslandProgressBar: View {
    let completed: [Bool]
    var current: Color = ClickyChrome.ask

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(completed.suffix(5).enumerated()), id: \.offset) { _, verified in
                if verified { Capsule().fill(DS.Colors.success) }
                else { Capsule().strokeBorder(DS.Colors.success, lineWidth: 1) }
            }
            Capsule().fill(current)
            Capsule().fill(DS.Colors.surface4)
        }
        .frame(width: 40, height: 3)
        .accessibilityHidden(true)
    }
}

struct IslandButtonStyle: ButtonStyle {
    enum Kind { case primary, warning, secondary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .warning: return Color(hex: "#1a1204")
        case .secondary: return DS.Colors.textPrimary
        case .quiet: return DS.Colors.textTertiary
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return DS.Colors.accent
        case .warning: return DS.Colors.warning
        case .secondary: return Color.white.opacity(0.1)
        case .quiet: return .clear
        }
    }
}

extension View {
    func islandButton(_ kind: IslandButtonStyle.Kind) -> some View { buttonStyle(IslandButtonStyle(kind: kind)).clickyPointerCursor() }
}

/// Cursor-side surfaces (Quick Ask, reply) share the island's black material but float beside the pointer.
private struct CursorCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func cursorCard() -> some View { modifier(CursorCardModifier()) }
}

/// Ghost surface for the cursor-side Quick Ask: translucent blur, no card border, readable on any wallpaper.
private struct GhostPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func ghostPill() -> some View { modifier(GhostPillModifier()) }
}
