import Foundation

/// Versioned result schema shared by the Local AI Lab export and `clicky-local-bench`. Records contain sample
/// identities, metrics and model output text; personal datasets stay outside Git and are never uploaded.
nonisolated public enum LocalBenchmarkSchema {
    public static let version = 1
}

nonisolated public struct LocalBenchmarkEnvironment: Codable, Equatable, Sendable {
    public var commit: String
    public var operatingSystem: String
    public var hardware: String
    public var physicalMemoryBytes: UInt64
    public var worker: [String: String]
    public var metalDevice: String?

    public init(commit: String, operatingSystem: String, hardware: String, physicalMemoryBytes: UInt64,
                worker: [String: String], metalDevice: String?) {
        self.commit = commit; self.operatingSystem = operatingSystem; self.hardware = hardware
        self.physicalMemoryBytes = physicalMemoryBytes; self.worker = worker; self.metalDevice = metalDevice
    }
}

nonisolated public struct LocalBenchmarkModel: Codable, Equatable, Sendable {
    public var identifier: String
    public var revision: String
    public var fingerprint: String
    public var kind: LocalModelKind
    public var quantization: String

    public init(identifier: String, revision: String, fingerprint: String, kind: LocalModelKind, quantization: String) {
        self.identifier = identifier; self.revision = revision; self.fingerprint = fingerprint
        self.kind = kind; self.quantization = quantization
    }
}

nonisolated public struct LocalBenchmarkConfiguration: Codable, Equatable, Sendable {
    public enum Pipeline: String, Codable, Sendable {
        case asrOnly, asrWithCleanup, cleanupOnReference, text, vision
    }
    public var pipeline: Pipeline
    public var recognizer: LocalBenchmarkModel?
    public var cleanup: LocalBenchmarkModel?
    public var generator: LocalBenchmarkModel?
    public var promptIdentifier: String?
    public var parameters: LocalGenerationParameters?
    public var warmUpRuns: Int
    public var repetitions: Int
    /// "foreground-protected" (nice 10) or "default"; CPU priority only, GPU fairness is not implied.
    public var workerPriority: String
    public var dataset: String
    public var datasetRevision: String?

    public init(pipeline: Pipeline, recognizer: LocalBenchmarkModel? = nil, cleanup: LocalBenchmarkModel? = nil,
                generator: LocalBenchmarkModel? = nil, promptIdentifier: String? = nil, parameters: LocalGenerationParameters? = nil,
                warmUpRuns: Int, repetitions: Int, workerPriority: String, dataset: String, datasetRevision: String? = nil) {
        self.pipeline = pipeline; self.recognizer = recognizer; self.cleanup = cleanup; self.generator = generator
        self.promptIdentifier = promptIdentifier; self.parameters = parameters; self.warmUpRuns = warmUpRuns
        self.repetitions = repetitions; self.workerPriority = workerPriority; self.dataset = dataset; self.datasetRevision = datasetRevision
    }
}

/// Manual review labels; nil until a person annotated the sample. Never inferred automatically.
nonisolated public struct LocalBenchmarkAnnotation: Codable, Equatable, Sendable {
    public var meaningPreserved: Bool?
    public var harmfulDeletion: Bool?
    public var wrongRepair: Bool?
    public var addedContent: Bool?
    public var answeredQuestion: Bool?
    public var numberOrNameError: Bool?
    public var note: String?

    public init(meaningPreserved: Bool? = nil, harmfulDeletion: Bool? = nil, wrongRepair: Bool? = nil, addedContent: Bool? = nil,
                answeredQuestion: Bool? = nil, numberOrNameError: Bool? = nil, note: String? = nil) {
        self.meaningPreserved = meaningPreserved; self.harmfulDeletion = harmfulDeletion; self.wrongRepair = wrongRepair
        self.addedContent = addedContent; self.answeredQuestion = answeredQuestion; self.numberOrNameError = numberOrNameError; self.note = note
    }
}

nonisolated public struct LocalBenchmarkSampleResult: Codable, Equatable, Sendable {
    public var sampleIdentifier: String
    public var repetition: Int
    public var audioSeconds: Double?
    public var rawText: String?
    public var cleanedText: String?
    public var outputText: String?
    public var gateVerdict: CleanupVerdict?
    public var gateConcerns: [CleanupConcern]
    public var rawWordErrorRate: Double?
    public var cleanWordErrorRate: Double?
    public var cleanCharacterErrorRate: Double?
    /// Worker-measured stage times and host end-to-end times (host includes IPC, queueing and preprocessing).
    public var recognizerMetrics: LocalRunMetrics?
    public var cleanupMetrics: LocalRunMetrics?
    public var generationMetrics: LocalRunMetrics?
    public var hostRecognizerMilliseconds: Double?
    public var hostCleanupMilliseconds: Double?
    public var stopToFinalMilliseconds: Double?
    public var failure: String?
    public var annotation: LocalBenchmarkAnnotation?
    /// Vision benchmark only: output was JSON with the requested keys.
    public var schemaCompliant: Bool?
    /// Vision benchmark only: the predicted box center lies inside the true box.
    public var targetHit: Bool?
    public var intersectionOverUnion: Double?

    public init(sampleIdentifier: String, repetition: Int) {
        self.sampleIdentifier = sampleIdentifier; self.repetition = repetition; gateConcerns = []
    }
}

/// Peak memory observed while every model of the configuration was resident together.
nonisolated public struct LocalBenchmarkMemory: Codable, Equatable, Sendable {
    public var speechWorker: LocalMemoryReport?
    public var inferenceWorker: LocalMemoryReport?
    public var combinedPeakFootprintBytes: UInt64?

    public init(speechWorker: LocalMemoryReport? = nil, inferenceWorker: LocalMemoryReport? = nil, combinedPeakFootprintBytes: UInt64? = nil) {
        self.speechWorker = speechWorker; self.inferenceWorker = inferenceWorker; self.combinedPeakFootprintBytes = combinedPeakFootprintBytes
    }
}

nonisolated public struct LocalBenchmarkSummary: Codable, Equatable, Sendable {
    public var samples: Int
    public var failures: Int
    public var corpusRawWordErrorRate: Double?
    public var corpusCleanWordErrorRate: Double?
    public var corpusCleanCharacterErrorRate: Double?
    public var stopToFinalP50: Double?
    public var stopToFinalP95: Double?
    public var recognizerP50: Double?
    public var cleanupP50: Double?
    public var verdictCounts: [String: Int]
    /// Vision benchmark only, over successful samples.
    public var schemaComplianceRate: Double?
    public var targetAccuracy: Double?
    public var meanIntersectionOverUnion: Double?

    public init(samples: Int, failures: Int) { self.samples = samples; self.failures = failures; verdictCounts = [:] }
}

nonisolated public struct LocalBenchmarkRun: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var identifier: UUID
    public var startedAt: Date
    public var environment: LocalBenchmarkEnvironment
    public var configuration: LocalBenchmarkConfiguration
    public var loadMilliseconds: [String: Double]
    public var coldFirstMilliseconds: [String: Double]
    public var memory: LocalBenchmarkMemory
    public var results: [LocalBenchmarkSampleResult]
    public var summary: LocalBenchmarkSummary?
    /// Free-form observations (thermal state, foreground app responsiveness notes) recorded by the operator.
    public var observations: [String]

    public init(identifier: UUID = UUID(), startedAt: Date = Date(), environment: LocalBenchmarkEnvironment,
                configuration: LocalBenchmarkConfiguration) {
        schemaVersion = LocalBenchmarkSchema.version; self.identifier = identifier; self.startedAt = startedAt
        self.environment = environment; self.configuration = configuration
        loadMilliseconds = [:]; coldFirstMilliseconds = [:]; memory = LocalBenchmarkMemory(); results = []; observations = []
    }

    /// Recomputes the summary from the results. Percentiles need at least five successful samples.
    public mutating func summarize(references: [String: (raw: String?, clean: String?)]) {
        var summary = LocalBenchmarkSummary(samples: results.count, failures: results.filter { $0.failure != nil }.count)
        let succeeded = results.filter { $0.failure == nil }
        func pairs(_ text: (LocalBenchmarkSampleResult) -> String?, _ reference: ((raw: String?, clean: String?)) -> String?) -> ([String], [String]) {
            var refs: [String] = [], hyps: [String] = []
            for result in succeeded {
                guard let hypothesis = text(result), let refPair = references[result.sampleIdentifier], let ref = reference(refPair) else { continue }
                refs.append(ref); hyps.append(hypothesis)
            }
            return (refs, hyps)
        }
        let raw = pairs({ $0.rawText }, { $0.raw })
        let clean = pairs({ $0.cleanedText ?? $0.rawText }, { $0.clean })
        summary.corpusRawWordErrorRate = raw.0.isEmpty ? nil : SpeechMetrics.corpusWordErrorRate(Array(zip(raw.0, raw.1)).map { (reference: $0.0, hypothesis: $0.1) })
        summary.corpusCleanWordErrorRate = clean.0.isEmpty ? nil : SpeechMetrics.corpusWordErrorRate(Array(zip(clean.0, clean.1)).map { (reference: $0.0, hypothesis: $0.1) })
        summary.corpusCleanCharacterErrorRate = clean.0.isEmpty ? nil : SpeechMetrics.corpusCharacterErrorRate(Array(zip(clean.0, clean.1)).map { (reference: $0.0, hypothesis: $0.1) })
        let stopToFinal = succeeded.compactMap(\.stopToFinalMilliseconds)
        if stopToFinal.count >= 5 {
            summary.stopToFinalP50 = SpeechMetrics.percentile(stopToFinal, 50)
            summary.stopToFinalP95 = SpeechMetrics.percentile(stopToFinal, 95)
        }
        let recognizer = succeeded.compactMap(\.hostRecognizerMilliseconds)
        if recognizer.count >= 5 { summary.recognizerP50 = SpeechMetrics.percentile(recognizer, 50) }
        let cleanup = succeeded.compactMap(\.hostCleanupMilliseconds)
        if cleanup.count >= 5 { summary.cleanupP50 = SpeechMetrics.percentile(cleanup, 50) }
        for result in succeeded { if let verdict = result.gateVerdict { summary.verdictCounts[verdict.rawValue, default: 0] += 1 } }
        self.summary = summary
    }
}

/// One personal or public benchmark sample. Personal samples are recorded deliberately in the Lab, approved
/// by the user, stored locally under Application Support and never committed or uploaded.
nonisolated public struct LocalBenchmarkSample: Codable, Equatable, Identifiable, Sendable {
    public enum Split: String, Codable, Sendable, CaseIterable { case development, heldOut }
    public var id: String
    public var audioFile: String
    public var rawReference: String?
    public var cleanReference: String?
    public var split: Split
    public var tags: [String]
    public var approvedAt: Date?

    public init(id: String, audioFile: String, rawReference: String?, cleanReference: String?, split: Split,
                tags: [String] = [], approvedAt: Date? = nil) {
        self.id = id; self.audioFile = audioFile; self.rawReference = rawReference; self.cleanReference = cleanReference
        self.split = split; self.tags = tags; self.approvedAt = approvedAt
    }

    /// Only approved samples with both references count for quality metrics.
    public var isApproved: Bool { approvedAt != nil && rawReference != nil && cleanReference != nil }
}
