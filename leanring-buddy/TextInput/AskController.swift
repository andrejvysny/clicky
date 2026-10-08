import AppKit
import Combine

@MainActor
final class AskController: ObservableObject {
    private let preferences: UserDefaults
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
    let replySpeech = LocalReplySpeech()
    @Published var speechPreference: SpeechReplyPreference {
        didSet {
            preferences.set(speechPreference.rawValue, forKey: "askSpeechPreference")
            if speechPreference != .always { replySpeech.stop() }
        }
    }
    @Published var editorGeneration = UUID()
    @Published var showSettings = false
    @Published var provider: AgentProvider {
        didSet { preferences.set(provider.rawValue, forKey: "askProvider"); refreshSession() }
    }
    @Published var workingDirectory: String {
        didSet { preferences.set(workingDirectory, forKey: "askWorkingDirectory"); refreshSession() }
    }
    @Published var claudeExecutable: String { didSet { preferences.set(claudeExecutable, forKey: "askClaudeExecutable") } }
    @Published var codexExecutable: String { didSet { preferences.set(codexExecutable, forKey: "askCodexExecutable") } }
    @Published var shortcutKeyCode: UInt32 { didSet { saveShortcut() } }
    @Published var shortcutModifiers: UInt32 { didSet { saveShortcut() } }
    @Published var shortcutWarning: String?
    var onShortcutChanged: (() -> Void)?
    var onSubmitted: (() -> Void)?

    private var inputState = AskInputState()
    private let runner = ManagedAgentRunner()
    private var responseTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var attachmentState = WindowAttachmentState()
    private let responseOverlay = CompanionResponseOverlayManager()

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--clicky-ui-test")
        let defaults = testing ? UserDefaults(suiteName: "ClickyUITests")! : UserDefaults.standard
        if testing { defaults.removePersistentDomain(forName: "ClickyUITests") }
        preferences = defaults
        provider = AgentProvider(rawValue: defaults.string(forKey: "askProvider") ?? "") ?? .preview
        speechPreference = SpeechReplyPreference(rawValue: defaults.string(forKey: "askSpeechPreference") ?? "") ?? .voiceOnly
        workingDirectory = defaults.string(forKey: "askWorkingDirectory") ?? (testing ? NSTemporaryDirectory() : NSHomeDirectory())
        claudeExecutable = defaults.string(forKey: "askClaudeExecutable") ?? Self.discover("claude")
        codexExecutable = defaults.string(forKey: "askCodexExecutable") ?? Self.discover("codex")
        shortcutKeyCode = defaults.object(forKey: "askShortcutKeyCode") == nil ? 49 : UInt32(defaults.integer(forKey: "askShortcutKeyCode"))
        shortcutModifiers = defaults.object(forKey: "askShortcutModifiers") == nil ? 0xA00 : UInt32(defaults.integer(forKey: "askShortcutModifiers"))
        refreshSession()
    }

    var canSubmit: Bool { !isBusy && !isCapturing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedExecutable: URL? {
        let path = provider == .claude ? claudeExecutable : codexExecutable
        return path.isEmpty ? nil : URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    @discardableResult
    func submit() -> Bool {
        guard !isBusy, !isCapturing else { return false }
        let directory = NSString(string: workingDirectory).expandingTildeInPath
        let request = AskRequest(text: draft, workingDirectory: directory, session: session, image: attachment)
        let generation: UInt64
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw AskError.invalidDirectory }
            if provider != .preview {
                guard let selectedExecutable, FileManager.default.isExecutableFile(atPath: selectedExecutable.path) else { throw AskError.missingExecutable(provider.displayName) }
            }
            generation = try inputState.begin(text: draft, identifier: request.identifier)
        } catch { errorMessage = error.localizedDescription; showSettings = provider != .preview; return false }

        let selectedProvider = provider
        let executable = selectedExecutable
        replySpeech.stop()
        isBusy = true
        errorMessage = nil
        response = ""
        status = selectedProvider == .preview ? "Local preview" : "Working"
        draft = ""
        removeAttachment()
        responseOverlay.showOverlayAndBeginStreaming()
        onSubmitted?()
        responseTask = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                for try await event in runner.stream(provider: selectedProvider, executable: executable, request: request) {
                    guard !Task.isCancelled, inputState.activeRequest == request.identifier, inputState.generation == generation else { return }
                    switch event {
                    case .session(let value): session = value; persistSession(value)
                    case .textDelta(let delta):
                        if inputState.append(delta, identifier: request.identifier, generation: generation) {
                            response = inputState.response
                            responseOverlay.updateStreamingText(response)
                        }
                    case .status(let message): status = message
                    case .completed: completed = true
                    }
                }
                guard inputState.activeRequest == request.identifier, inputState.generation == generation else { return }
                inputState.finish(identifier: request.identifier, generation: generation, succeeded: completed)
                status = selectedProvider == .preview ? "Preview complete · no AI request" : "Ready"
                responseOverlay.finishStreaming()
                if selectedProvider != .preview, speechPreference.shouldSpeak(voiceInitiated: false, dictation: false) {
                    replySpeech.speak(response)
                }
            } catch {
                guard inputState.activeRequest == request.identifier, inputState.generation == generation else { return }
                inputState.finish(identifier: request.identifier, generation: generation, succeeded: false)
                errorMessage = error is CancellationError ? "Reply stopped. Your question is available to retry." : error.localizedDescription
                status = "Needs attention"
                if draft.isEmpty { draft = inputState.recoveryDraft }
                responseOverlay.updateStreamingText(errorMessage ?? "The reply could not complete.")
                responseOverlay.finishStreaming()
            }
            isBusy = false
            responseTask = nil
        }
        return true
    }

    func stopReply() {
        replySpeech.stop()
        responseTask?.cancel()
        runner.cancel()
        inputState.cancel()
        if draft.isEmpty { draft = inputState.recoveryDraft }
        responseTask = nil
        isBusy = false
        status = "Stopped · question available to retry"
        responseOverlay.hideOverlay()
    }

    func dismissResponse() { responseOverlay.hideOverlay() }

    func beginPresentation(target: WindowCaptureTarget?) {
        removeAttachment()
        attachmentState.beginPresentation(target: target)
        captureTargetName = target?.applicationName
    }

    func endPresentation() {
        removeAttachment()
        attachmentState.endPresentation()
        captureTargetName = nil
    }

    func attachWindowSnapshot() {
        guard !isBusy, !isCapturing else { return }
        let lease: WindowCaptureLease
        do { lease = try attachmentState.beginCapture() }
        catch { attachmentError = error.localizedDescription; return }
        attachment = nil
        attachmentError = nil
        isCapturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await WindowSnapshotCapture.capture(lease.target)
                try Task.checkCancellation()
                guard attachmentState.accept(image, lease: lease) else { throw AttachmentError.targetChanged }
                attachment = image
            } catch {
                guard attachmentState.fail(lease: lease) else { return }
                if !(error is CancellationError) { attachmentError = error.localizedDescription }
            }
            isCapturing = false
            captureTask = nil
        }
    }

    func removeAttachment() {
        captureTask?.cancel()
        captureTask = nil
        attachmentState.discard()
        attachment = nil
        attachmentError = nil
        isCapturing = false
    }

    func newConversation() {
        guard !isBusy else { return }
        var sessions = savedSessions()
        sessions.removeValue(forKey: sessionKey)
        saveSessions(sessions)
        session = nil
        response = ""
        errorMessage = nil
        responseOverlay.hideOverlay()
        replySpeech.stop()
        removeAttachment()
    }

    func chooseDirectory() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false
        if chooser.runModal() == .OK, let url = chooser.url { workingDirectory = url.path }
    }

    func chooseExecutable() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = false
        chooser.showsHiddenFiles = true
        if chooser.runModal() == .OK, let url = chooser.url {
            if provider == .claude { claudeExecutable = url.path } else { codexExecutable = url.path }
        }
    }

    private func saveShortcut() {
        preferences.set(Int(shortcutKeyCode), forKey: "askShortcutKeyCode")
        preferences.set(Int(shortcutModifiers), forKey: "askShortcutModifiers")
        onShortcutChanged?()
    }

    private var sessionKey: String { provider.rawValue + ":" + NSString(string: workingDirectory).expandingTildeInPath }
    private func refreshSession() {
        guard !isBusy else { return }
        session = savedSessions()[sessionKey]
        response = ""
        status = "Ready"
        responseOverlay.hideOverlay()
        errorMessage = nil
        replySpeech.stop()
        removeAttachment()
    }
    private func savedSessions() -> [String: AgentSession] {
        guard let data = preferences.data(forKey: "askSessions") else { return [:] }
        return (try? JSONDecoder().decode([String: AgentSession].self, from: data)) ?? [:]
    }
    private func saveSessions(_ sessions: [String: AgentSession]) {
        if let data = try? JSONEncoder().encode(sessions) { preferences.set(data, forKey: "askSessions") }
    }
    private func persistSession(_ session: AgentSession) {
        var sessions = savedSessions()
        sessions[session.provider.rawValue + ":" + session.workingDirectory] = session
        saveSessions(sessions)
    }
    private static func discover(_ name: String) -> String {
        let directories = [NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}
