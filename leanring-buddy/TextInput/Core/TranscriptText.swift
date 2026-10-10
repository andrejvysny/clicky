import Foundation

/// Deterministic transcript normalization and token classes shared by the cleanup gate and the metrics.
/// `normalize` is a port of voice-benchmark `benchmark/normalize.py` (version 1) so Swift and Python
/// WER/CER agree. Known deviations: Swift `lowercased()` can differ from Python `str.lower()` on exotic
/// scripts; decimals are split at the point exactly as in Python ("3.5" -> "3 5").
nonisolated public enum TranscriptText {
    public static let hardFillers: Set<String> = ["uh", "um", "uhm", "er", "erm", "ah", "eh", "hmm", "mm", "mhm", "huh"]
    /// Single-token soft markers; "you know" and "i mean" are handled as phrases. "okay" is "ok" after normalization.
    static let softSingles: Set<String> = ["like", "so", "well", "ok", "oh", "actually", "basically", "right"]
    static let softPhrases: [[String]] = [["you", "know"], ["i", "mean"]]
    static let editingSingles: Set<String> = ["no", "sorry", "wait", "actually", "rather"]
    static let editingPhrases: [[String]] = [["i", "mean"], ["scratch", "that"], ["or", "rather"]]
    static let negationSingles: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without", "cannot"]

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let spelling: [String: String] = [
        "colour": "color", "favourite": "favorite", "realise": "realize", "realised": "realized",
        "organise": "organize", "organised": "organized", "centre": "center", "theatre": "theater",
        "okay": "ok", "o.k.": "ok", "alright": "all right",
    ]

    private static let punctuation = try! NSRegularExpression(pattern: "[^\\w\\s']")
    private static let edgeApostrophe = try! NSRegularExpression(pattern: "(?<!\\w)'|'(?!\\w)")
    private static let digitGroup = try! NSRegularExpression(pattern: "(?<=\\d),(?=\\d{3}\\b)")

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func splitWhitespace(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func normalize(_ text: String) -> String {
        wordsToNumbers(preNumberTokens(text)).joined(separator: " ")
    }

    /// Every normalization step except collapsing spelled numbers, which must see neighbouring words.
    private static func preNumberTokens(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var t = text.precomposedStringWithCompatibilityMapping.lowercased()
        t = t.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        t = replacing(digitGroup, in: t, with: "")
        t = t.replacingOccurrences(of: "%", with: " percent ").replacingOccurrences(of: "-", with: " ")
        t = replacing(punctuation, in: t, with: " ")
        t = replacing(edgeApostrophe, in: t, with: " ")
        let spelled = splitWhitespace(t).map { spelling[$0] ?? $0 }
        return splitWhitespace(spelled.joined(separator: " "))
    }

    /// Normalized tokens; apostrophes stay inside words ("don't").
    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    public static func isHardFiller(_ token: String) -> Bool { hardFillers.contains(token) }

    public static func isNegation(_ token: String) -> Bool {
        negationSingles.contains(token) || token.hasSuffix("n't")
    }

    /// Digits only, or digits with an ordinal suffix. Decimals never occur: normalization splits at the point.
    public static func isNumber(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        let digits = token.prefix(while: { $0.isASCII && $0.isNumber })
        let suffix = token.dropFirst(digits.count)
        return !digits.isEmpty && ["st", "nd", "rd", "th"].contains(String(suffix))
    }

    /// Per-token flags for multi-word phrases ("you know"); every token of a matching phrase is marked.
    static func mask(_ tokens: [String], singles: Set<String>, phrases: [[String]]) -> [Bool] {
        var flags = tokens.map { singles.contains($0) }
        for phrase in phrases where tokens.count >= phrase.count {
            for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<start + phrase.count]) == phrase {
                for k in start..<start + phrase.count { flags[k] = true }
            }
        }
        return flags
    }

    static func softMask(_ tokens: [String]) -> [Bool] { mask(tokens, singles: softSingles, phrases: softPhrases) }
    static func editingMask(_ tokens: [String]) -> [Bool] { mask(tokens, singles: editingSingles, phrases: editingPhrases) }

    // MARK: spelled-out cardinals (port of _parse_number / _words_to_numbers)

    private static func isNumberWord(_ t: String) -> Bool { ones[t] != nil || tens[t] != nil }

    private static func accepts(_ t: String, current: Int, prev: String?) -> Bool {
        if let v = ones[t] {
            return current % 100 == 0 || (v < 10 && prev.map { tens[$0] != nil } == true)
        }
        if tens[t] != nil { return current % 100 == 0 }
        if t == "hundred" { return current % 1000 > 0 && current % 1000 < 100 && prev != "hundred" }
        if scales[t] != nil { return current > 0 }
        return false
    }

    private static func parseNumber(_ tokens: [String], from start: Int) -> (value: Int, end: Int) {
        var total = 0, current = 0, j = start
        var prev: String?
        while j < tokens.count {
            let t = tokens[j]
            if t == "and", current >= 100, current % 100 == 0, j + 1 < tokens.count, isNumberWord(tokens[j + 1]) {
                j += 1
                continue
            }
            guard accepts(t, current: current, prev: prev) else { break }
            if let v = ones[t] {
                current += v
            } else if let v = tens[t] {
                current += v
            } else if t == "hundred" {
                current = (current / 100) * 100 + (current % 100) * 100
            } else if let s = scales[t] {
                total += current * s
                current = 0
            }
            prev = t
            j += 1
        }
        return (total + current, j)
    }

    private static func wordsToNumbers(_ tokens: [String]) -> [String] {
        groupNumbers(tokens).map { $0.word }
    }

    /// Collapses spelled cardinals; each result remembers the source token range it came from.
    private static func groupNumbers(_ tokens: [String]) -> [(word: String, range: Range<Int>)] {
        var out: [(word: String, range: Range<Int>)] = []
        var i = 0
        while i < tokens.count {
            guard isNumberWord(tokens[i]) else {
                out.append((tokens[i], i..<i + 1))
                i += 1
                continue
            }
            let parsed = parseNumber(tokens, from: i)
            out.append((String(parsed.value), i..<parsed.end))
            i = parsed.end
        }
        return out
    }

    // MARK: tokens with original-text context

    static let contractions: [String: [String]] = [
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"], "kinda": ["kind", "of"],
        "cause": ["because"], "i'm": ["i", "am"], "it's": ["it", "is"], "don't": ["do", "not"], "can't": ["cannot"],
        "won't": ["will", "not"], "isn't": ["is", "not"], "let's": ["let", "us"], "we're": ["we", "are"],
        "you're": ["you", "are"], "they're": ["they", "are"], "that's": ["that", "is"], "i'll": ["i", "will"],
        "you'll": ["you", "will"], "i've": ["i", "have"], "i'd": ["i", "would"],
        "doesn't": ["does", "not"], "didn't": ["did", "not"], "aren't": ["are", "not"], "wasn't": ["was", "not"],
        "weren't": ["were", "not"], "haven't": ["have", "not"], "hasn't": ["has", "not"], "hadn't": ["had", "not"],
        "couldn't": ["could", "not"], "shouldn't": ["should", "not"], "wouldn't": ["would", "not"],
        "he's": ["he", "is"], "she's": ["she", "is"], "there's": ["there", "is"], "what's": ["what", "is"],
        "where's": ["where", "is"], "who's": ["who", "is"],
        "we'll": ["we", "will"], "they'll": ["they", "will"], "we've": ["we", "have"], "they've": ["they", "have"],
        "you've": ["you", "have"], "we'd": ["we", "would"], "they'd": ["they", "would"], "you'd": ["you", "would"],
    ]

    private static func endsSentence(_ piece: String) -> Bool {
        guard let last = piece.last(where: { !"\"')]}\u{201D}\u{2019}".contains($0) }) else { return false }
        return ".!?\u{2026}".contains(last)
    }

    private static func endsWithComma(_ piece: String) -> Bool {
        piece.last(where: { !"\"')]}\u{201D}\u{2019}".contains($0) }) == ","
    }

    /// Normalized tokens (same words as `words`) plus whether each sat after a sentence boundary or beside a
    /// comma in the ORIGINAL text. With `expandContractions`, "gonna" becomes "going to" etc. so that
    /// contraction vs. expansion compares equal; the expansion shares the original token's context.
    static func tokens(_ text: String, expandContractions: Bool = false) -> [TranscriptToken] {
        let pieces = splitWhitespace(text)
        var flat: [(word: String, piece: Int, first: Bool, last: Bool)] = []
        for (p, piece) in pieces.enumerated() {
            let ws = preNumberTokens(piece)
            for (j, w) in ws.enumerated() { flat.append((w, p, j == 0, j == ws.count - 1)) }
        }
        var out: [TranscriptToken] = []
        for group in groupNumbers(flat.map { $0.word }) {
            let head = flat[group.range.lowerBound], tail = flat[group.range.upperBound - 1]
            let before = head.first
            let token = TranscriptToken(
                word: group.word,
                boundaryBefore: before && (head.piece == 0 || endsSentence(pieces[head.piece - 1])),
                commaBefore: before && head.piece > 0 && endsWithComma(pieces[head.piece - 1]),
                commaAfter: tail.last && endsWithComma(pieces[tail.piece]))
            guard expandContractions, let expansion = contractions[group.word] else { out.append(token); continue }
            for (k, w) in expansion.enumerated() {
                var part = token
                part.word = w
                if k > 0 { part.boundaryBefore = false; part.commaBefore = false }
                if k < expansion.count - 1 { part.commaAfter = false }
                part.ambiguousIs = group.word.hasSuffix("'s") && k == 1 && w == "is"
                out.append(part)
            }
        }
        return out
    }
}

nonisolated public struct TranscriptToken: Equatable, Sendable {
    public var word: String
    public var boundaryBefore: Bool
    public var commaBefore: Bool
    public var commaAfter: Bool
    /// The "is" of an expanded "<x>'s", which may equally have meant "has".
    public var ambiguousIs = false
}
