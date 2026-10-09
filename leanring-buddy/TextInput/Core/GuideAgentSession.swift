import Foundation

nonisolated public struct GuideAgentTurn: Sendable {
    public let message: String
    public let image: PNGImageAttachment?
    public let context: GuideCaptureContext?
    public let purpose: GuideRequestPurpose
    public let taskContext: GuideHostTaskContext?
    public var effort: AskEffort
    public let writing: WritingHostPayload?
    public init(message: String, image: PNGImageAttachment? = nil, context: GuideCaptureContext? = nil,
                purpose: GuideRequestPurpose = .planning, taskContext: GuideHostTaskContext? = nil, effort: AskEffort = .low,
                writing: WritingHostPayload? = nil) {
        self.message = message; self.image = image; self.context = context
        self.purpose = purpose; self.taskContext = taskContext; self.effort = effort; self.writing = writing
    }
    public var text: String {
        let request = GuideHostRequest(purpose: purpose, text: message, task: taskContext, capture: context, writing: writing)
        return String(decoding: try! JSONEncoder().encode(request), as: UTF8.self)
    }
    public var codexInput: [JSONValue] {
        var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        if let image { input.append(.object(["type": .string("image"), "url": .string(image.dataURL)])) }
        return input
    }
}

/// The provider conversation the walkthrough coordinator talks to; tests substitute a scripted fake.
nonisolated public protocol GuideAgentRunning: Sendable {
    func turn(_ request: GuideAgentTurn) async throws -> GuidePresentation
    func identifier() async -> String?
    func close() async
}

extension GuideAgentRunning {
    /// Sends the turn; a reply of a kind the purpose forbids gets exactly one text-only corrective turn on the same
    /// capture (the provider already has the image and any writing source, which is never resent). Returns the
    /// presentation and whether a correction was needed.
    public func turnAllowingOneCorrection(_ request: GuideAgentTurn) async throws -> (GuidePresentation, corrected: Bool) {
        do { return (try await turn(request), false) }
        catch let wrong as GuideWrongPurpose {
            let correction = GuideAgentTurn(message: GuideHostMessages.wrongPurpose(wrong), context: request.context,
                                            purpose: request.purpose, taskContext: request.taskContext, effort: request.effort)
            return (try await turn(correction), true)
        }
    }
}

public actor GuideAgentSession: GuideAgentRunning {
    private let profile: GuideAgentProfile
    private let executable: URL
    private let validateProfile: Bool
    private var process: AgentProcess?
    private var pump: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var pending: CheckedContinuation<GuidePresentation, Error>?
    private var pendingTurn: GuideAgentTurn?
    private var pendingPurpose: GuideRequestPurpose?
    private var codex: GuideCodexProtocol
    private var response = ""
    private var ready = false
    private var sessionIdentifier: String?
    private var closed = false
    private var policyRequestID: String?
    private var claudeTurnID: UUID?
    private let timeoutNanoseconds: UInt64
    private let onUnexpectedExit: (@Sendable (String) -> Void)?

    public init(profile: GuideAgentProfile, executable: URL, validateProfile: Bool = true,
                timeoutNanoseconds: UInt64 = 300_000_000_000,
                onUnexpectedExit: (@Sendable (String) -> Void)? = nil) {
        self.profile = profile; self.executable = executable; self.validateProfile = validateProfile
        self.timeoutNanoseconds = timeoutNanoseconds
        self.onUnexpectedExit = onUnexpectedExit
        codex = GuideCodexProtocol(directory: profile.workingDirectory.path, contract: profile.contract)
    }

    public func turn(_ request: GuideAgentTurn) async throws -> GuidePresentation {
        guard !closed else { throw AskError.incompleteTurn }
        guard pending == nil else { throw AskError.busy }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; pendingTurn = request; pendingPurpose = request.purpose; response = ""
                do {
                    if process == nil { try launch() }
                    else { try sendPendingTurn() }
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0) }
                        catch { return }
                        await self?.fail(AskError.protocolFailure("The agent turn timed out. Retry explicitly with fresh context."))
                    }
                } catch { fail(error) }
            }
        } onCancel: { Task { await self.close() } }
    }

    public func identifier() -> String? { sessionIdentifier }
    public func close() {
        let hadProcess = process != nil
        closed = true; timeout?.cancel(); pump?.cancel(); process?.stop(); process = nil
        let continuation = pending; pending = nil; pendingTurn = nil; response = ""
        pendingPurpose = nil; continuation?.resume(throwing: CancellationError())
        if !hadProcess { profile.removeTaskFiles() }
    }

    private func launch() throws {
        if validateProfile { try profile.validate(executable: executable) }
        let child = try AgentProcess(executable: executable, arguments: profile.arguments,
                                     workingDirectory: profile.workingDirectory.path, environment: profile.environment,
                                     onExit: { [profile] in profile.removeTaskFiles() })
        let messages = try child.start()
        process = child
        pump = Task.detached { [weak self] in
            do {
                for try await message in messages { await self?.receive(message) }
                await self?.fail(AskError.incompleteTurn)
            } catch { await self?.fail(error) }
        }
        if profile.provider == .codex { try child.send(codex.initialize()) }
        else { try child.send(GuideClaudePolicy.control("initialize", identifier: "clicky-init")) }
    }

    private func sendPendingTurn() throws {
        guard let pendingTurn, let process else { return }
        if profile.provider == .codex {
            guard codex.threadID != nil else { return }
            try process.send(codex.startTurn(input: pendingTurn.codexInput, effort: pendingTurn.effort, purpose: pendingTurn.purpose))
        } else {
            policyRequestID = UUID().uuidString
            try process.send(GuideClaudePolicy.control("get_settings", identifier: policyRequestID!))
            return
        }
        self.pendingTurn = nil
    }

    private func receive(_ message: JSONValue) {
        guard !closed else { return }
        do {
            if profile.provider == .claude { try receiveClaude(message) }
            else { try receiveCodex(message) }
        } catch { fail(error) }
    }

    private func receiveClaude(_ message: JSONValue) throws {
        if message["type"].string == "control_response" {
            let response = message["response"]
            guard response["subtype"].string == "success" else { throw AskError.protocolFailure("Claude cannot audit its effective settings. Select a supported version.") }
            if response["request_id"].string == "clicky-init" { try sendPendingTurn() }
            else if response["request_id"].string == policyRequestID {
                try GuideClaudePolicy.audit(response["response"])
                guard let turn = pendingTurn else { throw AskError.incompleteTurn }
                policyRequestID = nil; pendingTurn = nil
                claudeTurnID = UUID()
                // Keep stdin open: --no-session-persistence cannot resume a terminated conversation.
                try process?.send(AgentProtocol.claudePrompt(turn.text, image: turn.image,
                                                           includePointingInstructions: false, identifier: claudeTurnID))
            }
            return
        }
        if message["type"].string == "system", message["subtype"].string == "init" {
            let builtinPlugins = ["cc-plugin-agents-md", "cc-plugin-telemetry", "cc-plugin-plugin-authoring"]
            guard message["model"].string == GuideAgentProfile.claudeModel,
                  case .array(let tools) = message["tools"], tools.allSatisfy({ $0.string == "StructuredOutput" }),
                  message["mcp_servers"] == .array([]), message["skills"] == .array([]),
                  case .array(let plugins) = message["plugins"], plugins.allSatisfy({
                      $0["path"].string == "builtin" && builtinPlugins.contains($0["name"].string ?? "")
                  }) else {
                throw AskError.protocolFailure("Claude loaded capabilities outside Clicky's clean profile.")
            }
            sessionIdentifier = message["session_id"].string; ready = true
        }
        if message["type"].string == "system", message["subtype"].string?.hasPrefix("hook_") == true {
            throw AskError.protocolFailure("Claude loaded a managed hook; clean guidance is unavailable.")
        }
        guard message["type"].string == "result" else { return }
        guard pending != nil, let claudeTurnID else { return }
        guard let incoming = message["user_message_uuid"].string.flatMap(UUID.init(uuidString:)) else {
            throw AskError.protocolFailure("Claude did not correlate its result to the submitted turn. Select a supported version.")
        }
        guard incoming == claudeTurnID else { return }
        guard ready, !message["is_error"].bool else {
            throw AskError.protocolFailure("Claude Haiku 5.5 could not complete the turn. Check model access and official sign-in, then Retry explicitly.")
        }
        let data: Data
        if message["structured_output"] != .null { data = try JSONEncoder().encode(message["structured_output"]) }
        else { data = Data((message["result"].string ?? "").utf8) }
        let presentation: GuidePresentation
        do { presentation = try parsePresentation(data) }
        catch let wrong as GuideWrongPurpose { self.claudeTurnID = nil; reject(wrong); return }
        self.claudeTurnID = nil; complete(presentation)
    }

    private func receiveCodex(_ message: JSONValue) throws {
        let hadThread = codex.threadID != nil
        for outgoing in try codex.receive(message) {
            if outgoing["method"].string == "thread/start" { try profile.disableSkills(codex.disabledSkillPaths) }
            try process?.send(outgoing)
        }
        if !hadThread, let id = codex.threadID {
            ready = true; sessionIdentifier = id; try sendPendingTurn()
        }
        guard codex.accepts(message), pending != nil else { return }
        let params = message["params"]
        switch message["method"].string {
        case "item/agentMessage/delta":
            response += params["delta"].string ?? ""
            guard response.utf8.count <= 262_144 else { throw AskError.protocolFailure("Guide output exceeds its limit.") }
        case "item/completed":
            if response.isEmpty, params["item"]["type"].string == "agentMessage" { response = params["item"]["text"].string ?? "" }
        case "turn/completed":
            guard params["turn"]["status"].string == "completed" else {
                throw AskError.protocolFailure("GPT-6 Luna could not complete the turn. Check model access and official sign-in, then Retry explicitly.")
            }
            do { complete(try parsePresentation(Data(response.utf8))) }
            catch let wrong as GuideWrongPurpose { reject(wrong) }
        default: break
        }
    }

    private func parsePresentation(_ data: Data) throws -> GuidePresentation {
        guard let purpose = pendingPurpose else { throw AskError.incompleteTurn }
        return try GuidePresentation.parseResponse(data, purpose: purpose)
    }

    private func complete(_ value: GuidePresentation) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil; pendingPurpose = nil; response = ""
        continuation?.resume(returning: value)
    }

    /// Ends only the pending turn with an error; the conversation stays open for a corrective turn.
    private func reject(_ error: Error) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil; pendingPurpose = nil; response = ""
        continuation?.resume(throwing: error)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        timeout?.cancel(); timeout = nil; closed = true
        let hadProcess = process != nil
        process?.stop(); process = nil
        if !hadProcess { profile.removeTaskFiles() }
        let continuation = pending; pending = nil; pendingTurn = nil; pendingPurpose = nil; response = ""
        continuation?.resume(throwing: error)
        if continuation == nil { onUnexpectedExit?(error.localizedDescription) }
    }
}
