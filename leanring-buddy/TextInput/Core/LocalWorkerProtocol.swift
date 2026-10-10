import Foundation

/// Private wire contract between Clicky and its bundled local inference worker. The worker is launched directly
/// by the host with inherited pipes (no listener, no shell); every frame is bounded and versioned, and every
/// message after the handshake carries the per-launch session nonce so output from a previous worker can never
/// be attributed to the current one.
nonisolated public enum LocalWorkerProtocol {
    public static let version = 1
    public static let magic: [UInt8] = Array("CLKW".utf8)
    public static let maximumHeaderBytes = 64 * 1024
    /// Largest binary payload: one PNG (≤ 3 MiB) or ≤ 300 s of 16 kHz Int16 PCM (9.6 MB), with headroom.
    public static let maximumPayloadBytes = 16 * 1024 * 1024
    public static let maximumPromptCharacters = 64 * 1024
    public static let maximumOutputTokens = 4096
    public static let maximumAudioSeconds = 300.0
    public static let audioSampleRate = 16_000
}

nonisolated public enum LocalWorkerRole: String, Codable, Sendable {
    /// MLX text, vision and transcript-cleanup models.
    case inference
    /// Speech recognition (Core ML / MLX ASR) models.
    case speech
}

nonisolated public enum LocalModelKind: String, Codable, Sendable, CaseIterable {
    /// MLX vision-language model (text and single images).
    case mlxVLM
    /// MLX text-only language model (cleanup and text tests).
    case mlxLLM
    /// FluidAudio Parakeet TDT Core ML bundle.
    case parakeetCoreML
    /// WhisperKit Core ML bundle.
    case whisperKit

    public var role: LocalWorkerRole {
        switch self {
        case .mlxVLM, .mlxLLM: return .inference
        case .parakeetCoreML, .whisperKit: return .speech
        }
    }
}

/// The installed, host-verified model a load request names. The worker loads only this directory.
nonisolated public struct LocalModelReference: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    public let revision: String
    public let kind: LocalModelKind
    public let directory: String
    /// Host-computed digest over the verified file manifest; echoed in results so a measurement names its weights.
    public let fingerprint: String

    public init(identifier: String, revision: String, kind: LocalModelKind, directory: String, fingerprint: String) {
        self.identifier = identifier; self.revision = revision; self.kind = kind
        self.directory = directory; self.fingerprint = fingerprint
    }
}

nonisolated public struct LocalChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

nonisolated public struct LocalGenerationParameters: Codable, Equatable, Sendable {
    public var maximumTokens: Int
    public var temperature: Double
    public var topP: Double
    public var seed: UInt64?
    /// Longest image side handed to the processor, in pixels; the host already bounded the PNG itself.
    public var maximumImageSide: Int

    public init(maximumTokens: Int = 512, temperature: Double = 0, topP: Double = 1, seed: UInt64? = nil, maximumImageSide: Int = 1024) {
        self.maximumTokens = maximumTokens; self.temperature = temperature; self.topP = topP
        self.seed = seed; self.maximumImageSide = maximumImageSide
    }
}

nonisolated public enum LocalWorkerErrorCode: String, Codable, Sendable {
    case protocolMismatch, invalidMessage, duplicateRequest, staleSession, unknownModel, modelNotLoaded
    case busy, inputTooLarge, unsupported, loadFailed, inferenceFailed, outOfMemory, workerUnavailable, timedOut, internalError
}

nonisolated public struct LocalWorkerError: Codable, Equatable, Error, Sendable {
    public let code: LocalWorkerErrorCode
    /// Short, content-free description; never contains prompts, transcripts or file contents.
    public let message: String
    public init(_ code: LocalWorkerErrorCode, _ message: String) { self.code = code; self.message = message }
}

/// Measured numbers for one request. Times are monotonic milliseconds measured inside the worker after all
/// lazy MLX computation was evaluated; the host adds its own end-to-end time including IPC.
nonisolated public struct LocalRunMetrics: Codable, Equatable, Sendable {
    public var loadMilliseconds: Double?
    public var preprocessMilliseconds: Double?
    public var firstTokenMilliseconds: Double?
    public var totalMilliseconds: Double
    public var promptTokens: Int?
    public var generatedTokens: Int?
    public var audioSeconds: Double?
    public var memory: LocalMemoryReport?

    public init(loadMilliseconds: Double? = nil, preprocessMilliseconds: Double? = nil, firstTokenMilliseconds: Double? = nil,
                totalMilliseconds: Double, promptTokens: Int? = nil, generatedTokens: Int? = nil, audioSeconds: Double? = nil,
                memory: LocalMemoryReport? = nil) {
        self.loadMilliseconds = loadMilliseconds; self.preprocessMilliseconds = preprocessMilliseconds
        self.firstTokenMilliseconds = firstTokenMilliseconds; self.totalMilliseconds = totalMilliseconds
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.audioSeconds = audioSeconds
        self.memory = memory
    }
}

/// Process-level memory as the worker sees it. `physicalFootprint` is the kernel's phys_footprint (what Activity
/// Monitor calls Memory); the MLX fields come from MLX's own allocator and exclude Core ML allocations.
nonisolated public struct LocalMemoryReport: Codable, Equatable, Sendable {
    public var physicalFootprintBytes: UInt64
    public var peakPhysicalFootprintBytes: UInt64?
    public var mlxActiveBytes: UInt64?
    public var mlxPeakBytes: UInt64?
    public var mlxCacheBytes: UInt64?

    public init(physicalFootprintBytes: UInt64, peakPhysicalFootprintBytes: UInt64? = nil, mlxActiveBytes: UInt64? = nil,
                mlxPeakBytes: UInt64? = nil, mlxCacheBytes: UInt64? = nil) {
        self.physicalFootprintBytes = physicalFootprintBytes; self.peakPhysicalFootprintBytes = peakPhysicalFootprintBytes
        self.mlxActiveBytes = mlxActiveBytes; self.mlxPeakBytes = mlxPeakBytes; self.mlxCacheBytes = mlxCacheBytes
    }
}

nonisolated public struct LocalWorkerReadiness: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let role: LocalWorkerRole
    public let processIdentifier: Int32
    /// Pinned runtime versions compiled into the worker, e.g. ["mlx-swift": "0.32.3"].
    public let runtime: [String: String]
    public let metalDevice: String?
    /// True when the worker entered its no-network sandbox profile before reading any request.
    public let networkDenied: Bool
    public let supportedKinds: [LocalModelKind]

    public init(protocolVersion: Int, role: LocalWorkerRole, processIdentifier: Int32, runtime: [String: String],
                metalDevice: String?, networkDenied: Bool, supportedKinds: [LocalModelKind]) {
        self.protocolVersion = protocolVersion; self.role = role; self.processIdentifier = processIdentifier
        self.runtime = runtime; self.metalDevice = metalDevice; self.networkDenied = networkDenied; self.supportedKinds = supportedKinds
    }
}

/// Host → worker. Payload rules: `generate` carries at most one PNG when `hasImage`; `transcribe` carries exactly
/// `sampleCount` little-endian Int16 mono samples at 16 kHz. Every other message has an empty payload.
nonisolated public enum LocalWorkerCommand: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int, role: LocalWorkerRole, session: String)
    case load(request: UUID, model: LocalModelReference, warmUp: Bool)
    case unload(request: UUID, modelIdentifier: String)
    case generate(request: UUID, modelIdentifier: String, messages: [LocalChatMessage], parameters: LocalGenerationParameters, hasImage: Bool)
    case transcribe(request: UUID, modelIdentifier: String, sampleCount: Int, language: String)
    /// Drops prompt/KV caches without unloading weights.
    case clearCaches(request: UUID)
    case memory(request: UUID)
    case cancel(request: UUID)
    case shutdown
}

/// Worker → host. Exactly one of `completed`, `failed`, `canceled` ends each accepted request.
nonisolated public enum LocalWorkerEvent: Codable, Equatable, Sendable {
    case ready(session: String, readiness: LocalWorkerReadiness)
    case accepted(session: String, request: UUID)
    case progress(session: String, request: UUID, stage: String, fraction: Double?)
    case delta(session: String, request: UUID, text: String)
    case completed(session: String, request: UUID, text: String, metrics: LocalRunMetrics)
    case failed(session: String, request: UUID?, error: LocalWorkerError)
    case canceled(session: String, request: UUID)
    case memory(session: String, request: UUID, report: LocalMemoryReport)

    public var session: String {
        switch self {
        case .ready(let session, _), .accepted(let session, _), .progress(let session, _, _, _), .delta(let session, _, _),
             .completed(let session, _, _, _), .failed(let session, _, _), .canceled(let session, _), .memory(let session, _, _):
            return session
        }
    }

    public var request: UUID? {
        switch self {
        case .ready: return nil
        case .accepted(_, let request), .progress(_, let request, _, _), .delta(_, let request, _),
             .completed(_, let request, _, _), .canceled(_, let request), .memory(_, let request, _):
            return request
        case .failed(_, let request, _): return request
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .canceled, .memory: return true
        case .failed(_, let request, _): return request != nil
        default: return false
        }
    }
}

/// One frame on the wire: "CLKW" | UInt32 BE header length | UInt32 BE payload length | JSON header | payload.
nonisolated public struct LocalWorkerFrame<Message: Codable & Equatable & Sendable>: Equatable, Sendable {
    public let message: Message
    public let payload: Data

    public init(_ message: Message, payload: Data = Data()) { self.message = message; self.payload = payload }

    public func encoded() throws -> Data {
        let header = try JSONEncoder().encode(message)
        guard header.count <= LocalWorkerProtocol.maximumHeaderBytes, payload.count <= LocalWorkerProtocol.maximumPayloadBytes else {
            throw LocalWorkerError(.inputTooLarge, "Frame exceeds the protocol limit.")
        }
        var data = Data(LocalWorkerProtocol.magic)
        data.append(contentsOf: Self.bigEndianBytes(UInt32(header.count)))
        data.append(contentsOf: Self.bigEndianBytes(UInt32(payload.count)))
        data.append(header)
        data.append(payload)
        return data
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }
}

/// Incremental decoder for one direction of the pipe. Any malformed or oversized frame is fatal for the
/// connection: the caller must stop the worker rather than try to resynchronize.
nonisolated public struct LocalWorkerFramer<Message: Codable & Equatable & Sendable> {
    private var buffer = Data()
    private static var prefixLength: Int { 12 }

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [LocalWorkerFrame<Message>] {
        buffer.append(chunk)
        var frames: [LocalWorkerFrame<Message>] = []
        while buffer.count >= Self.prefixLength {
            let bytes = [UInt8](buffer.prefix(Self.prefixLength))
            guard Array(bytes[0..<4]) == LocalWorkerProtocol.magic else { throw LocalWorkerError(.invalidMessage, "Bad frame marker.") }
            let headerLength = Int(Self.readUInt32(bytes, at: 4))
            let payloadLength = Int(Self.readUInt32(bytes, at: 8))
            guard headerLength > 0, headerLength <= LocalWorkerProtocol.maximumHeaderBytes,
                  payloadLength <= LocalWorkerProtocol.maximumPayloadBytes else {
                throw LocalWorkerError(.inputTooLarge, "Frame exceeds the protocol limit.")
            }
            let total = Self.prefixLength + headerLength + payloadLength
            guard buffer.count >= total else { break }
            let start = buffer.startIndex
            let header = buffer.subdata(in: (start + Self.prefixLength)..<(start + Self.prefixLength + headerLength))
            let payload = buffer.subdata(in: (start + Self.prefixLength + headerLength)..<(start + total))
            let message: Message
            do { message = try JSONDecoder().decode(Message.self, from: header) }
            catch { throw LocalWorkerError(.invalidMessage, "Undecodable frame header.") }
            frames.append(LocalWorkerFrame(message, payload: payload))
            buffer.removeSubrange(start..<(start + total))
        }
        return frames
    }

    /// True when bytes of an incomplete frame remain; at end of stream that is a truncated frame.
    public var hasPartialFrame: Bool { !buffer.isEmpty }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

/// Host-side bookkeeping that turns the worker's event stream into exactly-once outcomes. It rejects events from
/// another session, events for requests the host never issued, and anything after a request's terminal event.
nonisolated public struct LocalWorkerLedger: Sendable {
    public enum Disposition: Equatable, Sendable {
        /// Deliver to the request's consumer; `terminal` ends it.
        case deliver(terminal: Bool)
        /// Drop silently: late output for a request that already ended or was abandoned by the host.
        case stale
        /// The worker violated the protocol (wrong session, unknown request); the connection must be stopped.
        case violation(String)
    }

    public let session: String
    private var pending: Set<UUID> = []
    private var finished: Set<UUID> = []

    public init(session: String) { self.session = session }

    public var pendingRequests: Set<UUID> { pending }

    /// Registers a new request before it is sent. False for a reused identifier.
    public mutating func register(_ request: UUID) -> Bool {
        guard !pending.contains(request), !finished.contains(request) else { return false }
        pending.insert(request)
        return true
    }

    /// The host abandoned a request (its consumer went away or it was canceled past the grace period);
    /// later worker events for it are stale rather than violations.
    public mutating func abandon(_ request: UUID) {
        if pending.remove(request) != nil { finished.insert(request) }
    }

    public mutating func classify(_ event: LocalWorkerEvent) -> Disposition {
        guard event.session == session else { return .violation("Event from another worker session.") }
        guard let request = event.request else {
            if case .ready = event { return .violation("Unexpected second handshake.") }
            // A connection-level failure (no request) is delivered and ends the session.
            return .deliver(terminal: true)
        }
        if finished.contains(request) { return .stale }
        guard pending.contains(request) else { return .violation("Event for a request the host never sent.") }
        if event.isTerminal {
            pending.remove(request)
            finished.insert(request)
            return .deliver(terminal: true)
        }
        return .deliver(terminal: false)
    }

    /// Ends every pending request, e.g. when the worker exited; returns them so the host can fail each once.
    public mutating func failAll() -> [UUID] {
        let all = Array(pending)
        finished.formUnion(pending)
        pending.removeAll()
        return all
    }
}
