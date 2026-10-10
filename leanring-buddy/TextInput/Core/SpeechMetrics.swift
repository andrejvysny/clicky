import Foundation

/// WER/CER on normalized text, matching voice-benchmark `metrics.py`: aggregates are corpus-level
/// (total errors / total reference units), never a mean of per-utterance rates.
nonisolated public struct ErrorCounts: Equatable, Sendable {
    public var errors: Int
    public var referenceUnits: Int
    public init(errors: Int, referenceUnits: Int) {
        self.errors = errors
        self.referenceUnits = referenceUnits
    }
    public var rate: Double? { referenceUnits == 0 ? nil : Double(errors) / Double(referenceUnits) }
}

nonisolated public enum SpeechMetrics {
    /// Levenshtein distance (substitutions + deletions + insertions, each cost 1) = jiwer S+D+I.
    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    public static func wordCounts(reference: String, hypothesis: String) -> ErrorCounts {
        counts(TranscriptText.words(reference), TranscriptText.words(hypothesis))
    }

    /// Characters are Unicode scalars of the normalized string (spaces included), as in Python.
    public static func characterCounts(reference: String, hypothesis: String) -> ErrorCounts {
        counts(Array(TranscriptText.normalize(reference).unicodeScalars), Array(TranscriptText.normalize(hypothesis).unicodeScalars))
    }

    private static func counts<T: Equatable>(_ ref: [T], _ hyp: [T]) -> ErrorCounts {
        if ref.isEmpty { return ErrorCounts(errors: hyp.count, referenceUnits: 0) }
        return ErrorCounts(errors: editDistance(ref, hyp), referenceUnits: ref.count)
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        wordCounts(reference: reference, hypothesis: hypothesis).rate
    }

    public static func characterErrorRate(reference: String, hypothesis: String) -> Double? {
        characterCounts(reference: reference, hypothesis: hypothesis).rate
    }

    public static func corpusRate(_ counts: [ErrorCounts]) -> Double? {
        let units = counts.reduce(0) { $0 + $1.referenceUnits }
        guard units > 0 else { return nil }
        return Double(counts.reduce(0) { $0 + $1.errors }) / Double(units)
    }

    /// Pairs are (reference, hypothesis).
    public static func corpusWordErrorRate(_ pairs: [(reference: String, hypothesis: String)]) -> Double? {
        corpusRate(pairs.map { wordCounts(reference: $0.reference, hypothesis: $0.hypothesis) })
    }

    public static func corpusCharacterErrorRate(_ pairs: [(reference: String, hypothesis: String)]) -> Double? {
        corpusRate(pairs.map { characterCounts(reference: $0.reference, hypothesis: $0.hypothesis) })
    }

    /// Linear interpolation between closest ranks (numpy default). `p` is 0...100; nil for empty input or invalid `p`.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty, p >= 0, p <= 100, values.allSatisfy({ !$0.isNaN }) else { return nil }
        let sorted = values.sorted()
        let rank = p / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    /// Population standard deviation; nil for empty input.
    public static func meanAndStandardDeviation(_ values: [Double]) -> (mean: Double, standardDeviation: Double)? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// Processing time over audio duration; below 1 is faster than real time. nil without audio.
    public static func realTimeFactor(processingSeconds: Double, audioSeconds: Double) -> Double? {
        audioSeconds > 0 ? processingSeconds / audioSeconds : nil
    }
}
