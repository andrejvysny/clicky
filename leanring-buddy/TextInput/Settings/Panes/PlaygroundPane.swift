import SwiftUI

/// Try local models on your own input. Results stay in memory until saved. Leaving the pane stops a
/// recording; closing the window cancels running jobs.
struct PlaygroundPane: View {
    @EnvironmentObject private var context: SettingsContext
    @State private var mode = Mode.text

    enum Mode: Hashable { case text, vision, speech }

    var body: some View {
        SettingsPage(title: "Playground", subtitle: "Try models on your own input. Results stay in memory until saved.") {
            SettingsSegmented(selection: $mode, options: [(.text, "Text"), (.vision, "Vision"), (.speech, "Speech")])
        } content: {
            if let lab = context.lab() {
                switch mode {
                case .text: LabTextTab(model: lab.text, runtime: lab.runtime)
                case .vision: LabVisionTab(model: lab.vision, runtime: lab.runtime)
                case .speech: LabSpeechTab(model: lab.speech, runtime: lab.runtime)
                }
            } else {
                SettingsNote("Local AI is not available in this build.")
            }
        }
        // Switching away from Speech must not leave the microphone on.
        .onChange(of: mode) { old, _ in if old == .speech { context.lab()?.speech.cancelRecording() } }
        .accessibilityIdentifier("localAIPlayground")
    }
}
