import AppKit
import SwiftUI

/// Floating panel opened from the menu with the full last reply. Settings live in the Clicky window.
struct QuickAskView: View {
    @ObservedObject var controller: AskController
    let onCancel: () -> Void
    let onLayoutChanged: () -> Void
    let maximumHeight: CGFloat
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        ScrollView {
            content.background(GeometryReader { geometry in
                Color.clear.preference(key: ComposerHeightKey.self, value: geometry.size.height)
            })
        }
        .frame(width: 440, height: min(maximumHeight, max(200, contentHeight)))
        .background(ClickyChrome.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .preferredColorScheme(.dark)
        .onPreferenceChange(ComposerHeightKey.self) { height in
            guard height.isFinite, height > 0, abs(contentHeight - height) > 0.5 else { return }
            contentHeight = height
            onLayoutChanged()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Triangle().fill(ClickyChrome.ask).frame(width: 14, height: 12).rotationEffect(.degrees(35))
                Text("Last reply").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Settings") { SettingsWindowController.shared.show() }.islandButton(.secondary)
                Button("Close", action: onCancel).islandButton(.quiet).keyboardShortcut(.cancelAction)
            }
            reply
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .foregroundStyle(DS.Colors.textPrimary)
    }

    @ViewBuilder private var reply: some View {
        if controller.response.isEmpty {
            Text("No reply yet. Press \(ShortcutLabel.text(keyCode: controller.shortcutKeyCode, modifiers: controller.shortcutModifiers)) to ask.")
                .font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
        } else {
            Text(ReplyMarkdown.attributed(controller.response)).font(.system(size: 13)).lineSpacing(3)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(controller.response).accessibilityIdentifier("quickAskResponse")
            HStack(spacing: 6) {
                Button("Copy") { controller.copyResponse() }.islandButton(.secondary)
                Button("Speak") { controller.speakResponse() }.islandButton(.secondary)
                Spacer()
                Button("New conversation") { controller.newConversation() }.islandButton(.quiet)
            }
        }
        if let error = controller.errorMessage {
            Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 420
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

extension View {
    func clickyPointerCursor() -> some View { modifier(PointerCursorModifier()) }
}
