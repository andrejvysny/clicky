import AppKit
import SwiftUI

struct TextCompanionPanelView: View {
    @ObservedObject var controller: AskController
    @ObservedObject var companionManager: CompanionManager
    let onOpenQuickAsk: (QuickAskPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Triangle().fill(Color.blue).frame(width: 18, height: 18).rotationEffect(.degrees(35))
                Text("Clicky").font(.headline)
                Spacer()
                Text(controller.isBusy ? "Working" : "Ready").font(.caption).foregroundStyle(.secondary)
            }
            Button("Ask Clicky") { onOpenQuickAsk(.ghost) }.clickyPointerCursor()
            Text(controller.provider.displayName).font(.caption).foregroundStyle(.secondary)
            if let warning = controller.shortcutWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            Toggle("Show blue companion", isOn: Binding(get: { companionManager.isClickyCursorEnabled }, set: { companionManager.setClickyCursorEnabled($0) }))
            if controller.isBusy { Button("Stop reply") { controller.stopReply() }.clickyPointerCursor() }
            if !controller.response.isEmpty {
                Button("Read last reply") { onOpenQuickAsk(.details(showSettings: false)) }.clickyPointerCursor()
                Button("Copy last reply") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.response, forType: .string) }.clickyPointerCursor()
                Button("Dismiss reply bubble") { controller.dismissResponse() }.clickyPointerCursor()
                ReplySpeechControls(speech: controller.replySpeech, text: controller.response)
            }
            Divider()
            Button("Settings") { onOpenQuickAsk(.details(showSettings: true)) }.clickyPointerCursor()
            Text("Voice and visual guidance are not enabled in this build.").font(.caption2).foregroundStyle(.secondary)
            Button("Quit Clicky") { NSApp.terminate(nil) }.clickyPointerCursor()
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(.dark)
    }
}

private struct ReplySpeechControls: View {
    @ObservedObject var speech: LocalReplySpeech
    let text: String
    var body: some View {
        if speech.isSpeaking {
            Button("Stop speaking") { speech.stop() }.clickyPointerCursor()
        } else {
            Button("Speak last reply") { speech.speak(text) }.clickyPointerCursor()
        }
    }
}
