import AppKit
import Combine
import SwiftUI

/// Floating status for voice input: recording progress, processing stage, Load prompt, dictation review and results.
/// The panel is nonactivating and never key, so showing it never steals focus from the application being dictated
/// into; its buttons accept clicks without activating Clicky. The single exception is the review text editor: a click
/// into it lets this panel become key (still without activating the app) so the user can type corrections.
@MainActor
final class VoiceStatusPanelController {
    private let voice: VoiceController
    private var panel: VoicePanel?
    private var cancellables: Set<AnyCancellable> = []
    private var anchoredTop: CGFloat?
    private var anchorPointer = CGPoint.zero
    private var layoutScheduled = false

    init(voice: VoiceController) {
        self.voice = voice
        voice.objectWillChange.sink { [weak self] in self?.scheduleLayout() }.store(in: &cancellables)
    }

    /// Ask-mode progress is shown on the Quick Ask card itself; everything else lives here.
    private var visible: Bool {
        switch voice.phase {
        case .idle: return false
        case .recording(let mode, _, _, _, _), .transcribing(let mode), .cleaning(let mode): return mode == .dictate
        default: return true
        }
    }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        // objectWillChange fires before the change; measure on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutScheduled = false
            applyLayout()
        }
    }

    private func applyLayout() {
        guard visible else {
            anchoredTop = nil
            panel?.releaseKeyboard()
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        if case .review = voice.phase {} else { panel.releaseKeyboard() }
        if !panel.isVisible { anchorPointer = NSEvent.mouseLocation; anchoredTop = nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPointer) }) ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        guard ShellPanelLayout.isValid(visibleFrame) else { return }
        let width = VoiceStatusView.width
        let height = ShellPanelLayout.height(measured: panel.contentView?.fittingSize.height ?? 60, minimum: 30,
                                             maximum: visibleFrame.height)
        var frame = PopupPlacement.besideCompanion(pointer: anchorPointer, size: CGSize(width: width, height: height), visibleFrame: visibleFrame)
        let top = anchoredTop ?? frame.maxY
        anchoredTop = top
        frame = ShellPanelLayout.anchoredFrame(frame, top: top, visibleFrame: visibleFrame)
        guard ShellPanelLayout.isValid(frame) else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> VoicePanel {
        let panel = VoicePanel(contentRect: CGRect(x: 0, y: 0, width: VoiceStatusView.width, height: 60),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityIdentifier("voiceStatusPanel")
        panel.onCancel = { [weak self] in self?.voice.cancel() }
        let host = NSHostingView(rootView: VoiceStatusView(voice: voice))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Overlays to exclude from any capture.
    var windowNumbers: Set<Int> { panel.map { $0.windowNumber > 0 ? [$0.windowNumber] : [] } ?? [] }
}

/// Never key and never main, except while the user edits the dictation review text.
private final class VoicePanel: NSPanel {
    var onCancel: (() -> Void)?
    private var keyAllowed = false
    override var canBecomeKey: Bool { keyAllowed }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func allowKeyboard() {
        keyAllowed = true
        makeKey()
    }

    /// Gives keyboard focus back to whatever had it; the panel stays on screen without being key.
    func releaseKeyboard() {
        guard keyAllowed else { return }
        keyAllowed = false
        if isKeyWindow { orderOut(nil); orderFrontRegardless() }
    }
}

struct VoiceStatusView: View {
    static let width: CGFloat = 340
    @ObservedObject var voice: VoiceController

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: Self.width, alignment: .leading)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voiceStatus")
    }

    @ViewBuilder private var content: some View {
        switch voice.phase {
        case .idle: EmptyView()
        case .requestingPermission: progress("Waiting for microphone permission…", cancel: true)
        case .needsSpeechModels: needsModels
        case .recording(let mode, let elapsed, let limit, let deviceName, let level): recording(mode, elapsed, limit, deviceName, level)
        case .transcribing: progress(voice.statusNote ?? "Transcribing…", cancel: true)
        case .cleaning: progress("Cleaning up…", cancel: true)
        case .inserting: progress(voice.undoing ? "Undoing…" : "Inserting…", cancel: true)
        case .inserted(let outcome): inserted(outcome)
        case .review(let review): VoiceReviewView(voice: voice, writer: voice.writer, review: review)
        case .result(let message): Text(message).font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
        case .failed(let message): failed(message)
        }
    }

    private func label(_ mode: InputMode) -> String { mode == .dictate ? "Dictating" : "Asking" }

    private func recording(_ mode: InputMode, _ elapsed: Double, _ limit: Double, _ deviceName: String, _ level: Float) -> some View {
        let warning = VoiceRecordingLimits(maximumSeconds: limit).isWarning(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: DS.Colors.destructiveText, glow: true)
                Text(label(mode)).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary)
                Text("\(VoiceText.clock(elapsed)) / \(VoiceText.clock(limit))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(warning ? DS.Colors.warningText : DS.Colors.textSecondary)
                Spacer(minLength: 4)
                Button("Stop") { voice.stop() }.islandButton(.primary).accessibilityIdentifier("voiceStop")
                Button("Cancel") { voice.cancel() }.islandButton(.quiet).accessibilityIdentifier("voiceCancel")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(ClickyChrome.ask).frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
                }
            }
            .frame(height: 3)
            Text(deviceName).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            if let note = voice.statusNote {
                Text(note).font(.system(size: 10)).foregroundStyle(DS.Colors.warningText)
            }
            if voice.bluetoothMicrophone {
                Text("Bluetooth mic — quality may be lower").font(.system(size: 10)).foregroundStyle(DS.Colors.warningText)
            }
            if warning {
                Text("Recording stops at \(VoiceText.clock(limit)).").font(.system(size: 10)).foregroundStyle(DS.Colors.warningText)
            }
        }
    }

    private func progress(_ text: String, cancel: Bool) -> some View {
        HStack(spacing: 8) {
            SpinnerRing(size: 10)
            Text(text).font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary).lineLimit(2)
            Spacer(minLength: 4)
            if cancel { Button("Cancel") { voice.cancel() }.islandButton(.quiet).accessibilityIdentifier("voiceCancel") }
        }
    }

    private var needsModels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The speech models are not loaded. Nothing was recorded.").font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Load speech pipeline") { voice.loadSpeechModels() }.islandButton(.primary)
                    .disabled(voice.isLoadingModels).accessibilityIdentifier("voiceLoad")
                if voice.isLoadingModels { SpinnerRing(size: 10) }
                Spacer()
                Button("Dismiss") { voice.dismiss() }.islandButton(.quiet)
            }
        }
    }

    private func inserted(_ outcome: VoiceInsertedOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(outcome.message).font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
            if outcome.canUndo || outcome.offersOriginal {
                HStack(spacing: 6) {
                    if outcome.canUndo { Button("Undo") { voice.undoInsertion() }.islandButton(.secondary).accessibilityIdentifier("voiceUndo") }
                    if outcome.offersOriginal {
                        Button("Copy original") { voice.copyOriginalTranscript() }.islandButton(.secondary)
                            .accessibilityIdentifier("voiceCopyOriginal")
                    }
                    Spacer()
                    Button("Dismiss") { voice.dismiss() }.islandButton(.quiet)
                }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.system(size: 12)).foregroundStyle(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if voice.offersMicrophoneSettings {
                    Button("Open Settings") { voice.openMicrophoneSettings() }.islandButton(.primary).accessibilityIdentifier("voiceOpenSettings")
                }
                Spacer()
                Button("Dismiss") { voice.dismiss() }.islandButton(.quiet)
            }
        }
    }
}

/// Dictation that was not inserted automatically: editable text plus Insert, original, Copy and Discard.
private struct VoiceReviewView: View {
    let voice: VoiceController
    @ObservedObject var writer: WritingCoordinator
    let review: DictationReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.headline).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(review.concerns, id: \.self) { concern in
                Text("• " + concern).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText).fixedSize(horizontal: false, vertical: true)
            }
            VoiceReviewEditor(text: $writer.previewText)
                .frame(height: 96)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let note = review.note {
                Text(note).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Insert") { voice.insertReview() }.islandButton(.primary).disabled(!review.canInsert)
                    .accessibilityIdentifier("voiceInsert")
                if review.offersOriginal || writer.previewText != review.raw {
                    Button("Use original transcript") { voice.useOriginalTranscript() }.islandButton(.secondary)
                        .disabled(writer.previewText == review.raw)
                }
                Button("Copy") { voice.copyReview() }.islandButton(.secondary).accessibilityIdentifier("voiceCopy")
                Spacer(minLength: 2)
                Button("Discard") { voice.discardReview() }.islandButton(.quiet).accessibilityIdentifier("voiceDiscard")
            }
        }
    }
}

/// Plain-text editor whose first click lets the nonactivating panel take keyboard focus.
private struct VoiceReviewEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let editor = ReviewTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.string = text
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? NSTextView, editor.string != text, !editor.hasMarkedText() else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VoiceReviewEditor
        init(_ parent: VoiceReviewEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class ReviewTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        (window as? VoicePanel)?.allowKeyboard()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
