import Foundation

/// One stateless generation on the on-device worker: the full message list, at most one PNG, bounded output.
nonisolated public struct LocalInferenceRequest: Sendable {
    public let messages: [LocalChatMessage]
    public let image: Data?
    public let parameters: LocalGenerationParameters
    public init(messages: [LocalChatMessage], image: Data?, parameters: LocalGenerationParameters) {
        self.messages = messages; self.image = image; self.parameters = parameters
    }
}

/// Runs one generation and returns the final text. The app wires this to `LocalAIRuntime`; tests script it.
public typealias LocalInferenceClient = @Sendable (LocalInferenceRequest) async throws -> String

/// A guide or writing conversation on the on-device MLX model. The worker keeps no state between requests, so
/// this actor owns the transcript and resends it (bounded) every turn, attaching only the latest capture. Replies
/// go through `LocalReply` and the shared parser; an unusable reply gets exactly one repair turn, after which the
/// turn fails like any provider protocol error. Nothing leaves the Mac and nothing is persisted.
public actor LocalMLXAgent: GuideAgentRunning {
    /// Messages travel in the worker's 64 KiB JSON frame header, so the budget leaves room for escaping.
    public static let maximumPromptBytes = 44_000
    public static let maximumImageSide = 1568

    private let contract: AgentContract
    private let client: LocalInferenceClient
    private let timeoutNanoseconds: UInt64
    private let sessionIdentifier = "local-" + UUID().uuidString.lowercased()
    private var history: [LocalChatMessage] = []
    private var latestImage: (attachment: PNGImageAttachment, captureID: UUID?)?
    private var inflight: Task<String, Error>?
    private var busy = false
    private var closed = false

    public init(contract: AgentContract, client: @escaping LocalInferenceClient, timeoutNanoseconds: UInt64 = 300_000_000_000) {
        self.contract = contract; self.client = client; self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func identifier() -> String? { sessionIdentifier }

    public func close() {
        closed = true; inflight?.cancel(); inflight = nil
        history = []; latestImage = nil
    }

    public func turn(_ request: GuideAgentTurn) async throws -> GuidePresentation {
        guard !closed else { throw AskError.incompleteTurn }
        guard !busy else { throw AskError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        if let image = request.image { latestImage = (image, request.context?.captureID) }
        let attached = attachedImage(for: request)
        let frame = attached.map { LocalReply.ImageFrame(captureID: $0.captureID, pixelWidth: $0.attachment.pixelWidth,
                                                         pixelHeight: $0.attachment.pixelHeight) }
        let user = LocalChatMessage(role: .user, text: Self.render(request, imageAttached: attached != nil))
        let output = try await generate(history + [user], image: attached?.attachment, purpose: request.purpose)
        do {
            let value = try LocalReply.presentation(from: output, purpose: request.purpose, frame: frame)
            remember(user, output)
            return value
        } catch let wrong as GuideWrongPurpose {
            // Kept so the shared one-time purpose correction reads as a follow-up to this reply.
            remember(user, output)
            throw wrong
        } catch AskError.protocolFailure(let problem) {
            let repair = LocalChatMessage(role: .user, text: LocalPrompt.repair(problem, allowedKinds: GuideContract.allowedKinds(for: request.purpose)))
            let retry = try await generate(history + [user, LocalChatMessage(role: .assistant, text: output), repair],
                                           image: attached?.attachment, purpose: request.purpose)
            let value = try LocalReply.presentation(from: retry, purpose: request.purpose, frame: frame)
            remember(user, retry)
            return value
        }
    }

    /// The latest capture, unless this turn names a different capture the agent never received.
    private func attachedImage(for request: GuideAgentTurn) -> (attachment: PNGImageAttachment, captureID: UUID?)? {
        guard let latestImage else { return nil }
        if let context = request.context, context.captureID != latestImage.captureID { return nil }
        return latestImage
    }

    private func remember(_ user: LocalChatMessage, _ output: String) {
        let reply = LocalReply.firstObject(in: output) ?? output
        history += [user, LocalChatMessage(role: .assistant, text: reply)]
    }

    private func generate(_ conversation: [LocalChatMessage], image: PNGImageAttachment?, purpose: GuideRequestPurpose) async throws -> String {
        let messages = try Self.bounded(system: LocalPrompt.system(for: contract), conversation: conversation)
        let side = image.map { min(max($0.pixelWidth, $0.pixelHeight), Self.maximumImageSide) } ?? 1024
        let request = LocalInferenceRequest(messages: messages, image: image?.data,
                                            parameters: LocalGenerationParameters(maximumTokens: Self.outputTokens(for: purpose),
                                                                                  maximumImageSide: side))
        let client = client, timeout = timeoutNanoseconds
        let task = Task<String, Error> {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await client(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw AskError.protocolFailure("The on-device model timed out. Retry explicitly with fresh context.")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw AskError.incompleteTurn }
                return first
            }
        }
        inflight = task
        defer { if inflight == task { inflight = nil } }
        let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closed else { throw CancellationError() }
        return output
    }

    static func outputTokens(for purpose: GuideRequestPurpose) -> Int {
        switch purpose {
        case .writing: return LocalWorkerProtocol.maximumOutputTokens
        case .verification: return 512
        default: return 1536
        }
    }

    /// System prompt, then as much recent history as fits; the current request itself must fit.
    static func bounded(system: String, conversation: [LocalChatMessage]) throws -> [LocalChatMessage] {
        var kept = conversation
        func size(_ messages: [LocalChatMessage]) -> Int { system.utf8.count + messages.reduce(0) { $0 + $1.text.utf8.count } }
        // Drop whole user/assistant exchanges from the front, never the trailing request.
        while size(kept) > maximumPromptBytes, kept.count > 1 {
            kept.removeFirst(min(2, kept.count - 1))
        }
        guard size(kept) <= maximumPromptBytes else { throw AskError.promptTooLarge }
        return [LocalChatMessage(role: .system, text: system)] + kept
    }

    /// A compact host request: no protocol bookkeeping, pixel geometry or capture metadata the model cannot use.
    static func render(_ turn: GuideAgentTurn, imageAttached: Bool) -> String {
        var fields: [String: JSONValue] = [
            "purpose": .string(turn.purpose.rawValue),
            "allowedKinds": .array(GuideContract.allowedKinds(for: turn.purpose).map { .string($0.rawValue) }),
            "request": .string(turn.message),
            "image": .string(imageAttached ? "attached: the current screen" : "none"),
        ]
        if let task = turn.taskContext, let value = encoded(task) { fields["task"] = compact(value) }
        if let writing = turn.writing, let value = encoded(writing) { fields["writing"] = compact(value) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(JSONValue.object(fields)), as: UTF8.self)) ?? turn.message
    }

    private static let droppedKeys: Set<String> = ["id", "taskID", "stepRevision", "contextRevision", "planRevision",
                                                   "captureID", "target", "ghost", "crop", "evidenceTarget"]

    private static func encoded<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Drops nulls, identifiers and pixel geometry recursively; boxes in old captures would mislead the model.
    static func compact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            return .object(fields.filter { !droppedKeys.contains($0.key) && $0.value != .null }.mapValues(compact))
        case .array(let items): return .array(items.map(compact))
        default: return value
        }
    }
}
