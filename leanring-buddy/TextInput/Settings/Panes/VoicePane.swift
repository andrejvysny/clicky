import SwiftUI

/// Voice input. Reading this pane opens no microphone and loads no model; model controls live in Models.
struct VoicePane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        if let voice = context.voice {
            Content(voice: voice, runtime: context.runtime) { context.selection = .models }
        } else {
            SettingsPage(title: "Voice") { SettingsNote("Voice input is not available in this build.") }
        }
    }

    private struct Content: View {
        @ObservedObject var voice: VoiceController
        let runtime: LocalAIRuntime?
        let openModels: () -> Void

        var body: some View {
            SettingsPage(title: "Voice", subtitle: "Opening this page doesn't open the microphone or load a model.") {
                SettingsSwitch(isOn: $voice.enabled, label: "Voice input")
            } content: {
                Group {
                    input
                    SettingsGroup("Dictate anywhere") {
                        SettingsRow(title: "Smart cleanup", subtitle: "Removes fillers, repetitions and clear self-corrections. Ambiguous changes ask first.") {
                            SettingsSwitch(isOn: $voice.cleanupEnabled, label: "Smart cleanup")
                        }
                        if let runtime {
                            SettingsDivider()
                            ModelStatusRow(runtime: runtime, group: .cleanup, title: "Cleanup model", openModels: openModels)
                        }
                        SettingsDivider()
                        SettingsRow(title: "Never press Enter", subtitle: "Dictation inserts text only. You send it.") {
                            Text("Always").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    SettingsGroup("Ask by voice") {
                        SettingsRow(title: "After you stop", subtitle: "The text goes into Quick Ask and waits for Enter. Nothing is sent on its own.") {
                            Text("Review in Quick Ask").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    if let runtime {
                        SettingsGroup("Speech pipeline") {
                            ModelStatusRow(runtime: runtime, group: .speech, title: nil, openModels: openModels) {
                                if !runtime.isLoaded(.speech) {
                                    Button(voice.isLoadingModels ? "Loading…" : "Load") { voice.loadSpeechModels() }
                                        .islandButton(.secondary).disabled(voice.isLoadingModels)
                                }
                            }
                        }
                    }
                }
                .disabled(!voice.enabled)
            }
            .onAppear { voice.refreshDevices() }
        }

        private var input: some View {
            SettingsGroup("Input") {
                SettingsRow(title: "Microphone") {
                    Picker("", selection: $voice.inputDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(voice.devices) { device in
                            Text(device.transport == "bluetooth" ? device.name + " (Bluetooth)" : device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingsRow(title: "Permission") { permission }
                SettingsDivider()
                SettingsRow(title: "Recording limit") {
                    Picker("", selection: $voice.limitSeconds) {
                        ForEach(VoiceController.limitChoices, id: \.self) { Text(VoiceText.clock($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                }
            }
        }

        @ViewBuilder private var permission: some View {
            switch voice.microphone {
            case .granted: SettingsStatus(text: "Allowed")
            case .undetermined:
                HStack(spacing: 8) {
                    SettingsStatus(text: "Not asked yet", color: DS.Colors.textSecondary)
                    Button("Request") { voice.requestMicrophoneFromSettings() }.islandButton(.secondary)
                }
            case .denied:
                HStack(spacing: 8) {
                    SettingsStatus(text: "Not allowed", color: DS.Colors.warningText)
                    Button("Open System Settings") { voice.openMicrophoneSettings() }.islandButton(.secondary)
                }
            }
        }
    }
}

/// One model group's status with a link to Models, instead of repeating its controls.
struct ModelStatusRow<Extra: View>: View {
    @ObservedObject var runtime: LocalAIRuntime
    let group: LocalModelGroup
    let title: String?
    let openModels: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        let state = runtime.groups[group]
        let name = runtime.selectedEntry(group)?.displayName ?? "No model"
        SettingsRow(title: title ?? name, subtitle: title == nil ? subtitle(state) : nil) {
            HStack(spacing: 8) {
                LabPhaseBadge(phase: state?.phase ?? .missing, progress: state?.downloadProgress)
                if title != nil { Text(name).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary).lineLimit(1) }
                extra
                SettingsLink("Models →", action: openModels)
            }
        }
    }

    private func subtitle(_ state: LocalAIRuntime.GroupState?) -> String {
        guard let load = state?.loadMilliseconds, runtime.isLoaded(group) else { return "Runs on this Mac." }
        return "Runs on this Mac. Loaded in \(LabFormat.milliseconds(load))."
    }
}

extension ModelStatusRow where Extra == EmptyView {
    init(runtime: LocalAIRuntime, group: LocalModelGroup, title: String?, openModels: @escaping () -> Void) {
        self.init(runtime: runtime, group: group, title: title, openModels: openModels, extra: { EmptyView() })
    }
}
