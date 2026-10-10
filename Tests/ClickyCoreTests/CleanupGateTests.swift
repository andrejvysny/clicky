import XCTest
@testable import ClickyCore

final class CleanupGateTests: XCTestCase {
    private func verdict(_ raw: String, _ cleaned: String) -> CleanupVerdict {
        CleanupGate.assess(raw: raw, cleaned: cleaned).verdict
    }

    // a
    func testAnsweringTheQuestionIsRejected() {
        let a = CleanupGate.assess(raw: "what kind of a car do you think you'll buy next", cleaned: "I would buy a Tesla Model 3.")
        XCTAssertEqual(a.verdict, .reject)
        XCTAssertTrue(a.concerns.contains(.addedContent))
    }

    // b, c
    func testWrongRepairKeepingAbandonedStartIsNotAccepted() {
        let raw = "what do you think you'll uh what kind of a car do you think you'll buy next"
        let a = CleanupGate.assess(raw: raw, cleaned: "What do you think you'll buy next?")
        XCTAssertNotEqual(a.verdict, .accept)
        XCTAssertEqual(a.removedWords, ["kind", "of", "a", "car"])
    }

    func testCorrectRepairIsAccepted() {
        let raw = "what do you think you'll uh what kind of a car do you think you'll buy next"
        let a = CleanupGate.assess(raw: raw, cleaned: "What kind of a car do you think you'll buy next?")
        XCTAssertEqual(a.verdict, .accept)
        XCTAssertEqual(a.removedWords, [])
        XCTAssertEqual(a.explainedRemovals, 7)
    }

    func testAlignmentPrefersLaterRawOccurrence() {
        let (rawAligned, _) = CleanupGate.align(["a", "b", "a", "b"], ["a", "b"])
        XCTAssertEqual(rawAligned, [false, false, true, true])
    }

    // d, e
    func testInventedRepetitionIsNotAccepted() {
        let a = CleanupGate.assess(raw: "from the banks of the river", cleaned: "from the banks of the banks of the river")
        XCTAssertEqual(a.verdict, .reject)
        XCTAssertEqual(a.addedWords.count, 3)
    }

    func testDeletingContentIsNotAccepted() {
        XCTAssertNotEqual(verdict("we walked from the banks of the river", "from the river"), .accept)
        XCTAssertEqual(verdict("from the banks of the river", "from the river"), .reject)
    }

    // f, g
    func testFillerRemovalIsAccepted() {
        XCTAssertEqual(verdict("um so I think uh we should go", "So I think we should go."), .accept)
    }

    func testStutterRemovalIsAccepted() {
        XCTAssertEqual(verdict("I I think the the plan works", "I think the plan works."), .accept)
        XCTAssertEqual(verdict("I I I think we can", "I think we can."), .accept)
    }

    // h
    func testNegationFlipIsRejected() {
        let a = CleanupGate.assess(raw: "I don't think we should ship it", cleaned: "I think we should ship it.")
        XCTAssertEqual(a.verdict, .reject)
        XCTAssertTrue(a.concerns.contains(.negationChanged))
    }

    func testLoneNoIsNotTreatedAsCorrection() {
        XCTAssertEqual(verdict("there is no way out", "there is way out"), .reject)
        XCTAssertEqual(verdict("I have no money", "I have money"), .reject)
    }

    // i
    func testNumberCorrectionNeedsReview() {
        let a = CleanupGate.assess(raw: "meet at 5 no wait 6 pm", cleaned: "Meet at 6 pm.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertEqual(a.concerns, [.numberInCorrection])
    }

    func testChangedNumberIsRejected() {
        let a = CleanupGate.assess(raw: "send 3 copies", cleaned: "send 4 copies")
        XCTAssertEqual(a.verdict, .reject)
        XCTAssertTrue(a.concerns.contains(.numberChanged))
        XCTAssertEqual(verdict("send three copies please now", "Send 3 copies please now."), .accept)
    }

    func testStutteredNumberIsReviewedNotRejected() {
        // "5 5" may be a stutter or a real value; a person decides, but it is not treated as a changed number.
        let a = CleanupGate.assess(raw: "send 5 5 copies today", cleaned: "Send 5 copies today.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertEqual(a.concerns, [.protectedRepetition])
    }

    // j
    func testRemovedNameIsNotAccepted() {
        let a = CleanupGate.assess(raw: "tell Martina about it", cleaned: "tell her about it")
        XCTAssertNotEqual(a.verdict, .accept)
        XCTAssertTrue(a.concerns.contains(.nameRemoved))
        XCTAssertEqual(verdict("please tell Martina about the new plan for tomorrow morning", "Please tell about the new plan for tomorrow morning."), .review)
    }

    func testNameInCorrectionNeedsReview() {
        let a = CleanupGate.assess(raw: "ask Martina no sorry ask Peter about it", cleaned: "Ask Peter about it.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertEqual(a.concerns, [.nameInCorrection])
    }

    func testLowercaseRawHasNoNameCheck() {
        let a = CleanupGate.assess(raw: "please tell martina about the new plan for tomorrow morning", cleaned: "Please tell about the new plan for tomorrow morning.")
        XCTAssertFalse(a.concerns.contains(.nameRemoved))
    }

    // k
    func testEditingTermCorrectionWithoutNumbersIsAccepted() {
        let a = CleanupGate.assess(raw: "turn left no sorry turn right at the light", cleaned: "Turn right at the light.")
        XCTAssertEqual(a.verdict, .accept)
        XCTAssertEqual(a.explainedRemovals, 4)
    }

    // l
    func testSilenceIsNoSpeech() {
        XCTAssertEqual(verdict("", "anything"), .noSpeech)
        XCTAssertEqual(verdict("uh um", ""), .noSpeech)
        XCTAssertEqual(verdict("  Uh, um...  ", "Uh."), .noSpeech)
        XCTAssertEqual(CleanupGate.assess(raw: "hello there", cleaned: "").concerns, [.emptyCleanup])
        XCTAssertEqual(verdict("hello there", "  ?! "), .reject)
    }

    // m
    func testSummarizingIsRejected() {
        let raw = "so yesterday we met with the client and went through the whole roadmap and they asked for more time on the budget"
        let a = CleanupGate.assess(raw: raw, cleaned: "We met the client about the budget.")
        XCTAssertEqual(a.verdict, .reject)
        XCTAssertTrue(a.concerns.contains(.unexplainedDeletion))
        XCTAssertTrue(a.concerns.contains(.tooShort) || a.concerns.contains(.lowRecall))
    }

    // edge cases
    func testIdenticalPunctuationAndCapitalizationOnlyChangesAreAccepted() {
        XCTAssertEqual(verdict("we should go home", "we should go home"), .accept)
        XCTAssertEqual(verdict("we should go home", "We should go home."), .accept)
        XCTAssertEqual(verdict("we should go home", "We should, go: home!"), .accept)
        XCTAssertEqual(verdict("we should go home", "WE SHOULD GO HOME"), .accept)
    }

    func testSpelledNumbersMatchDigits() {
        XCTAssertEqual(verdict("it costs twenty five dollars", "It costs $25 dollars."), .accept)
    }

    func testUnicodeText() {
        XCTAssertEqual(verdict("ich möchte um halb acht Uhr gehen", "Ich möchte um halb acht Uhr gehen."), .accept)
        XCTAssertEqual(verdict("dobrý deň uh pozdravte Martinu", "Dobrý deň, pozdravte Martinu."), .accept)
        XCTAssertEqual(verdict("我们 去 公园 吧", "我们去公园吧"), .reject) // unspaced script cannot be tokenized: never auto-accepted
    }

    func testRestartedSentenceIsExplained() {
        XCTAssertEqual(verdict("we should we should go to the park", "We should go to the park."), .accept)
    }

    func testVeryLongInputGoesToReview() {
        let long = Array(repeating: "word", count: CleanupGate.maxTokens + 1).joined(separator: " ")
        let a = CleanupGate.assess(raw: long, cleaned: long)
        XCTAssertEqual(a.verdict, .review)
        XCTAssertEqual(a.concerns, [.inputTooLong])
        let atCap = Array(repeating: "word", count: CleanupGate.maxTokens).joined(separator: " ")
        XCTAssertEqual(verdict(atCap, atCap), .accept)
    }

    func testAddedNegationIsRejected() {
        XCTAssertEqual(verdict("we should ship it today", "We should not ship it today."), .reject)
    }

    func testSoftMarkersAreDeletableOnlyWhenSetOff() {
        XCTAssertNotEqual(verdict("turn right at the light", "turn at the light"), .accept)
        XCTAssertNotEqual(verdict("I like pizza", "I pizza"), .accept)
        XCTAssertEqual(verdict("so I think we should go", "I think we should go"), .accept)
        XCTAssertEqual(verdict("um like we should go", "We should go."), .accept)
        XCTAssertEqual(verdict("It works. So we should go", "It works. We should go."), .accept)
        XCTAssertEqual(verdict("it was like, really big", "It was really big."), .accept)
        XCTAssertEqual(verdict("we went, you know, home", "We went home."), .accept)
        XCTAssertEqual(verdict("and in a like, a park", "And in a park."), .accept)
        XCTAssertNotEqual(verdict("we went you know home", "We went home."), .accept)
    }

    func testContractionsEqualTheirExpansions() {
        XCTAssertEqual(verdict("i'm gonna send it", "I am going to send it."), .accept)
        XCTAssertEqual(verdict("I don't know", "I do not know"), .accept)
        XCTAssertEqual(verdict("I can't go", "I cannot go."), .accept)
        XCTAssertEqual(verdict("I do not know", "I don't know."), .accept)
        XCTAssertEqual(verdict("we're sure it's fine", "We are sure it is fine."), .accept)
        XCTAssertEqual(verdict("I don't know", "I know"), .reject)
    }

    func testSoftMarkerChainsNeedAnAnchor() {
        XCTAssertNotEqual(verdict("so right now we leave", "so now we leave"), .accept)
        XCTAssertNotEqual(verdict("turn so right", "turn so"), .accept)
        XCTAssertEqual(verdict("um so like we should go", "we should go"), .accept)
        XCTAssertEqual(verdict("well, like, I think so", "I think so"), .accept)
    }

    func testMoreContractionsEqualTheirExpansions() {
        XCTAssertEqual(verdict("I didn't go", "I did not go"), .accept)
        XCTAssertEqual(verdict("I did not go", "I didn't go"), .accept)
        XCTAssertEqual(verdict("I didn't go", "I did go"), .reject)
        XCTAssertEqual(verdict("she doesn't know", "She does not know."), .accept)
        XCTAssertEqual(verdict("they weren't ready", "They were not ready."), .accept)
        XCTAssertEqual(verdict("we haven't finished", "We have not finished."), .accept)
        XCTAssertEqual(verdict("he couldn't come", "He could not come."), .accept)
        XCTAssertEqual(verdict("he's late and who's there", "He is late and who is there."), .accept)
        XCTAssertEqual(verdict("we'll go and they've left", "We will go and they have left."), .accept)
        XCTAssertEqual(verdict("you'd know we'd agree", "You would know we would agree."), .accept)
        XCTAssertEqual(verdict("I wouldn't go", "I would go"), .reject)
    }

    func testIsHasAmbiguityAcceptsEitherExpansion() {
        XCTAssertEqual(verdict("it's been a while", "It has been a while."), .accept)
        XCTAssertEqual(verdict("it's fine", "It is fine."), .accept)
    }

    func testTokenClasses() {
        XCTAssertTrue(TranscriptText.isNumber("25"))
        XCTAssertTrue(TranscriptText.isNumber("1st"))
        XCTAssertFalse(TranscriptText.isNumber("first1"))
        XCTAssertTrue(TranscriptText.isNegation("won't"))
        XCTAssertFalse(TranscriptText.isNegation("note"))
        XCTAssertEqual(TranscriptText.words("You'll, don't!"), ["you'll", "don't"])
    }

    func testHasReadingOfApostropheSRequiresParticiple() {
        XCTAssertEqual(CleanupGate.assess(raw: "it's been a while", cleaned: "It has been a while.").verdict, .accept)
        XCTAssertEqual(CleanupGate.assess(raw: "she's finished the report", cleaned: "She has finished the report.").verdict, .accept)
        XCTAssertNotEqual(CleanupGate.assess(raw: "it's fine", cleaned: "It has fine.").verdict, .accept)
    }

    // Review findings F1: WER normalization must not hide sign, decimal or intentional repetition changes.
    func testDroppedMinusSignNeedsReview() {
        let a = CleanupGate.assess(raw: "The temperature is -5 degrees.", cleaned: "The temperature is 5 degrees.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertTrue(a.concerns.contains(.numberFormatChanged))
    }

    func testRepeatedDigitRemovalNeedsReview() {
        let a = CleanupGate.assess(raw: "The number is 5 5 1.", cleaned: "The number is 5 1.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertTrue(a.concerns.contains(.protectedRepetition))
    }

    func testSplitDecimalNeedsReview() {
        let a = CleanupGate.assess(raw: "The amount is 3.50 euros.", cleaned: "The amount is 3 50 euros.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertTrue(a.concerns.contains(.numberFormatChanged))
    }

    func testRepeatedNegationRemovalNeedsReview() {
        let a = CleanupGate.assess(raw: "I do not not agree with you.", cleaned: "I do not agree with you.")
        XCTAssertEqual(a.verdict, .review)
        XCTAssertTrue(a.concerns.contains(.protectedRepetition))
    }

    func testNumericFormsThatKeepMeaningAreAccepted() {
        XCTAssertEqual(verdict("um the temperature is minus five degrees", "The temperature is -5 degrees."), .accept)
        XCTAssertEqual(verdict("it costs uh three point five euros", "It costs 3.5 euros."), .accept)
        XCTAssertEqual(verdict("it is negative 5 today", "It is -5 today."), .accept)
        XCTAssertEqual(verdict("pages 5-10 and a well-known fix", "Pages 5-10 and a well-known fix."), .accept)
    }

    func testOrdinaryStutterAndFillerCleanupStillAccepted() {
        XCTAssertEqual(verdict("so um I I think we should uh leave at noon", "I think we should leave at noon."), .accept)
    }

    func testNegationDeletionAndNumberSubstitutionStillRejected() {
        XCTAssertEqual(verdict("I do not want to go there", "I do want to go there."), .reject)
        XCTAssertEqual(verdict("the meeting is at 5 tomorrow", "The meeting is at 6 tomorrow."), .reject)
    }
}
