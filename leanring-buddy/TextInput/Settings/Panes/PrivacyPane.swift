import AppKit
import SwiftUI

/// Everything about what Clicky can see: screen sharing, selection reading and the VS Code bridge.
struct PrivacyPane: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        SettingsPage(title: "Screen & privacy") {
            Content(controller: context.ask, store: context.ask.writingDefinitions)
        }
    }

    private struct Content: View {
        @ObservedObject var controller: AskController
        @ObservedObject var store: WritingDefinitionsStore
        @ObservedObject private var guide: VisualGuideController
        @State private var screenRecordingAllowed = CGPreflightScreenCaptureAccess()

        init(controller: AskController, store: WritingDefinitionsStore) {
            self.controller = controller
            self.store = store
            guide = controller.guide
        }

        var body: some View {
            SettingsGroup("Screen") {
                SettingsRow(title: "Share the screen", subtitle: "Clicky shares only the window you asked from. Images stay in memory.") {
                    Picker("", selection: $controller.screenInclusion) {
                        ForEach(ScreenInclusionPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                SettingsDivider()
                SettingsRow(title: "Screen Recording") {
                    if screenRecordingAllowed {
                        SettingsStatus(text: "Allowed")
                    } else {
                        HStack(spacing: 8) {
                            SettingsStatus(text: "Not allowed", color: DS.Colors.warningText)
                            Button("Open System Settings") { WindowSnapshotCapture.openScreenRecordingSettings() }.islandButton(.secondary)
                            // macOS applies a new Screen Recording grant only after relaunch.
                            Button("Quit & Reopen") { Self.relaunch() }.islandButton(.secondary)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Offer to share the display when no window is focused", subtitle: "Asked once per session.") {
                    SettingsSwitch(isOn: Binding(get: { guide.displayFallbackAllowed }, set: { guide.displayFallbackAllowed = $0 }),
                                   label: "Offer to share the display")
                }
            }
            SettingsGroup("Selection") {
                SettingsRow(title: "Attach selected text when asking",
                            subtitle: "Read from the focused, non-secure field through Accessibility. ⌫ in an empty prompt removes it.") {
                    SettingsSwitch(isOn: $controller.attachSelection, label: "Attach selected text")
                }
            }
            SettingsGroup("VS Code bridge") {
                SettingsRow(title: "Allow the Clicky VS Code bridge",
                            subtitle: "Local extension. It can report the active editor and terminal, apply one edit, and insert (never run) one line.") {
                    SettingsSwitch(isOn: Binding(get: { store.bridgeEnabled }, set: { store.setBridgeEnabled($0) }), label: "VS Code bridge")
                }
            }
            .onAppear {
                screenRecordingAllowed = CGPreflightScreenCaptureAccess()
                store.refreshBridge()
            }
        }

        private static func relaunch() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
}
