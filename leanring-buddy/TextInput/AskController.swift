import AppKit
import Combine
import SwiftUI

@MainActor
final class AskController: ObservableObject {
    private let preferences: UserDefaults
    let guide = VisualGuideController()
    let replySpeech = LocalReplySpeech()
    @Published var draft = ""
    @Published private(set) var response = ""
    @Published private(set) var status = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var session: AgentSession?
    @Published private(set) var attachment: PNGImageAttachment?
    @Published private(set) var isCapturing = false
    @Published private(set) var attachmentError: String?
    @Published private(set) var captureTargetName: String?
    @Published var editorGeneration = UUID()
    @Published private(set) var presentationHasSubmission = false
    @Published var showSettings = false
    /// Per-prompt effort; resets to Low after every submission.
    @Published private(set) var effort: AskEffort = .low
    @Published private(set) var selection: SelectionQuote?
    @Published private(set) var snippets: [PastedSnippet] = []
    @Published private(set) var busySince: Date?
    /// Quick Ask is open; the island hides its own status meanwhile.
    @Published private(set) var isComposing = false
    @Published private(set) var lastReplyAt: Date?
    @Published private(set) var lastReplyEffort: AskEffort = .low
    /// Off by default: opening Quick Ask reads nothing unless the user opts in.
    @Published var attachSelection: Bool { didSet { preferences.set(attachSelection, forKey: "askAttachSelection") } }
    @Published var speechPreference: SpeechReplyPreference {
        didSet {
            preferences.set(speechPreference.rawValue, forKey: "askSpeechPreference")
            if speechPreference != .always { replySpeech.stop() }
        }
    }
    @Published var screenInclusion: ScreenInclusionPreference {
        didSet {
            preferences.set(screenInclusion.rawValue, forKey: "askTaskSharing")
            guide.sharingPreference = screenInclusion
            if screenInclusion == .off { guide.pause(); removeAttachment() }
        }
    }
    @Published var provider: AgentProvider {
        didSet {
            guard oldValue != provider else { return }
            preferences.set(provider.rawValue, forKey: "askProvider")
            cancelLogin()
            guide.endTask(); syncGuideSettings(); response = ""; removeAttachment(); replySpeech.stop()
        }
    }
    @Published var claudeExecutable: String { didSet { preferences.set(claudeExecutable, forKey: "askClaudeExecutable"); syncGuideSettings() } }
    @Published var codexExecutable: String { didSet { preferences.set(codexExecutable, forKey: "askCodexExecutable"); syncGuideSettings() } }
    @Published private(set) var shortcutKeyCode: UInt32
    @Published private(set) var shortcutModifiers: UInt32
    @Published var shortcutWarning: String?
    var onShortcutChanged: (() -> Bool)?
    var onPointTarget: ((GuideMark) -> Void)?
    var onPointingCleared: (() -> Void)?
    var onGuideStateChanged: (() -> Void)?
    private var presentationTarget: WindowCaptureTarget?
    private var captureTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var attachmentState = WindowAttachmentState()
    private var submitAfterCapture = false

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        let defaults = testing ? UserDefaults(suiteName: "ClickyUITests")! : UserDefaults.standard
        if testing { defaults.removePersistentDomain(forName: "ClickyUITests") }
        preferences = defaults
        provider = AgentProvider(rawValue: defaults.string(forKey: "askProvider") ?? "") ?? .preview
        speechPreference = SpeechReplyPreference(rawValue: defaults.string(forKey: "askSpeechPreference") ?? "") ?? .voiceOnly
        let savedSharing = defaults.string(forKey: "askTaskSharing") ?? defaults.string(forKey: "askScreenInclusion") ?? ""
        screenInclusion = ScreenInclusionPreference.stored(savedSharing) ?? (testing ? .off : .always)
        claudeExecutable = defaults.string(forKey: "askClaudeExecutable") ?? Self.discover("claude")
        codexExecutable = defaults.string(forKey: "askCodexExecutable") ?? Self.discover("codex")
        attachSelection = defaults.bool(forKey: "askAttachSelection")
        shortcutKeyCode = defaults.object(forKey: "askShortcutKeyCode") == nil ? 49 : UInt32(defaults.integer(forKey: "askShortcutKeyCode"))
        shortcutModifiers = defaults.object(forKey: "askShortcutModifiers") == nil ? 0xA00 : UInt32(defaults.integer(forKey: "askShortcutModifiers"))
        defaults.removeObject(forKey: "askSessions")
        defaults.removeObject(forKey: "askWorkingDirectory")
        // The old persisted display approval becomes a preference; live consent is per running process.
        GuideDisplayConsent.migrate(defaults)
        syncGuideSettings()
        guide.onResponse = { [weak self] value in self?.showResponse(value) }
        guide.defaults = defaults
        guide.onTarget = { [weak self] mark in self?.onPointTarget?(mark) }
        guide.onClearTarget = { [weak self] in self?.onPointingCleared?() }
        guide.onStateChanged = { [weak self] in self?.syncGuideState() }
    }
    var hasScreenAttachment: Bool { guide.task?.grant?.paused == false }
    var canSubmit: Bool { !isBusy && AskComposition.hasContent(draft: draft, selection: selection, snippets: snippets) }
    var effortAdjustable: Bool { guide.effortAdjustable && !isBusy }
    /// What the next prompt will actually use: a running Claude task keeps its launch effort.
    var displayedEffort: AskEffort { provider == .claude && guide.agent != nil && guide.task != nil ? guide.agentEffort : effort }
    var selectedExecutable: URL? {
        let path = provider == .claude ? claudeExecutable : codexExecutable
        return path.isEmpty ? nil : URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    @discardableResult
    func submit() -> Bool {
        guard !isBusy else { return false }
        if isCapturing { submitAfterCapture = canSubmit; return submitAfterCapture }
        guard canSubmit else { return false }
        do {
            if provider != .preview {
                guard let selectedExecutable, FileManager.default.isExecutableFile(atPath: selectedExecutable.path) else { throw AskError.missingExecutable(provider.displayName) }
            }
            syncGuideSettings(); replySpeech.stop()
            let message = AskComposition.message(draft: draft, selection: selection, snippets: snippets)
            try guide.ask(message, target: presentationTarget, explicitlyVisual: attachment != nil, effort: effort)
            draft = ""; response = ""; errorMessage = nil; presentationHasSubmission = true
            selection = nil; snippets = []; effort = .low
            removeAttachment(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func stopReply() {
        guide.pause(message: "Stopped · Retry explicitly")
        if draft.isEmpty { draft = guide.lastUserText }
        replySpeech.stop()
    }
    /// Clears a failed request's message without ending the conversation.
    func dismissError() { guide.error = nil; errorMessage = nil; attachmentError = nil }
    func copyResponse() {
        guard !response.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(response, forType: .string)
    }
    /// A step card is on screen and accepts Next/Retry shortcuts.
    var guideStepActive: Bool {
        if let demo = guide.demo { return !demo.completed && !demo.paused }
        guard guide.task?.step != nil, let phase = guide.task?.phase else { return false }
        return [.waiting, .verifying, .uncertain].contains(phase)
    }
    func guideNextShortcut() { guide.nextManually() }
    func guideRetryShortcut() { guide.task?.phase == .uncertain ? guide.checkNow() : guide.retry() }
    func guideBackShortcut() { guide.back() }
    func guideEndShortcut() { guide.endTask() }
    func speakResponse() { if !response.isEmpty { replySpeech.speak(response) } }
    func cycleEffort() { if effortAdjustable { effort = effort.next } }
    func removeSelection() { selection = nil }
    func removeSnippet(_ id: UUID) { snippets.removeAll { $0.id == id } }
    func addSnippet(_ text: String) { if !isBusy { snippets.append(PastedSnippet(text: text)) } }
    func newConversation() { guide.endTask(); response = ""; errorMessage = nil; removeAttachment(); replySpeech.stop(); lastReplyAt = nil }
    func beginPresentation(target: WindowCaptureTarget?) {
        isComposing = true
        presentationHasSubmission = false; removeAttachment(); presentationTarget = target
        snippets = []
        selection = attachSelection ? target.flatMap { target in
            ScopedAccessibility.selectedText(target).flatMap { SelectionQuote(text: $0, applicationName: target.applicationName) }
        } : nil
        attachmentState.beginPresentation(target: target); captureTargetName = target?.applicationName
        guide.composerWillOpen()
    }
    func endPresentation() {
        isComposing = false
        removeAttachment(); attachmentState.endPresentation(); captureTargetName = nil; selection = nil
        guide.composerDidClose(submitted: presentationHasSubmission)
    }
    func attachWindowSnapshot() {
        guard !isBusy, !isCapturing else { return }
        let lease: WindowCaptureLease
        do { lease = try attachmentState.beginCapture() }
        catch { attachmentError = error.localizedDescription; return }
        attachment = nil; attachmentError = nil; isCapturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await WindowSnapshotCapture.capture(lease.target)
                try Task.checkCancellation()
                guard attachmentState.accept(image, lease: lease) else { return }
                attachment = image
            } catch {
                guard attachmentState.fail(lease: lease) else { return }
                if !(error is CancellationError) { attachmentError = error.localizedDescription }
            }
            isCapturing = false; captureTask = nil
            if submitAfterCapture {
                submitAfterCapture = false
                if attachmentError == nil { _ = submit() }
            }
        }
    }
    func toggleScreenAttachment() {
        if let grant = guide.task?.grant {
            if !grant.paused { guide.pause() }
            else { attachmentError = "Sharing is paused while editing. Close Quick Ask and use Resume in the guide controls." }
            return
        }
        if let presentationTarget, guide.task != nil { guide.authorizeWindow(presentationTarget) }
        else { attachmentError = "This window will be shared only if your submitted task needs visual context." }
    }
    func removeAttachment() {
        captureTask?.cancel(); captureTask = nil; attachmentState.discard()
        attachment = nil; attachmentError = nil; isCapturing = false; submitAfterCapture = false
    }
    func chooseExecutable() {
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.canChooseFiles = true; chooser.allowsMultipleSelection = false
        if chooser.runModal() == .OK, let url = chooser.url {
            if provider == .claude { claudeExecutable = url.path } else { codexExecutable = url.path }
        }
    }
    func updateShortcut(keyCode: UInt32, modifiers: UInt32) {
        let previous = (shortcutKeyCode, shortcutModifiers)
        shortcutKeyCode = keyCode; shortcutModifiers = modifiers
        if onShortcutChanged?() ?? true {
            preferences.set(Int(keyCode), forKey: "askShortcutKeyCode"); preferences.set(Int(modifiers), forKey: "askShortcutModifiers"); return
        }
        shortcutKeyCode = previous.0; shortcutModifiers = previous.1
        shortcutWarning = (onShortcutChanged?() ?? false) ? "That shortcut is unavailable. The previous shortcut is still active." : "Quick Ask shortcut is unavailable. Use the menu bar."
    }
    func signInCodex() {
        guard loginTask == nil, let executable = selectedExecutable, provider == .codex else { return }
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try GuideAgentProfile(provider: .codex, root: guide.profileRoot, taskID: UUID())
                for try await event in GuideCodexLogin.signIn(executable: executable, profile: profile) {
                    try Task.checkCancellation()
                    switch event {
                    case .authorizationURL(let url): NSWorkspace.shared.open(url); status = "Complete official Codex sign-in in your browser"
                    case .completed: status = "Clicky's Codex profile is signed in"
                    }
                }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            loginTask = nil
        }
    }
    private func syncGuideSettings() {
        guide.provider = provider; guide.executable = selectedExecutable; guide.sharingPreference = screenInclusion
    }
    func cancelLogin() { loginTask?.cancel(); loginTask = nil }
    func shutdown() { cancelLogin(); removeAttachment(); guide.endTask(); replySpeech.stop() }
    private func syncGuideState() {
        if guide.isBusy != isBusy { busySince = guide.isBusy ? Date() : nil }
        status = guide.status; errorMessage = guide.error; isBusy = guide.isBusy; session = guide.session
        if guide.error != nil, draft.isEmpty { draft = guide.lastUserText }
        onGuideStateChanged?()
    }
    private func showResponse(_ value: String) {
        response = value; lastReplyAt = Date(); lastReplyEffort = guide.replyEffort
        if provider != .preview, speechPreference.shouldSpeak(voiceInitiated: false, dictation: false) { replySpeech.speak(value) }
    }
    private static func discover(_ name: String) -> String {
        let directories = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}
