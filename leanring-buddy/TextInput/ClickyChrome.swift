import SwiftUI

/// Small shared pieces of the v1 component sheet (Quick Ask context row, reply footer, guide card, menu panel).
enum ClickyChrome {
    static let ask = DS.Colors.overlayCursorBlue
    static let panel = Color(hex: "#14171F")
    static let pill = Color(hex: "#202226").opacity(0.82)
    static let hairline = Color.white.opacity(0.07)
    static let chip = Color.white.opacity(0.06)
}

/// Three effort pips; filled count follows the level.
struct EffortPips: View {
    let effort: AskEffort
    var size: CGFloat = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: size / 2)
                    .fill(index < effort.pipCount ? ClickyChrome.ask : ClickyChrome.ask.opacity(0.3))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The original companion spinner, reduced: a 250° arc rotating.
struct SpinnerRing: View {
    var color: Color = ClickyChrome.ask
    var size: CGFloat = 10
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size * 0.22), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } }
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var outlined = false
    var glow = false

    var body: some View {
        Group {
            if outlined { Circle().strokeBorder(color, lineWidth: 1.5) } else { Circle().fill(color) }
        }
        .frame(width: 6, height: 6)
        .shadow(color: glow ? color : .clear, radius: 3)
        .accessibilityHidden(true)
    }
}

struct KeyCap: View {
    let label: String
    var accent: Color = DS.Colors.borderStrong

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(DS.Colors.textPrimary)
            .frame(minWidth: 18)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(accent, lineWidth: 1))
    }
}
