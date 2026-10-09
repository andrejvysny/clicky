import AppKit
import SwiftUI

/// Clicky window opened from the menu: the full last reply, or Settings. Asking happens in the island.
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
        .onChange(of: controller.showSettings) { _ in onLayoutChanged() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Triangle().fill(ClickyChrome.ask).frame(width: 14, height: 12).rotationEffect(.degrees(35))
                Text(controller.showSettings ? "Settings" : "Last reply").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(controller.showSettings ? "Last reply" : "Settings") { controller.showSettings.toggle() }.islandButton(.secondary)
                Button("Close", action: onCancel).islandButton(.quiet).keyboardShortcut(.cancelAction)
            }
            if controller.showSettings { AskSettingsView(controller: controller) } else { reply }
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

/// Grouped settings: backend, shortcuts, sharing, speech, conversation.
struct AskSettingsView: View {
    @ObservedObject var controller: AskController
    @ObservedObject private var guide: VisualGuideController
    @State private var recordingShortcut = false
    @State private var screenRecordingAllowed = CGPreflightScreenCaptureAccess()

    init(controller: AskController) {
        self.controller = controller
        guide = controller.guide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Backend") {
                Picker("", selection: $controller.provider) {
                    ForEach(AgentProvider.allCases, id: \.self) { Text($0 == .preview ? "Preview" : $0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if controller.provider == .preview {
                    note("Local preview sends nothing and uses no AI.")
                    Button("Demo guide (no AI)") { controller.guide.startDemo() }.islandButton(.secondary)
                } else {
                    HStack(spacing: 6) {
                        TextField("Executable path", text: controller.provider == .claude ? $controller.claudeExecutable : $controller.codexExecutable)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        Button("Choose") { controller.chooseExecutable() }.islandButton(.secondary)
                    }
                    note(controller.provider == .claude
                         ? "Haiku 5.5 with your Claude sign-in. Raising effort starts a new conversation."
                         : "GPT-6 Luna in a separate Clicky-owned Codex profile. Effort applies per prompt.")
                    if controller.provider == .codex { Button("Sign in to Clicky Codex") { controller.signInCodex() }.islandButton(.secondary) }
                }
            }
            section("Shortcuts") {
                HStack(spacing: 3) {
                    Text("Quick Ask").font(.system(size: 12))
                    Spacer()
                    ForEach(ShortcutLabel.parts(keyCode: controller.shortcutKeyCode, modifiers: controller.shortcutModifiers), id: \.self) { KeyCap(label: $0) }
                }
                HStack(spacing: 6) {
                    Button(recordingShortcut ? "Press a shortcut…" : "Change") { recordingShortcut = true }.islandButton(.secondary)
                    Button("Reset") { controller.updateShortcut(keyCode: 49, modifiers: 0xA00) }.islandButton(.quiet)
                }
                if recordingShortcut {
                    ShortcutCaptureView { keyCode, modifiers in
                        if let keyCode, let modifiers { controller.updateShortcut(keyCode: keyCode, modifiers: modifiers) }
                        recordingShortcut = false
                    }.frame(height: 22)
                }
                if let warning = controller.shortcutWarning { Text(warning).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText) }
                note("In Quick Ask: ⌥⇧E effort · ⌘N new conversation · Esc stops a running reply, then closes. Reply: ⌥⇧C copy · ⌥⇧V speak. Guide step: ⌥⇧← back · ⌥⇧→ skip · ⌥⇧R retry · ⌥⇧⌫ end.")
            }
            section("Screen") {
                Picker("Sharing", selection: $controller.screenInclusion) {
                    ForEach(ScreenInclusionPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                note("When a question needs the screen, Clicky shares the window you asked from automatically. With no focused window it asks before sharing a display, once per session. Images stay in memory.")
                HStack(spacing: 6) {
                    Text(screenRecordingAllowed ? "Screen Recording: allowed" : "Screen Recording: not allowed")
                        .font(.system(size: 12))
                        .foregroundStyle(screenRecordingAllowed ? DS.Colors.textSecondary : DS.Colors.warningText)
                    Spacer()
                    if !screenRecordingAllowed {
                        Button("Open System Settings") { WindowSnapshotCapture.openScreenRecordingSettings() }.islandButton(.secondary)
                        // macOS applies a new Screen Recording grant only after relaunch.
                        Button("Quit & Reopen") { Self.relaunch() }.islandButton(.secondary)
                    }
                }
                Toggle("Offer to share the display when no window is focused", isOn: Binding(
                    get: { guide.displayFallbackAllowed },
                    set: { guide.displayFallbackAllowed = $0 }))
                    .font(.system(size: 12))
                Toggle("Attach selected text when Quick Ask opens", isOn: $controller.attachSelection).font(.system(size: 12))
                note("Reads only the selection in the focused, non-secure field through Accessibility. ⌫ in an empty prompt removes it.")
            }
            section("Speech") {
                Picker("Speak replies", selection: $controller.speechPreference) {
                    ForEach(SpeechReplyPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Button("New conversation") { controller.newConversation() }.islandButton(.secondary)
        }
        .disabled(controller.isBusy)
        .onAppear {
            screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(DS.Colors.textTertiary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

extension View {
    func clickyPointerCursor() -> some View { modifier(PointerCursorModifier()) }
}
