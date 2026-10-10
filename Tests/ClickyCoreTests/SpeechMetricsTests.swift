import XCTest
@testable import ClickyCore

final class SpeechMetricsTests: XCTestCase {
    // Expected values come from voice-benchmark benchmark/normalize.py (NORMALIZER_VERSION 1).
    func testNormalizationMatchesPython() {
        let cases: [(String, String)] = [
            ("Hello, World!", "hello world"),
            ("I\u{2019}ll pay twenty five dollars", "i'll pay 25 dollars"),
            ("It costs 1,250 and 50% off", "it costs 1250 and 50 percent off"),
            ("twenty-one hundred and five", "2105"),
            ("The Colour of the Theatre, okay? alright", "the color of the theater ok all right"),
            ("one thousand two hundred thirty four", "1234"),
            ("Uh, um... don't go!  'quoted' text", "uh um don't go quoted text"),
            ("Caf\u{E9} NA\u{CF}VE \u{FB01}ne", "caf\u{E9} na\u{EF}ve fine"),
            ("3.5 apples", "3 5 apples"),
            ("five six", "5 6"),
            ("forty two thousand and seven", "42000 and 7"),
            ("one two three four", "1 2 3 4"),
            ("", ""),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TranscriptText.normalize(input), expected, input)
        }
    }

    func testWordAndCharacterCountsMatchPython() {
        XCTAssertEqual(SpeechMetrics.wordCounts(reference: "the cat sat", hypothesis: "the cat sat down"), ErrorCounts(errors: 1, referenceUnits: 3))
        XCTAssertEqual(SpeechMetrics.characterCounts(reference: "the cat sat", hypothesis: "the cat sat down"), ErrorCounts(errors: 5, referenceUnits: 11))
        XCTAssertEqual(SpeechMetrics.wordCounts(reference: "hello world", hypothesis: "hallo word"), ErrorCounts(errors: 2, referenceUnits: 2))
        XCTAssertEqual(SpeechMetrics.characterCounts(reference: "hello world", hypothesis: "hallo word"), ErrorCounts(errors: 2, referenceUnits: 11))
        XCTAssertEqual(SpeechMetrics.wordCounts(reference: "one two three four", hypothesis: "1 2 three"), ErrorCounts(errors: 1, referenceUnits: 4))
        XCTAssertEqual(SpeechMetrics.characterCounts(reference: "one two three four", hypothesis: "1 2 three"), ErrorCounts(errors: 2, referenceUnits: 7))
        XCTAssertEqual(SpeechMetrics.wordCounts(reference: "a b c d", hypothesis: ""), ErrorCounts(errors: 4, referenceUnits: 4))
        XCTAssertEqual(SpeechMetrics.characterCounts(reference: "a b c d", hypothesis: ""), ErrorCounts(errors: 7, referenceUnits: 7))
    }

    func testRatesAndEmptyReference() {
        XCTAssertEqual(SpeechMetrics.wordErrorRate(reference: "The cat, sat!", hypothesis: "the cat sat down"), 1.0 / 3.0)
        XCTAssertEqual(SpeechMetrics.wordErrorRate(reference: "same words", hypothesis: "Same words."), 0)
        XCTAssertNil(SpeechMetrics.wordErrorRate(reference: "", hypothesis: "extra"))
        XCTAssertEqual(SpeechMetrics.wordCounts(reference: "", hypothesis: "extra words").errors, 2)
        XCTAssertNil(SpeechMetrics.characterErrorRate(reference: "?!", hypothesis: "x"))
    }

    func testCorpusRateIsTotalErrorsOverTotalReferenceWords() {
        let pairs = [(reference: "a b", hypothesis: "a b"), (reference: "one two three four five six", hypothesis: "x")]
        // errors 0 + 6 over 2 + 6 words; a mean of rates would give 0.5
        XCTAssertEqual(SpeechMetrics.corpusWordErrorRate(pairs), 6.0 / 8.0)
        XCTAssertNil(SpeechMetrics.corpusWordErrorRate([]))
        XCTAssertNotNil(SpeechMetrics.corpusCharacterErrorRate(pairs))
    }

    func testEditDistanceIsGeneric() {
        XCTAssertEqual(SpeechMetrics.editDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(SpeechMetrics.editDistance([1, 2, 3], [Int]()), 3)
        XCTAssertEqual(SpeechMetrics.editDistance([Int](), [1, 2]), 2)
        XCTAssertEqual(SpeechMetrics.editDistance(["a", "b"], ["a", "b"]), 0)
    }

    func testPercentileMatchesNumpyLinear() {
        let values = [15.0, 20, 35, 40, 50]
        XCTAssertEqual(SpeechMetrics.percentile(values, 0), 15)
        XCTAssertEqual(SpeechMetrics.percentile(values, 50), 35)
        XCTAssertEqual(SpeechMetrics.percentile(values, 100), 50)
        XCTAssertEqual(SpeechMetrics.percentile(values, 40)!, 29, accuracy: 1e-9)
        XCTAssertEqual(SpeechMetrics.percentile([4, 1, 3, 2], 95)!, 3.85, accuracy: 1e-9)
        XCTAssertEqual(SpeechMetrics.percentile([7], 95), 7)
        XCTAssertNil(SpeechMetrics.percentile([], 50))
        XCTAssertNil(SpeechMetrics.percentile(values, 101))
        XCTAssertNil(SpeechMetrics.percentile([1, .nan], 50))
    }

    func testMeanStandardDeviationAndRealTimeFactor() {
        let stats = SpeechMetrics.meanAndStandardDeviation([2, 4, 4, 4, 5, 5, 7, 9])!
        XCTAssertEqual(stats.mean, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.standardDeviation, 2, accuracy: 1e-9)
        XCTAssertNil(SpeechMetrics.meanAndStandardDeviation([]))
        XCTAssertEqual(SpeechMetrics.realTimeFactor(processingSeconds: 1, audioSeconds: 4), 0.25)
        XCTAssertNil(SpeechMetrics.realTimeFactor(processingSeconds: 1, audioSeconds: 0))
    }
}
