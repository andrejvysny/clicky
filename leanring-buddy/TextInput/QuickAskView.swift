import AppKit
import SwiftUI

struct QuickAskView: View {
    @ObservedObject var controller: AskController
    let onCancel: () -> Void
    let onLayoutChanged: () -> Void
    let maximumHeight: CGFloat
    @State private var editorHeight: CGFloat = 88
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        ScrollView {
            composer.background(GeometryReader { geometry in
                Color.clear.preference(key: ComposerHeightKey.self, value: geometry.size.height)
            })
        }
        .frame(width: 440, height: min(maximumHeight, max(240, contentHeight)))
        .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(.dark)
        .onPreferenceChange(ComposerHeightKey.self) { height in
            guard abs(contentHeight - height) > 0.5 else { return }
            contentHeight = height
            onLayoutChanged()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Triangle().fill(Color.blue).frame(width: 16, height: 16).rotationEffect(.degrees(35))
                Text("Ask Clicky").font(.headline)
                Spacer()
                Button(controller.showSettings ? "Done" : "Settings") { controller.showSettings.toggle() }
                    .clickyPointerCursor()
            }
            Picker("Backend", selection: $controller.provider) {
                ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.disabled(controller.isBusy)
            Text(controller.session.map { "Managed session · " + String($0.identifier.prefix(12)) } ?? "New managed conversation")
                .font(.caption).foregroundStyle(.secondary)
            if controller.showSettings { AskSettingsView(controller: controller) }
            QuickAskEditor(text: $controller.draft, height: $editorHeight, onSubmit: { _ = controller.submit() }, onCancel: onCancel)
                .frame(height: editorHeight)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .id(controller.editorGeneration)
                .disabled(controller.isBusy)
            HStack {
                Button(controller.isCapturing ? "Capturing window…" : "Attach window screenshot") { controller.attachWindowSnapshot() }
                    .disabled(controller.isBusy || controller.isCapturing || controller.captureTargetName == nil)
                    .clickyPointerCursor().accessibilityIdentifier("quickAskAttachWindow")
                if controller.isCapturing { Button("Cancel capture") { controller.removeAttachment() }.clickyPointerCursor() }
            }
            if let image = controller.attachment { AttachmentPreview(image: image, onRemove: controller.removeAttachment) }
            if let error = controller.attachmentError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text(controller.captureTargetName.map { "Captures only the original \($0) window. Review before sending." } ?? "Reopen Quick Ask in the window you want to attach.")
                .font(.caption2).foregroundStyle(.secondary)
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !controller.response.isEmpty {
                ScrollView { Text(controller.response).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
                    .accessibilityIdentifier("quickAskResponse")
            }
            HStack {
                Text("Enter sends · Shift+Enter adds a line").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).clickyPointerCursor()
                if controller.isBusy {
                    Button("Stop reply") { controller.stopReply() }.clickyPointerCursor()
                } else {
                    Button("Send") { _ = controller.submit() }.disabled(!controller.canSubmit).clickyPointerCursor().accessibilityIdentifier("quickAskSend")
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(.dark)
        .onChange(of: editorHeight) { _ in onLayoutChanged() }
        .onChange(of: controller.showSettings) { _ in onLayoutChanged() }
        .onChange(of: controller.errorMessage) { _ in onLayoutChanged() }
        .onChange(of: controller.response.isEmpty) { _ in onLayoutChanged() }
        .onChange(of: controller.attachment) { _ in onLayoutChanged() }
        .onChange(of: controller.attachmentError) { _ in onLayoutChanged() }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 420
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AskSettingsView: View {
    @ObservedObject var controller: AskController
    @State private var recordingShortcut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project folder").font(.caption)
            HStack {
                TextField("Project folder", text: $controller.workingDirectory).textFieldStyle(.roundedBorder)
                Button("Choose") { controller.chooseDirectory() }.clickyPointerCursor()
            }
            if controller.provider != .preview {
                Text("Installed agent executable").font(.caption)
                HStack {
                    TextField("Executable path", text: controller.provider == .claude ? $controller.claudeExecutable : $controller.codexExecutable).textFieldStyle(.roundedBorder)
                    Button("Choose") { controller.chooseExecutable() }.clickyPointerCursor()
                }
                Text("Use the official CLI to sign in. Clicky does not store account credentials.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(recordingShortcut ? "Press a shortcut…" : "Change Quick Ask shortcut") { recordingShortcut = true }.clickyPointerCursor()
                Button("Reset") { controller.shortcutModifiers = 0xA00; controller.shortcutKeyCode = 49 }.clickyPointerCursor()
            }
            if recordingShortcut { ShortcutCaptureView { keyCode, modifiers in
                if let keyCode, let modifiers { controller.shortcutModifiers = modifiers; controller.shortcutKeyCode = keyCode }
                recordingShortcut = false
            }.frame(height: 26) }
            if let warning = controller.shortcutWarning { Text(warning).font(.caption2).foregroundStyle(.orange) }
            Picker("Speak replies", selection: $controller.speechPreference) {
                ForEach(SpeechReplyPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("Voice input, dictation, and guided steps are prepared for a later build.").font(.caption2).foregroundStyle(.secondary)
            Button("New conversation") { controller.newConversation() }.clickyPointerCursor()
        }.disabled(controller.isBusy)
    }
}

private struct AttachmentPreview: View {
    let image: PNGImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if let preview = NSImage(data: image.data) {
                Image(nsImage: preview).resizable().scaledToFit().frame(width: 120, height: 80)
                    .accessibilityLabel("Attached window screenshot")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(image.displayName).font(.caption).lineLimit(2)
                Text("\(image.pixelWidth) × \(image.pixelHeight) pixels").font(.caption2).foregroundStyle(.secondary)
                if let context = image.context { Text(context.capturedAt, style: .time).font(.caption2).foregroundStyle(.secondary) }
                Button("Remove screenshot", action: onRemove).clickyPointerCursor()
            }
        }.accessibilityIdentifier("quickAskAttachment")
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
