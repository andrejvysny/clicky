import AppKit
import Combine
import SwiftUI

/// Completed milestones before the current step: `true` verified, `false` user-confirmed (manual Next).
struct GuideCardProgress: Equatable {
    var completed: [Bool]
    var stepNumber: Int { completed.count + 1 }
}

/// Click-through circle + instruction card. Never takes focus or mouse events.
@MainActor
final class GuidanceOverlay {
    enum Tone { case waiting, verifying, success, miss, warning, stale }

    fileprivate final class Model: ObservableObject {
        @Published var instruction = ""
        @Published var status = ""
        @Published var tone: Tone = .waiting
        @Published var progress: GuideCardProgress?
        @Published var shortcutHints = false
    }

    private static let circleInset: CGFloat = 14
    /// The card keeps 12 pt clear of the mark.
    private static let cardGap: CGFloat = 12

    private let model = Model()
    private var circlePanel: NSPanel?
    private var cardPanel: NSPanel?
    private var cardHost: NSHostingController<AnyView>?
    private var circleFrame: NSRect = .zero

    var windowNumbers: Set<Int> {
        Set([circlePanel, cardPanel].compactMap { $0 }.filter { $0.windowNumber > 0 }.map(\.windowNumber))
    }

    /// `target` is global top-left Core Graphics points.
    func show(target: CGRect, instruction: String, progress: GuideCardProgress? = nil, shortcutHints: Bool = false) {
        model.instruction = instruction
        model.status = ""
        model.tone = .waiting
        model.progress = progress
        model.shortcutHints = shortcutHints
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height ?? 0
        circleFrame = NSRect(x: target.minX, y: primaryHeight - target.maxY, width: target.width, height: target.height)
            .insetBy(dx: -Self.circleInset, dy: -Self.circleInset)

        if circlePanel == nil {
            let panel = makePanel()
            let host = NSHostingController(rootView: AnyView(GuidanceCircleView(model: model)))
            host.sizingOptions = []
            panel.contentView = host.view
            circlePanel = panel
        }
        if cardPanel == nil {
            let panel = makePanel()
            let host = NSHostingController(rootView: AnyView(GuidanceCardView(model: model)))
            host.sizingOptions = []
            panel.contentView = host.view
            cardPanel = panel
            cardHost = host
        }
        circlePanel?.setFrame(circleFrame, display: true)
        circlePanel?.contentView?.frame = NSRect(origin: .zero, size: circleFrame.size)
        layoutCard()
        circlePanel?.orderFrontRegardless()
        cardPanel?.orderFrontRegardless()
    }

    func update(status: String, tone: Tone) {
        model.status = status
        model.tone = tone
        layoutCard()
    }

    func hide() {
        circlePanel?.orderOut(nil)
        cardPanel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        return panel
    }

    /// Docks to the first side with room: below, above, left, right; then clamps to the screen.
    private func layoutCard() {
        guard let cardPanel, let cardHost else { return }
        let size = cardHost.sizeThatFits(in: CGSize(width: 300, height: 400))
        let screen = NSScreen.screens.first { $0.frame.intersects(circleFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? circleFrame
        let gap = Self.cardGap
        let candidates = [
            CGPoint(x: circleFrame.minX, y: circleFrame.minY - gap - size.height),
            CGPoint(x: circleFrame.minX, y: circleFrame.maxY + gap),
            CGPoint(x: circleFrame.minX - gap - size.width, y: circleFrame.maxY - size.height),
            CGPoint(x: circleFrame.maxX + gap, y: circleFrame.maxY - size.height),
        ]
        var origin = candidates.first { visible.contains(CGRect(origin: $0, size: size)) } ?? candidates[0]
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        cardPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        cardPanel.contentView?.frame = NSRect(origin: .zero, size: size)
    }
}

private extension GuidanceOverlay.Tone {
    var color: Color {
        switch self {
        case .waiting, .verifying: return DS.Colors.overlayCursorBlue
        case .success: return DS.Colors.success
        case .miss, .warning: return DS.Colors.warning
        case .stale: return DS.Colors.textSecondary
        }
    }
    var cardBorder: Color {
        switch self {
        case .success: return DS.Colors.success.opacity(0.35)
        case .warning, .miss: return DS.Colors.warning.opacity(0.4)
        default: return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

private struct GuidanceCircleView: View {
    @ObservedObject var model: GuidanceOverlay.Model
    @State private var pulsing = false

    var body: some View {
        let tone = model.tone
        Ellipse()
            .stroke(tone == .verifying ? tone.color.opacity(0.45) : (tone == .stale ? tone.color.opacity(0.55) : tone.color),
                    style: StrokeStyle(lineWidth: tone == .stale ? 2 : 3, dash: tone == .stale ? [5, 4] : []))
            .shadow(color: [.verifying, .stale].contains(tone) ? .clear : tone.color.opacity(0.6), radius: 8)
            .padding(8)
            // Only the waiting mark pulses; other states hold still so a change reads as a state change.
            .scaleEffect(pulsing && tone == .waiting ? 1.06 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
            }
    }
}

private struct GuidanceCardView: View {
    @ObservedObject var model: GuidanceOverlay.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let progress = model.progress { header(progress) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.instruction)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(2)
                if !model.status.isEmpty { statusRow }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            if model.shortcutHints {
                HStack(spacing: 10) {
                    Text("⌥⇧→ skip")
                    Text("⌥⇧R retry")
                }
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(DS.Colors.surface2).frame(height: 1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 270, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(model.tone.cardBorder, lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 8)
        )
    }

    private func header(_ progress: GuideCardProgress) -> some View {
        HStack(spacing: 8) {
            Text("Step \(progress.stepNumber)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.blue400)
            HStack(spacing: 3) {
                ForEach(Array(progress.completed.enumerated()), id: \.offset) { _, verified in
                    // Verified fills green; user-confirmed is outlined so trust stays visible.
                    if verified {
                        RoundedRectangle(cornerRadius: 2).fill(DS.Colors.success)
                    } else {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(DS.Colors.success, lineWidth: 1)
                    }
                }
                .frame(height: 3)
                RoundedRectangle(cornerRadius: 2).fill(DS.Colors.overlayCursorBlue).frame(height: 3)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            switch model.tone {
            case .waiting: StatusDot(color: DS.Colors.overlayCursorBlue, glow: true)
            case .verifying: SpinnerRing(size: 8)
            case .stale: SpinnerRing(color: DS.Colors.textSecondary, size: 8)
            case .success: EmptyView()
            case .miss, .warning: StatusDot(color: DS.Colors.warning)
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundColor(model.tone == .success ? DS.Colors.success : DS.Colors.textSecondary)
        }
    }
}
