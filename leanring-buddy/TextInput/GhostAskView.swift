import AppKit
import SwiftUI

struct GhostAskView: View {
    @ObservedObject var controller: AskController
    let onCancel: () -> Void
    let onLayoutChanged: () -> Void
    @State private var editorHeight: CGFloat = 22

    private var placeholder: String {
        switch controller.provider {
        case .preview: return "Ask Clicky (preview, no AI)…"
        case .claude: return "Ask Claude…"
        case .codex: return "Ask Codex…"
        }
    }

    private var canAttach: Bool {
        controller.captureTargetName != nil && !controller.isBusy && controller.attachment == nil && !controller.isCapturing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            pill
            details
        }
        .frame(width: 300, alignment: .leading)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: GhostHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(GhostHeightKey.self) { _ in onLayoutChanged() }
        .onChange(of: editorHeight) { _ in onLayoutChanged() }
        .onChange(of: controller.attachment) { _ in onLayoutChanged() }
        .onChange(of: controller.errorMessage) { _ in onLayoutChanged() }
        .onChange(of: controller.attachmentError) { _ in onLayoutChanged() }
        .onChange(of: controller.presentationHasSubmission) { _ in onLayoutChanged() }
        .onChange(of: controller.response.isEmpty) { _ in onLayoutChanged() }
        .onChange(of: controller.isCapturing) { _ in onLayoutChanged() }
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: 6) {
            Triangle().fill(Color.blue).frame(width: 9, height: 9).rotationEffect(.degrees(35))
            QuickAskEditor(text: $controller.draft, height: $editorHeight, placeholder: placeholder, compact: true,
                           onAttach: canAttach ? { controller.attachWindowSnapshot() } : nil,
                           onIncludeScreen: controller.screenInclusion.isAvailable && !controller.isBusy ? { controller.toggleScreenAttachment() } : nil,
                           onSubmit: { _ = controller.submit() }, onCancel: onCancel)
                .frame(height: editorHeight)
                .id(controller.editorGeneration)
                .disabled(controller.isBusy)
            if controller.screenInclusion.isAvailable && !controller.isBusy {
                Button { controller.toggleScreenAttachment() } label: {
                    Image(systemName: controller.hasScreenAttachment ? "eye.fill" : "eye").font(.system(size: 12))
                        .foregroundStyle(controller.hasScreenAttachment ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(controller.isCapturing)
                .help(controller.hasScreenAttachment ? "Screen included — click to remove (⌘⇧S)" : "Include your screen (⌘⇧S)")
                .accessibilityIdentifier("quickAskIncludeScreen")
                .clickyPointerCursor()
            }
            if let name = controller.captureTargetName, canAttach, !controller.hasScreenAttachment {
                Button { controller.attachWindowSnapshot() } label: {
                    Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach a screenshot of the \(name) window (⌘⇧A)")
                .accessibilityIdentifier("quickAskAttachWindow")
                .clickyPointerCursor()
            }
            if controller.isBusy {
                Button { controller.stopReply() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.plain).help("Stop reply").clickyPointerCursor()
            } else {
                Button { _ = controller.submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)).foregroundStyle(Color.blue) }
                    .buttonStyle(.plain).disabled(!controller.canSubmit)
                    .accessibilityIdentifier("quickAskSend").clickyPointerCursor()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var details: some View {
        if controller.isCapturing {
            HStack(spacing: 6) {
                Text("Capturing window…")
                Button("Cancel") { controller.removeAttachment() }.buttonStyle(.plain).foregroundStyle(.blue).clickyPointerCursor()
            }
            .font(.system(size: 11)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }
        if let image = controller.attachment {
            HStack(spacing: 6) {
                if let preview = NSImage(data: image.data) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(width: 44, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Attached window screenshot")
                }
                Text(image.displayName).font(.caption2)
                Text("\(image.pixelWidth)×\(image.pixelHeight)").font(.caption2).foregroundStyle(.secondary)
                Button { controller.removeAttachment() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Remove screenshot").clickyPointerCursor()
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .environment(\.colorScheme, .dark)
            .accessibilityIdentifier("quickAskAttachment")
        }
        if let error = controller.attachmentError ?? controller.errorMessage {
            Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        if controller.presentationHasSubmission {
            Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !controller.response.isEmpty {
                ScrollView { Text(ReplyMarkdown.attributed(controller.response)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(size: 12)).foregroundStyle(.white)
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    .accessibilityIdentifier("quickAskResponse")
            }
        }
    }
}

private struct GhostHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
