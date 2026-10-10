import SwiftUI

/// Settings › Voice. Reading this section opens no microphone and loads no model.
struct VoiceSettingsSection: View {
    var body: some View {
        if let voice = VoiceController.shared { Content(voice: voice) }
    }

    private struct Content: View {
        @ObservedObject var voice: VoiceController
        @State private var capturing: InputMode?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Voice input", isOn: $voice.enabled).font(.system(size: 12))
                Group {
                    shortcutRow("Dictate Anywhere", mode: .dictate, warning: voice.dictateWarning)
                    shortcutRow("Ask Clicky by voice", mode: .ask, warning: voice.askWarning)
                    note("Tap to start and tap again to stop, or hold while you speak. Dictate Anywhere inserts into the app you were in; Ask puts the text in the Quick Ask box and never sends it. ⌥⇧⎋ cancels.")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tap or hold threshold: \(String(format: "%.2f", voice.tapThreshold)) s").font(.system(size: 12))
                        Slider(value: $voice.tapThreshold, in: 0.15...0.6)
                    }
                    Toggle("Smart cleanup", isOn: $voice.cleanupEnabled).font(.system(size: 12))
                    note("Removes fillers, repetitions and clear self-corrections; ambiguous changes ask first.")
                    Picker("Microphone", selection: $voice.inputDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(voice.devices) { device in
                            Text(device.transport == "bluetooth" ? device.name + " (Bluetooth)" : device.name).tag(Optional(device.uid))
                        }
                    }
                    .font(.system(size: 12))
                    Picker("Recording limit", selection: $voice.limitSeconds) {
                        ForEach(VoiceController.limitChoices, id: \.self) { Text(VoiceText.clock($0)).tag($0) }
                    }
                    .font(.system(size: 12))
                    permissionRow
                    speechRow
                }
                .disabled(!voice.enabled)
            }
            .onAppear { voice.refreshDevices() }
        }

        private func shortcutRow(_ title: String, mode: InputMode, warning: String?) -> some View {
            let shortcut = voice.shortcut(for: mode)
            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 12))
                    Spacer()
                    ForEach(ShortcutLabel.parts(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers), id: \.self) { KeyCap(label: $0) }
                }
                HStack(spacing: 6) {
                    Button(capturing == mode ? "Press a shortcut…" : "Change") { capturing = mode }.islandButton(.secondary)
                    Button("Reset") { voice.resetShortcut(mode) }.islandButton(.quiet)
                }
                if capturing == mode {
                    ShortcutCaptureView { keyCode, modifiers in
                        if let keyCode, let modifiers { voice.updateShortcut(mode, keyCode: keyCode, modifiers: modifiers) }
                        capturing = nil
                    }.frame(height: 22)
                }
                if let warning { Text(warning).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText) }
            }
        }

        private var permissionRow: some View {
            HStack(spacing: 6) {
                switch voice.microphone {
                case .granted: Text("Microphone: allowed").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                case .undetermined:
                    Text("Microphone: not asked yet").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button("Request") { voice.requestMicrophoneFromSettings() }.islandButton(.secondary)
                case .denied:
                    Text("Microphone: not allowed").font(.system(size: 12)).foregroundStyle(DS.Colors.warningText)
                    Spacer()
                    Button("Open System Settings") { voice.openMicrophoneSettings() }.islandButton(.secondary)
                }
            }
        }

        @ViewBuilder private var speechRow: some View {
            if let runtime = LocalAIRuntime.shared { SpeechStatus(runtime: runtime, voice: voice) }
        }

        private func note(_ text: String) -> some View {
            Text(text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct SpeechStatus: View {
        @ObservedObject var runtime: LocalAIRuntime
        @ObservedObject var voice: VoiceController

        var body: some View {
            HStack(spacing: 8) {
                Text("Speech pipeline").font(.system(size: 12))
                LabPhaseBadge(phase: runtime.groups[.speech]?.phase ?? .missing, progress: runtime.groups[.speech]?.downloadProgress)
                Spacer(minLength: 4)
                if !runtime.isLoaded(.speech) {
                    Button(voice.isLoadingModels ? "Loading…" : "Load") { voice.loadSpeechModels() }
                        .islandButton(.secondary).disabled(voice.isLoadingModels)
                }
            }
        }
    }
}
