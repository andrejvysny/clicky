import Carbon.HIToolbox
import SwiftUI

/// Every shortcut in one place, grouped by when it is used. Global shortcuts are recorded by clicking
/// their keys; the rest work only inside Quick Ask, a reply or a guide step and are listed for reference.
struct ShortcutsPane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Click a shortcut to change it.") {
            Button("Reset all") { resetAll() }.islandButton(.quiet)
        } content: {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 22) {
                    GlobalShortcuts(controller: context.ask, voice: context.voice)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 22) {
                    reference("While asking", [("Cycle effort", "⌥⇧E"), ("Attach window", "⌘⇧A"), ("New conversation", "⌘N")])
                    reference("Replies", [("Copy reply", "⌥⇧C"), ("Speak reply", "⌥⇧V")])
                    reference("Guide", [("Back", "⌥⇧←"), ("Re-check", "⌥⇧R"), ("Mark done", "⌥⇧→"), ("End guide", "⌥⇧⌫")])
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func resetAll() {
        context.ask.updateShortcut(keyCode: 49, modifiers: 0xA00)
        context.voice?.resetShortcut(.ask)
        context.voice?.resetShortcut(.dictate)
    }

    private func reference(_ title: String, _ rows: [(String, String)]) -> some View {
        SettingsGroup(title) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: rows[index].0) { KeyCaps(text: rows[index].1) }
            }
        }
    }
}

private struct GlobalShortcuts: View {
    @ObservedObject var controller: AskController
    let voice: VoiceController?

    var body: some View {
        SettingsGroup("Ask") {
            ShortcutRecorderRow(title: "Quick Ask", keyCode: controller.shortcutKeyCode, modifiers: controller.shortcutModifiers,
                                warning: controller.shortcutWarning) { controller.updateShortcut(keyCode: $0, modifiers: $1) }
            if let voice {
                SettingsDivider()
                VoiceShortcutRow(voice: voice, mode: .ask, title: "Ask by voice", subtitle: "Hold to talk, or tap to start and stop")
            }
        }
        if let voice { VoiceShortcutGroups(voice: voice) }
    }
}

private struct VoiceShortcutGroups: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        SettingsGroup("Dictate") {
            VoiceShortcutRow(voice: voice, mode: .dictate, title: "Dictate anywhere", subtitle: nil)
            SettingsDivider()
            SettingsRow(title: "Cancel recording", subtitle: "Active only while recording.") { KeyCaps(text: "⌥⇧⎋") }
        }
        SettingsGroup("Timing") {
            SettingsRow(title: "Tap or hold", subtitle: "Shorter presses latch recording; longer presses record while held.") {
                HStack(spacing: 8) {
                    Slider(value: $voice.tapThreshold, in: 0.15...0.6).frame(width: 110).tint(DS.Colors.accent)
                    Text(String(format: "%.2f s", voice.tapThreshold)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .disabled(!voice.enabled)
    }
}

private struct VoiceShortcutRow: View {
    @ObservedObject var voice: VoiceController
    let mode: InputMode
    let title: String
    let subtitle: String?

    var body: some View {
        let shortcut = voice.shortcut(for: mode)
        ShortcutRecorderRow(title: title, subtitle: subtitle, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                            warning: mode == .ask ? voice.askWarning : voice.dictateWarning,
                            tint: mode == .dictate ? Color(hex: "#F0784A") : nil) {
            voice.updateShortcut(mode, keyCode: $0, modifiers: $1)
        }
        .disabled(!voice.enabled)
    }
}

/// A shortcut row whose keys are a button: click, then press the new combination (Esc cancels).
struct ShortcutRecorderRow: View {
    let title: String
    var subtitle: String?
    let keyCode: UInt32
    let modifiers: UInt32
    var warning: String?
    var tint: Color?
    let onChange: (UInt32, UInt32) -> Void
    @State private var recording = false

    var body: some View {
        SettingsRow(title: title, subtitle: warning ?? subtitle, subtitleColor: warning == nil ? DS.Colors.textTertiary : DS.Colors.warningText) {
            if recording {
                HStack(spacing: 6) {
                    Text("Press a key…").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                    ShortcutCaptureView { newKey, newModifiers in
                        if let newKey, let newModifiers { onChange(newKey, newModifiers) }
                        recording = false
                    }
                    .frame(width: 1, height: 1)
                }
            } else {
                Button { recording = true } label: {
                    HStack(spacing: 3) {
                        ForEach(ShortcutLabel.parts(keyCode: keyCode, modifiers: modifiers), id: \.self) {
                            KeyCap(label: $0, accent: tint ?? DS.Colors.borderStrong)
                        }
                    }
                }
                .buttonStyle(.plain).clickyPointerCursor()
                .accessibilityLabel("Change \(title) shortcut")
            }
        }
        .background(warning == nil ? Color.clear : DS.Colors.warning.opacity(0.08))
    }
}

/// Read-only keys from a label such as "⌥⇧E".
struct KeyCaps: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) { ForEach(Array(text).indices, id: \.self) { KeyCap(label: String(Array(text)[$0])) } }
    }
}
