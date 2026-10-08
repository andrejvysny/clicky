import AppKit
import Combine
import SwiftUI

/// Click-through circle + instruction card. Never takes focus or mouse events.
@MainActor
final class GuidanceOverlay {
    enum Tone { case waiting, success, miss, warning }

    fileprivate final class Model: ObservableObject {
        @Published var instruction = ""
        @Published var status = ""
        @Published var tone: Tone = .waiting
    }

    private static let circleInset: CGFloat = 14
    private static let cardGap: CGFloat = 10

    private let model = Model()
    private var circlePanel: NSPanel?
    private var cardPanel: NSPanel?
    private var cardHost: NSHostingController<AnyView>?
    private var circleFrame: NSRect = .zero

    var windowNumbers: Set<Int> {
        Set([circlePanel, cardPanel].compactMap { $0 }.filter { $0.windowNumber > 0 }.map(\.windowNumber))
    }

    /// `target` is global top-left Core Graphics points.
    func show(target: CGRect, instruction: String) {
        model.instruction = instruction
        model.status = ""
        model.tone = .waiting
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

    private func layoutCard() {
        guard let cardPanel, let cardHost else { return }
        let size = cardHost.sizeThatFits(in: CGSize(width: 280, height: 400))
        let screen = NSScreen.screens.first { $0.frame.intersects(circleFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? circleFrame
        var origin = CGPoint(x: circleFrame.minX, y: circleFrame.minY - Self.cardGap - size.height)
        if origin.y < visible.minY { origin.y = circleFrame.maxY + Self.cardGap }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        cardPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        cardPanel.contentView?.frame = NSRect(origin: .zero, size: size)
    }
}

private extension GuidanceOverlay.Tone {
    var color: Color {
        switch self {
        case .waiting: return .blue
        case .success: return .green
        case .miss: return .orange
        case .warning: return .yellow
        }
    }
}

private struct GuidanceCircleView: View {
    @ObservedObject var model: GuidanceOverlay.Model
    @State private var pulsing = false

    var body: some View {
        Ellipse()
            .stroke(model.tone.color, lineWidth: 3)
            .shadow(color: model.tone.color.opacity(0.6), radius: 8)
            .padding(8)
            .scaleEffect(pulsing ? 1.06 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
            }
    }
}

private struct GuidanceCardView: View {
    @ObservedObject var model: GuidanceOverlay.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.instruction)
                .font(.system(size: 13))
                .foregroundColor(.white)
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
        )
    }
}
