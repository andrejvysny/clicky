import Foundation

nonisolated public enum CleanupVerdict: String, Codable, Sendable { case accept, review, reject, noSpeech }

nonisolated public enum CleanupConcern: String, Codable, Sendable, CaseIterable {
    case emptyCleanup, addedContent, unexplainedDeletion, negationChanged, numberChanged, nameRemoved
    case tooShort, lowRecall, numberInCorrection, nameInCorrection
    /// Input beyond `CleanupGate.maxTokens`: alignment is skipped and a human decides.
    case inputTooLong
}

nonisolated public struct CleanupAssessment: Equatable, Sendable {
    public var verdict: CleanupVerdict
    public var concerns: [CleanupConcern]
    public var addedWords: [String]
    /// Unexplained deletions only.
    public var removedWords: [String]
    public var explainedRemovals: Int
}

/// Decides whether an LLM-cleaned dictation may be inserted automatically. Purely lexical and
/// conservative: only fillers, stutters, restarts and unambiguous self-corrections may disappear, and
/// numbers, negations and names must survive. Model-reported confidence is never an input.
nonisolated public enum CleanupGate {
    public static let maxTokens = 2000
    static let restartWindow = 12

    private enum Explanation { case none, filler, stutter, restart, correction }

    public static func assess(raw: String, cleaned: String) -> CleanupAssessment {
        var rawInfo = TranscriptText.tokens(raw, expandContractions: true)
        var rawTokens = rawInfo.map { $0.word }
        let cleanTokens = TranscriptText.tokens(cleaned, expandContractions: true).map { $0.word }
        let nonFiller = rawTokens.filter { !TranscriptText.isHardFiller($0) }
        if nonFiller.isEmpty { return CleanupAssessment(verdict: .noSpeech, concerns: [], addedWords: [], removedWords: [], explainedRemovals: 0) }
        if cleanTokens.isEmpty { return result(.reject, [.emptyCleanup]) }
        if rawTokens.count > maxTokens || cleanTokens.count > maxTokens { return result(.review, [.inputTooLong]) }

        var (rawAligned, cleanAligned) = align(rawTokens, cleanTokens)
        if resolveHasForIs(&rawInfo, rawAligned, cleanTokens, cleanAligned) {
            rawTokens = rawInfo.map { $0.word }
            (rawAligned, cleanAligned) = align(rawTokens, cleanTokens)
        }
        let explanations = explain(rawInfo, aligned: rawAligned)
        let added = zip(cleanTokens, cleanAligned).filter { !$1 && !TranscriptText.isHardFiller($0) }.map { $0.0 }
        let removed = rawTokens.indices.filter { !rawAligned[$0] && explanations[$0] == .none }
        let explainedCount = rawTokens.indices.filter { !rawAligned[$0] && explanations[$0] != .none }.count

        var findings = Findings()
        checkAdded(added, cleanCount: cleanTokens.count, &findings)
        checkDeletions(removed.count, nonFillerCount: nonFiller.count, &findings)
        let keptRaw = Set(rawTokens.indices.filter { rawAligned[$0] }.map { rawTokens[$0] })
        checkCorrections(rawTokens, rawAligned, explanations, kept: keptRaw, raw: raw, &findings)
        checkNegationAndNumbers(rawTokens, cleanTokens, rawAligned, explanations, &findings)
        checkNames(raw: raw, rawTokens: rawTokens, cleanTokens: cleanTokens, rawAligned, explanations, &findings)
        let alignedNonFiller = rawTokens.indices.filter { rawAligned[$0] && !TranscriptText.isHardFiller(rawTokens[$0]) }.count
        let cleanNonFiller = cleanTokens.filter { !TranscriptText.isHardFiller($0) }.count
        if Double(alignedNonFiller) < 0.5 * Double(nonFiller.count) { findings.add(.lowRecall, .reject) }
        if Double(cleanNonFiller) < 0.4 * Double(nonFiller.count) { findings.add(.tooShort, .reject) }

        let verdict: CleanupVerdict = findings.concerns.isEmpty ? .accept : (findings.rejects ? .reject : .review)
        return CleanupAssessment(verdict: verdict, concerns: findings.concerns, addedWords: added,
                                 removedWords: removed.map { rawTokens[$0] }, explainedRemovals: explainedCount)
    }

    private static func result(_ verdict: CleanupVerdict, _ concerns: [CleanupConcern]) -> CleanupAssessment {
        CleanupAssessment(verdict: verdict, concerns: concerns, addedWords: [], removedWords: [], explainedRemovals: 0)
    }

    private struct Findings {
        var concerns: [CleanupConcern] = []
        var rejects = false
        mutating func add(_ concern: CleanupConcern, _ severity: CleanupVerdict) {
            if !concerns.contains(concern) { concerns.append(concern) }
            if severity == .reject { rejects = true }
        }
    }

    // MARK: alignment

    /// LCS by prefix DP, traced back from the end so that among equal-length alignments the LATER raw
    /// occurrence is kept: an abandoned start before a restart is then a deleted prefix.
    static func align(_ raw: [String], _ clean: [String]) -> (raw: [Bool], clean: [Bool]) {
        let n = raw.count, m = clean.count, width = m + 1
        var table = [UInt16](repeating: 0, count: (n + 1) * width)
        for i in 1...n {
            for j in 1...m {
                table[i * width + j] = raw[i - 1] == clean[j - 1]
                    ? table[(i - 1) * width + j - 1] + 1
                    : max(table[(i - 1) * width + j], table[i * width + j - 1])
            }
        }
        var rawAligned = [Bool](repeating: false, count: n), cleanAligned = [Bool](repeating: false, count: m)
        var i = n, j = m
        while i > 0 && j > 0 {
            if raw[i - 1] == clean[j - 1], table[i * width + j] == table[(i - 1) * width + j - 1] + 1 {
                rawAligned[i - 1] = true
                cleanAligned[j - 1] = true
                i -= 1
                j -= 1
            } else if table[(i - 1) * width + j] == table[i * width + j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (rawAligned, cleanAligned)
    }

    /// "it's been" expands to "it is been"; when the cleanup wrote "it has been" the unmatched "is" faces an
    /// unmatched "has" after the same kept word, so that "is" is re-read as "has". Returns whether any changed.
    private static func resolveHasForIs(_ info: inout [TranscriptToken], _ rawAligned: [Bool],
                                        _ clean: [String], _ cleanAligned: [Bool]) -> Bool {
        var changed = false
        for k in info.indices where info[k].ambiguousIs && info[k].word == "is" && !rawAligned[k] && k > 0 && rawAligned[k - 1] {
            // "has" is only a valid reading of "'s" before a past participle ("it's been" → "it has been");
            // "it's fine" → "it has fine" must stay a change.
            let hasMatch = clean.indices.contains {
                $0 > 0 && $0 + 1 < clean.count && clean[$0] == "has" && !cleanAligned[$0] && cleanAligned[$0 - 1]
                    && clean[$0 - 1] == info[k - 1].word && isLikelyParticiple(clean[$0 + 1])
            }
            if hasMatch { info[k].word = "has"; changed = true }
        }
        return changed
    }

    private static let irregularParticiples: Set<String> = [
        "been", "got", "gotten", "had", "done", "gone", "made", "taken", "seen", "become", "come", "said", "told",
        "given", "known", "left", "found", "put", "set", "run", "sent", "brought", "bought", "thought", "kept", "begun",
    ]

    private static func isLikelyParticiple(_ word: String) -> Bool {
        irregularParticiples.contains(word) || (word.count > 3 && (word.hasSuffix("ed") || word.hasSuffix("en")))
    }

    // MARK: explaining deletions

    private static func explain(_ info: [TranscriptToken], aligned: [Bool]) -> [Explanation] {
        let tokens = info.map { $0.word }
        let soft = TranscriptText.softMask(tokens), editing = TranscriptText.editingMask(tokens)
        let softOK = deletableSoftMask(info, soft: soft, aligned: aligned)
        var result = [Explanation](repeating: .none, count: tokens.count)
        var i = 0
        while i < tokens.count {
            if aligned[i] { i += 1; continue }
            var end = i
            while end + 1 < tokens.count && !aligned[end + 1] { end += 1 }
            if isCorrection(tokens, i...end, soft: soft, editing: editing) {
                for k in i...end { result[k] = .correction }
            } else {
                for k in i...end { result[k] = explanation(for: k, tokens, aligned, softOK: softOK, spanEnd: end) }
            }
            i = end + 1
        }
        return result
    }

    /// A self-correction span has abandoned content, ends in editing terms, and is followed by kept text.
    /// A lone "no" (or content after the term, as in "I have no money") is not a correction.
    private static func isCorrection(_ tokens: [String], _ span: ClosedRange<Int>, soft: [Bool], editing: [Bool]) -> Bool {
        guard span.upperBound < tokens.count - 1, let lastEdit = span.last(where: { editing[$0] }) else { return false }
        func isContent(_ k: Int) -> Bool { !editing[k] && !soft[k] && !TranscriptText.isHardFiller(tokens[k]) }
        if (lastEdit + 1..<span.upperBound + 1).contains(where: isContent) { return false }
        return (span.lowerBound..<lastEdit).contains(where: isContent)
    }

    /// A soft marker may vanish silently only when the original text shows it as a discourse marker: at the
    /// start, after a sentence boundary, set off by commas, or beside a filler. Beside another marker it is
    /// excused only if that neighbour is itself excused and also removed, so a chain must be anchored by an
    /// independent rule ("so right now" keeps "so", which cannot excuse deleting "right"). Otherwise it is
    /// content ("turn right", "I like pizza").
    private static func deletableSoftMask(_ info: [TranscriptToken], soft: [Bool], aligned: [Bool]) -> [Bool] {
        let words = info.map { $0.word }
        var groups: [ClosedRange<Int>] = []
        var s = 0
        while s < words.count {
            guard soft[s] else { s += 1; continue }
            let length = TranscriptText.softPhrases.first(where: { s + $0.count <= words.count && Array(words[s..<s + $0.count]) == $0 })?.count ?? 1
            groups.append(s...(s + length - 1))
            s += length
        }
        var excused = groups.map { g -> Bool in
            let setOff = g.lowerBound == 0 || info[g.lowerBound].boundaryBefore || info[g.lowerBound].commaBefore || info[g.upperBound].commaAfter
            let nextToFiller = (g.lowerBound > 0 && TranscriptText.isHardFiller(words[g.lowerBound - 1]))
                || (g.upperBound + 1 < words.count && TranscriptText.isHardFiller(words[g.upperBound + 1]))
            return setOff || nextToFiller
        }
        var grew = true
        while grew {
            grew = false
            for (n, g) in groups.enumerated() where !excused[n] {
                let neighbours = [n - 1, n + 1].filter { groups.indices.contains($0) }
                    .filter { excused[$0] && !aligned[groups[$0].lowerBound] && (groups[$0].upperBound + 1 == g.lowerBound || g.upperBound + 1 == groups[$0].lowerBound) }
                if !neighbours.isEmpty { excused[n] = true; grew = true }
            }
        }
        var ok = [Bool](repeating: false, count: words.count)
        for (n, g) in groups.enumerated() { for k in g { ok[k] = excused[n] } }
        return ok
    }

    private static func explanation(for k: Int, _ tokens: [String], _ aligned: [Bool], softOK: [Bool], spanEnd: Int) -> Explanation {
        if TranscriptText.isHardFiller(tokens[k]) || softOK[k] { return .filler }
        var lo = k, hi = k
        while lo > 0 && tokens[lo - 1] == tokens[k] { lo -= 1 }
        while hi + 1 < tokens.count && tokens[hi + 1] == tokens[k] { hi += 1 }
        if (lo...hi).contains(where: { aligned[$0] }) && hi > lo { return .stutter }
        let window = (spanEnd + 1)..<min(tokens.count, spanEnd + 1 + restartWindow)
        return window.contains(where: { aligned[$0] && tokens[$0] == tokens[k] }) ? .restart : .none
    }

    // MARK: checks

    private static func checkAdded(_ added: [String], cleanCount: Int, _ f: inout Findings) {
        guard !added.isEmpty else { return }
        let heavy = added.count >= 3 || Double(added.count) > 0.15 * Double(cleanCount)
        f.add(.addedContent, heavy ? .reject : .review)
    }

    private static func checkDeletions(_ unexplained: Int, nonFillerCount: Int, _ f: inout Findings) {
        guard unexplained > 0 else { return }
        let heavy = unexplained >= 6 || Double(unexplained) > 0.25 * Double(nonFillerCount)
        f.add(.unexplainedDeletion, heavy ? .reject : .review)
    }

    private static func checkCorrections(_ tokens: [String], _ aligned: [Bool], _ explanations: [Explanation],
                                         kept: Set<String>, raw: String, _ f: inout Findings) {
        let names = capitalizedNames(in: raw)
        for k in tokens.indices where !aligned[k] && (explanations[k] == .correction || explanations[k] == .restart) && !kept.contains(tokens[k]) {
            if TranscriptText.isNumber(tokens[k]) { f.add(.numberInCorrection, .review) }
            if names.contains(tokens[k]) { f.add(.nameInCorrection, .review) }
        }
    }

    private static func checkNegationAndNumbers(_ raw: [String], _ clean: [String], _ aligned: [Bool],
                                                _ explanations: [Explanation], _ f: inout Findings) {
        let surviving = raw.indices.filter { aligned[$0] || explanations[$0] == .none }.map { raw[$0] }
        if surviving.filter(TranscriptText.isNegation).count != clean.filter(TranscriptText.isNegation).count {
            f.add(.negationChanged, .reject)
        }
        if surviving.filter(TranscriptText.isNumber).sorted() != clean.filter(TranscriptText.isNumber).sorted() {
            f.add(.numberChanged, .reject)
        }
    }

    private static func checkNames(raw: String, rawTokens: [String], cleanTokens: [String], _ aligned: [Bool],
                                   _ explanations: [Explanation], _ f: inout Findings) {
        let cleanSet = Set(cleanTokens)
        for name in capitalizedNames(in: raw) where !cleanSet.contains(name) {
            if rawTokens.indices.contains(where: { rawTokens[$0] == name && !aligned[$0] && explanations[$0] == .none }) {
                f.add(.nameRemoved, .review)
            }
        }
    }

    /// Normalized words that are capitalized in the original text, excluding sentence starts and "I".
    /// Lowercase ASR output simply yields none.
    static func capitalizedNames(in raw: String) -> Set<String> {
        let pieces = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var names = Set<String>()
        for (index, piece) in pieces.enumerated() {
            let startsSentence = index == 0 || [".", "!", "?"].contains(where: { pieces[index - 1].hasSuffix($0) })
            guard !startsSentence, let first = piece.first(where: { $0.isLetter || $0.isNumber }), first.isUppercase else { continue }
            for word in TranscriptText.words(piece) where word != "i" && !word.hasPrefix("i'")
                && !TranscriptText.isNumber(word) && !TranscriptText.isHardFiller(word) {
                names.insert(word)
            }
        }
        return names
    }
}
