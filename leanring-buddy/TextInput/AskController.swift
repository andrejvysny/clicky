import AppKit
import Combine
import SwiftUI

@MainActor
final class AskController: ObservableObject {
    private let preferences: UserDefaults
    let guide = VisualGuideController()
    let writingDefinitions: WritingDefinitionsStore
    /// Host-controlled Write/Rewrite/snippet transactions; separate from guide conversations.
    let writing: WritingCoordinator
    private let writingTargets: WritingNativeTargets
    /// Guide observation stays held until a host edit finishes, so synthetic paste never counts as a user action.
    private var composerClosePending: Bool?
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
    /// Per-prompt effort; resets to Low after every submission.
    @Published private(set) var effort: AskEffort = .low
    @Published private(set) var selection: SelectionQuote?
    @Published private(set) var snippets: [PastedSnippet] = []
    @Published private(set) var busySince: Date?
    /// Quick Ask is open; the island hides its own status meanwhile.
    @Published private(set) var isComposing = false
    @Published private(set) var lastReplyAt: Date?
    @Published private(set) var lastReplyEffort: AskEffort = .low
    /// One line about a voice session started from Quick Ask (never transcript text); nil when none is running.
    @Published private(set) var voiceStatus: VoiceAskStatus?
    /// Explains how the voice text in the draft was produced, e.g. "Cleaned up · Use original".
    @Published private(set) var voiceDraftNote: String?
    private var voiceNoteOffersOriginal = false
    var onVoiceStop: (() -> Void)?
    var onVoiceCancel: (() -> Void)?
    /// The span of `draft` (UTF-16 offsets) that voice placed, with the text it holds and the original transcript.
    private var voiceSpan: VoiceDraftSpan?
    /// The next submission came from a voice-placed draft, so `.voiceOnly` reply speech applies to its answer.
    private var voiceInitiatedPending = false
    private var replyVoiceInitiated = false
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
            guide.endTask(); writing.reset(); syncGuideSettings(); response = ""; removeAttachment(); replySpeech.stop()
            if writingFollowsBackend { writingProvider = provider }
        }
    }
    /// "Same as backend": writing uses the chat provider and follows it when it changes.
    @Published var writingFollowsBackend: Bool {
        didSet {
            preferences.set(writingFollowsBackend, forKey: "askWritingFollowsBackend")
            if writingFollowsBackend { writingProvider = provider }
        }
    }
    /// Writing (Write/Rewrite/skills) has its own provider; it starts as whatever the shared provider was, so
    /// splitting the preference changes nothing until the user picks a different one.
    @Published var writingProvider: AgentProvider {
        didSet {
            guard oldValue != writingProvider else { return }
            preferences.set(writingProvider.rawValue, forKey: "askWritingProvider")
            writing.reset(); syncGuideSettings()
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
    /// A submission made before the writing destination finished binding; routed once the binding is known.
    private var submitAfterBinding = false

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        let defaults = testing ? UserDefaults(suiteName: "ClickyUITests")! : UserDefaults.standard
        if testing { defaults.removePersistentDomain(forName: "ClickyUITests") }
        preferences = defaults
        writingDefinitions = WritingDefinitionsStore(defaults: defaults)
        let targets = WritingNativeTargets()
        writingTargets = targets
        writing = WritingCoordinator(environment: targets.environment)
        let sharedProvider = AgentProvider(rawValue: defaults.string(forKey: "askProvider") ?? "") ?? .preview
        provider = sharedProvider
        if defaults.string(forKey: "askWritingProvider") == nil { defaults.set(sharedProvider.rawValue, forKey: "askWritingProvider") }
        let savedWritingProvider = AgentProvider(rawValue: defaults.string(forKey: "askWritingProvider") ?? "") ?? sharedProvider
        writingProvider = savedWritingProvider
        // Before this preference existed, a writing provider equal to the backend behaved as "same as backend".
        writingFollowsBackend = defaults.object(forKey: "askWritingFollowsBackend") as? Bool ?? (savedWritingProvider == sharedProvider)
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
        writing.profileRoot = guide.profileRoot
        writing.definitions = { [weak self] in self?.writingDefinitions.definitions ?? .empty }
        writing.onApplyFinished = { [weak self] in self?.releaseComposerHold() }
    }
    var hasScreenAttachment: Bool { guide.task?.grant?.paused == false }
    var canSubmit: Bool { !isBusy && AskComposition.hasContent(draft: draft, selection: selection, snippets: snippets) }
    var effortAdjustable: Bool { guide.effortAdjustable && !isBusy }
    /// What the next prompt will actually use: a running Claude task keeps its launch effort.
    var displayedEffort: AskEffort { provider == .claude && guide.agent != nil && guide.task != nil ? guide.agentEffort : effort }
    var selectedExecutable: URL? { executable(for: provider) }
    var writingExecutable: URL? { executable(for: writingProvider) }
    private func executable(for provider: AgentProvider) -> URL? {
        guard provider.needsExecutable else { return nil }
        let path = provider == .claude ? claudeExecutable : codexExecutable
        return path.isEmpty ? nil : URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    @discardableResult
    func submit() -> Bool {
        guard !isBusy, !writing.isBusy else { return false }
        var chatText = draft
        if !isCapturing {
            switch routeWriting() {
            case .handled(let accepted): return accepted
            case .chat(let text): chatText = text
            }
        }
        if isCapturing { submitAfterCapture = canSubmit; return submitAfterCapture }
        guard canSubmit else { return false }
        do {
            if provider.needsExecutable {
                guard let selectedExecutable, FileManager.default.isExecutableFile(atPath: selectedExecutable.path) else { throw AskError.missingExecutable(provider.displayName) }
            }
            syncGuideSettings(); replySpeech.stop()
            let message = AskComposition.message(draft: chatText, selection: selection, snippets: snippets)
            try guide.ask(message, target: presentationTarget, explicitlyVisual: attachment != nil, effort: effort)
            draft = ""; response = ""; errorMessage = nil; presentationHasSubmission = true
            selection = nil; snippets = []; effort = .low
            replyVoiceInitiated = voiceInitiatedPending; clearVoiceDraft()
            removeAttachment(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func stopReply() {
        if writing.isBusy { writing.stop(); return }
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
    /// While viewing history ⌥⇧→ moves forward; otherwise it is the explicit, unverified manual Next.
    func guideNextShortcut() { guide.task?.historyIndex != nil ? guide.forward() : guide.nextManually() }
    func guideRetryShortcut() { guide.task?.phase == .uncertain ? guide.checkNow() : guide.retry() }
    func guideBackShortcut() { guide.back() }
    func guideEndShortcut() { guide.endTask() }
    func speakResponse() { if !response.isEmpty { replySpeech.speak(response) } }
    func cycleEffort() { if effortAdjustable { effort = effort.next } }
    func removeSelection() { selection = nil }
    func removeSnippet(_ id: UUID) { snippets.removeAll { $0.id == id } }
    func addSnippet(_ text: String) { if !isBusy { snippets.append(PastedSnippet(text: text)) } }
    func newConversation() { writing.discard(); guide.endTask(); response = ""; errorMessage = nil; removeAttachment(); replySpeech.stop(); lastReplyAt = nil; clearVoiceDraft(); replyVoiceInitiated = false }
    func beginPresentation(target: WindowCaptureTarget?) {
        isComposing = true
        presentationHasSubmission = false; removeAttachment(); presentationTarget = target
        snippets = []
        selection = attachSelection ? target.flatMap { target in
            ScopedAccessibility.selectedText(target).flatMap { SelectionQuote(text: $0, applicationName: target.applicationName) }
        } : nil
        attachmentState.beginPresentation(target: target); captureTargetName = target?.applicationName
        guide.composerWillOpen()
        // Bound before the panel is key; metadata only, no field content.
        let process = target?.displayIdentifier == nil ? target?.processIdentifier : nil
        writing.beginBinding(processIdentifier: process)
    }
    func endPresentation() {
        isComposing = false; submitAfterBinding = false
        removeAttachment(); attachmentState.endPresentation(); captureTargetName = nil; selection = nil
        if writing.phase == .applying { composerClosePending = presentationHasSubmission }
        else { guide.composerDidClose(submitted: presentationHasSubmission) }
    }

    private func releaseComposerHold() {
        guard let submitted = composerClosePending else { return }
        composerClosePending = nil
        if !isComposing { guide.composerDidClose(submitted: submitted) }
    }

    private enum WritingRouting { case handled(Bool), chat(String) }

    /// Slash commands and plainly worded writing requests go to the writing coordinator; questions stay chat.
    private func routeWriting() -> WritingRouting {
        // Routing depends on the bound destination (selection, editability); never decide it from a missing binding.
        if writing.isBinding {
            submitAfterBinding = true
            writing.whenBound { [weak self] in
                guard let self, submitAfterBinding, isComposing else { return }
                submitAfterBinding = false
                _ = submit()
            }
            return .handled(true)
        }
        let target = writing.target
        let route = QuickAskRoute.route(draft: draft, definitions: writingDefinitions.definitions,
                                        hasSelection: target?.mayHaveSelection ?? false,
                                        hasEditableTarget: target.map { $0.blockedReason == nil } ?? false)
        switch route {
        case .chat(let text):
            // A plain follow-up while a draft is under review refines it instead of starting a chat.
            if writing.canRefine, SlashParser.parse(draft) == .text(draft) {
                writing.refine(text); draft = ""; errorMessage = nil; return .handled(true)
            }
            return .chat(text)
        case .localError(let message):
            errorMessage = message; return .handled(false)
        case .snippet, .write, .rewrite:
            if case .snippet = route {} else if writingProvider.needsExecutable {
                guard let writingExecutable, FileManager.default.isExecutableFile(atPath: writingExecutable.path) else {
                    errorMessage = AskError.missingExecutable(writingProvider.displayName).localizedDescription; return .handled(false)
                }
            }
            syncGuideSettings(); replySpeech.stop()
            // Visible attachments travel with the writing request as reference material instead of being dropped.
            let started = writing.start(route, effort: effort, reference: writingReference())
            if started {
                draft = ""; errorMessage = nil; presentationHasSubmission = true; effort = .low
                // A literal snippet does not use attachments; they stay visible instead of being silently dropped.
                if case .snippet = route {} else { snippets = []; selection = nil }
            }
            return .handled(started)
        }
    }
    /// The attached selection quote and pasted chips, verbatim and in display order; nil when none are attached.
    private func writingReference() -> String? {
        let parts = [selection?.text].compactMap { $0 } + snippets.map(\.text)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Voice

    /// Places voice text in the draft without sending it. An empty draft receives the text; anything the user already
    /// wrote is kept in place and the voice text is appended on a new line. Only Enter submits.
    func insertVoiceDraft(_ text: String, raw: String, concerns: [CleanupConcern], cleanupFailed: Bool = false) {
        guard !text.isEmpty else { return }
        voiceSpan = VoiceDraftPlacement.place(text: text, raw: raw, in: &draft)
        voiceInitiatedPending = true
        let described = VoiceDraftPlacement.note(text: text, raw: raw, concerns: concerns, cleanupFailed: cleanupFailed)
        voiceDraftNote = described.note
        voiceNoteOffersOriginal = described.offersOriginal
    }

    /// True while the voice-placed span is still exactly as placed and differs from the original transcript.
    var canUseOriginalVoiceTranscript: Bool { VoiceDraftPlacement.canUseOriginal(voiceSpan, in: draft) }

    /// Swaps exactly the voice-placed span for the original transcript; refuses when the user edited it.
    func useOriginalVoiceTranscript() {
        guard let span = voiceSpan, let updated = VoiceDraftPlacement.useOriginal(span, in: &draft) else { return }
        voiceSpan = updated
        voiceDraftNote = nil
    }

    /// The note to show now: the "Use original" offer disappears once the placed text was edited.
    var visibleVoiceNote: String? {
        guard let note = voiceDraftNote else { return nil }
        return voiceNoteOffersOriginal && !canUseOriginalVoiceTranscript ? nil : note
    }

    func setVoiceStatus(_ status: VoiceAskStatus?) { if voiceStatus != status { voiceStatus = status } }

    private func clearVoiceDraft() { voiceSpan = nil; voiceDraftNote = nil; voiceInitiatedPending = false }

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
        writing.provider = writingProvider; writing.executable = writingExecutable
    }
    func cancelLogin() { loginTask?.cancel(); loginTask = nil }
    func shutdown() { writing.reset(); cancelLogin(); removeAttachment(); guide.endTask(); replySpeech.stop() }
    private func syncGuideState() {
        if guide.isBusy != isBusy { busySince = guide.isBusy ? Date() : nil }
        status = guide.status; errorMessage = guide.error; isBusy = guide.isBusy; session = guide.session
        if guide.error != nil, draft.isEmpty { draft = guide.lastUserText }
        onGuideStateChanged?()
    }
    private func showResponse(_ value: String) {
        response = value; lastReplyAt = Date(); lastReplyEffort = guide.replyEffort
        if provider != .preview, speechPreference.shouldSpeak(voiceInitiated: replyVoiceInitiated, dictation: false) { replySpeech.speak(value) }
    }
    private static func discover(_ name: String) -> String {
        let directories = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}
