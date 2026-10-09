import XCTest
@testable import ClickyCore

final class WritingDefinitionsTests: XCTestCase {
    private func assertThrows<T>(_ expected: DefinitionError, _ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? DefinitionError, expected, file: file, line: line) }
    }

    private func snippet(_ defs: inout WritingDefinitions, alias: String = "sig", body: String = "hello") throws -> SavedSnippet {
        try defs.addSnippet(name: "Sig", alias: alias, summary: "", body: body, restriction: .any)
    }

    private func skill(_ defs: inout WritingDefinitions, alias: String = "tone") throws -> CustomSkill {
        try defs.addSkill(name: "Tone", alias: alias, summary: "", instructions: "Be kind.", operation: .rewrite)
    }

    func testAliasValidation() {
        for ok in ["a", "0", "a-b", "a-", "9lives", String(repeating: "a", count: 32)] {
            XCTAssertTrue(WritingDefinitions.isValidAlias(ok), ok)
        }
        for bad in ["", "-a", "A", "aB", "a b", "a.b", "a_b", "é", "a/b", String(repeating: "a", count: 33)] {
            XCTAssertFalse(WritingDefinitions.isValidAlias(bad), bad)
        }
        var defs = WritingDefinitions.empty
        assertThrows(.invalidAlias) { try defs.addSnippet(name: "n", alias: "Upper", summary: "", body: "b", restriction: .any) }
        assertThrows(.invalidAlias) { try defs.addSkill(name: "n", alias: String(repeating: "a", count: 33), summary: "", instructions: "i", operation: .draft) }
    }

    func testReservedAliases() {
        var defs = WritingDefinitions.empty
        for alias in ["write", "fix", "guide", "skills", "snippets", "settings", "help", "clicky", "professional", "reply"] {
            assertThrows(.aliasReserved(alias)) { try defs.addSnippet(name: "n", alias: alias, summary: "", body: "b", restriction: .any) }
            assertThrows(.aliasReserved(alias)) { try defs.addSkill(name: "n", alias: alias, summary: "", instructions: "i", operation: .draft) }
        }
        XCTAssertTrue(defs.snippets.isEmpty && defs.skills.isEmpty)
    }

    func testAliasCollisionsAcrossKinds() throws {
        var defs = WritingDefinitions.empty
        _ = try snippet(&defs, alias: "one")
        _ = try skill(&defs, alias: "two")
        assertThrows(.aliasTaken("one")) { try defs.addSnippet(name: "n", alias: "one", summary: "", body: "b", restriction: .any) }
        assertThrows(.aliasTaken("one")) { try defs.addSkill(name: "n", alias: "one", summary: "", instructions: "i", operation: .draft) }
        assertThrows(.aliasTaken("two")) { try defs.addSnippet(name: "n", alias: "two", summary: "", body: "b", restriction: .any) }
        var s = defs.snippets[0]
        s.alias = "two"
        assertThrows(.aliasTaken("two")) { try defs.updateSnippet(s) }
        s.alias = "one"
        s.name = "Renamed"
        XCTAssertNoThrow(try defs.updateSnippet(s)) // own alias is not a collision
    }

    func testFieldLimits() {
        var defs = WritingDefinitions.empty
        assertThrows(.emptyName) { try defs.addSnippet(name: " \n", alias: "a", summary: "", body: "b", restriction: .any) }
        assertThrows(.emptyName) { try defs.addSnippet(name: "", alias: "a", summary: "", body: "b", restriction: .any) }
        assertThrows(.nameTooLong) { try defs.addSnippet(name: String(repeating: "x", count: 81), alias: "a", summary: "", body: "b", restriction: .any) }
        XCTAssertNoThrow(try defs.addSnippet(name: String(repeating: "x", count: 80), alias: "a", summary: String(repeating: "s", count: 160), body: "b", restriction: .any))
        assertThrows(.summaryTooLong) { try defs.addSnippet(name: "n", alias: "b", summary: String(repeating: "s", count: 161), body: "b", restriction: .any) }
        assertThrows(.emptyBody) { try defs.addSnippet(name: "n", alias: "b", summary: "", body: "", restriction: .any) }
        assertThrows(.bodyTooLarge) { try defs.addSnippet(name: "n", alias: "b", summary: "", body: String(repeating: "a", count: 65_537), restriction: .any) }
        XCTAssertNoThrow(try defs.addSnippet(name: "n", alias: "c", summary: "", body: String(repeating: "a", count: 65_536), restriction: .any))
        assertThrows(.bodyTooLarge) { try defs.addSnippet(name: "n", alias: "d", summary: "", body: String(repeating: "é", count: 32_769), restriction: .any) }
        assertThrows(.emptyInstructions) { try defs.addSkill(name: "n", alias: "b", summary: "", instructions: " \n\t", operation: .draft) }
        assertThrows(.instructionsTooLarge) { try defs.addSkill(name: "n", alias: "b", summary: "", instructions: String(repeating: "a", count: 4_001), operation: .draft) }
        XCTAssertNoThrow(try defs.addSkill(name: "n", alias: "e", summary: "", instructions: String(repeating: "a", count: 4_000), operation: .draft))
    }

    func testWhitespaceOnlyBodyIsAllowedAndNameStoredExactly() throws {
        var defs = WritingDefinitions.empty
        let s = try defs.addSnippet(name: "  Padded  ", alias: "ws", summary: "", body: "   \n", restriction: .any)
        XCTAssertEqual(s.name, "  Padded  ")
        XCTAssertEqual(s.body, "   \n")
    }

    func testAddDefaults() throws {
        var defs = WritingDefinitions.empty
        let s = try snippet(&defs)
        XCTAssertEqual(s.revision, 1)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(defs.snippets, [s])
        let k = try skill(&defs)
        XCTAssertEqual(k.revision, 1)
        XCTAssertFalse(k.builtIn)
        XCTAssertNotEqual(s.id, k.id)
    }

    func testRevisionBumps() throws {
        var defs = WritingDefinitions.empty
        var s = try snippet(&defs)
        XCTAssertEqual(try defs.updateSnippet(s).revision, 1) // identical
        s.body = "changed"
        XCTAssertEqual(try defs.updateSnippet(s).revision, 2)
        XCTAssertEqual(defs.snippets[0].body, "changed")
        s.revision = 99 // caller revision is ignored
        XCTAssertEqual(try defs.updateSnippet(s).revision, 2)
        try defs.setSnippetEnabled(id: s.id, enabled: false)
        XCTAssertEqual(defs.snippets[0].revision, 3)
        try defs.setSnippetEnabled(id: s.id, enabled: false)
        XCTAssertEqual(defs.snippets[0].revision, 3)

        var k = try skill(&defs)
        XCTAssertEqual(try defs.updateSkill(k).revision, 1)
        k.instructions = "Be bold."
        XCTAssertEqual(try defs.updateSkill(k).revision, 2)
        try defs.setSkillEnabled(id: k.id, enabled: false)
        XCTAssertEqual(defs.skills[0].revision, 3)
        try defs.setSkillEnabled(id: k.id, enabled: false)
        XCTAssertEqual(defs.skills[0].revision, 3)
    }

    func testNotFoundAndBuiltInReadOnly() throws {
        var defs = WritingDefinitions.empty
        let ghost = UUID()
        assertThrows(.notFound) { try defs.deleteSnippet(id: ghost) }
        assertThrows(.notFound) { try defs.deleteSkill(id: ghost) }
        assertThrows(.notFound) { try defs.duplicateSnippet(id: ghost) }
        assertThrows(.notFound) { try defs.duplicateSkill(id: ghost) }
        assertThrows(.notFound) { try defs.setSnippetEnabled(id: ghost, enabled: false) }
        assertThrows(.notFound) { try defs.setSkillEnabled(id: ghost, enabled: false) }
        var s = try snippet(&defs)
        s.id = ghost
        assertThrows(.notFound) { try defs.updateSnippet(s) }
        var k = try skill(&defs)
        k.id = ghost
        assertThrows(.notFound) { try defs.updateSkill(k) }

        let builtIn = SlashCommandRegistry.builtInSkills[0]
        assertThrows(.builtInReadOnly) { try defs.updateSkill(builtIn) }
        assertThrows(.builtInReadOnly) { try defs.deleteSkill(id: builtIn.id) }
        assertThrows(.builtInReadOnly) { try defs.setSkillEnabled(id: builtIn.id, enabled: false) }
        assertThrows(.builtInReadOnly) { try defs.duplicateSkill(id: builtIn.id) }
        XCTAssertFalse(defs.skills.contains { $0.builtIn })
    }

    func testDuplicateSequence() throws {
        var defs = WritingDefinitions.empty
        let original = try defs.addSnippet(name: "Sig", alias: "sig", summary: "s", body: "b\n", restriction: .terminalOnly)
        let first = try defs.duplicateSnippet(id: original.id)
        XCTAssertEqual(first.name, "Sig copy")
        XCTAssertEqual(first.alias, "sig-copy")
        XCTAssertEqual(first.revision, 1)
        XCTAssertNotEqual(first.id, original.id)
        XCTAssertEqual(first.body, "b\n")
        XCTAssertEqual(first.restriction, .terminalOnly)
        XCTAssertEqual(try defs.duplicateSnippet(id: original.id).alias, "sig-copy-2")
        XCTAssertEqual(try defs.duplicateSnippet(id: original.id).alias, "sig-copy-3")
        XCTAssertEqual(try defs.duplicateSnippet(id: first.id).alias, "sig-copy-copy")
    }

    func testDuplicateTruncatesNameAndAlias() throws {
        var defs = WritingDefinitions.empty
        let longAlias = String(repeating: "a", count: 32)
        let s = try defs.addSnippet(name: String(repeating: "n", count: 80), alias: longAlias, summary: "", body: "b", restriction: .any)
        let c1 = try defs.duplicateSnippet(id: s.id)
        XCTAssertEqual(c1.name.count, 80)
        XCTAssertTrue(c1.name.hasSuffix(" copy"))
        XCTAssertEqual(c1.alias, String(repeating: "a", count: 27) + "-copy")
        let c2 = try defs.duplicateSnippet(id: s.id)
        XCTAssertEqual(c2.alias, String(repeating: "a", count: 25) + "-copy-2")
        XCTAssertTrue(WritingDefinitions.isValidAlias(c2.alias))
    }

    func testDuplicateSkillAvoidsSnippetAlias() throws {
        var defs = WritingDefinitions.empty
        let k = try skill(&defs, alias: "tone")
        _ = try snippet(&defs, alias: "tone-copy")
        XCTAssertEqual(try defs.duplicateSkill(id: k.id).alias, "tone-copy-2")
    }

    func testDeleteRemovesAndFreesAlias() throws {
        var defs = WritingDefinitions.empty
        let s = try snippet(&defs, alias: "gone")
        try defs.deleteSnippet(id: s.id)
        XCTAssertTrue(defs.snippets.isEmpty)
        XCTAssertNoThrow(try defs.addSkill(name: "n", alias: "gone", summary: "", instructions: "i", operation: .draft))
        let k = defs.skills[0]
        try defs.deleteSkill(id: k.id)
        XCTAssertTrue(defs.skills.isEmpty)
    }

    func testExactRoundTrip() throws {
        let bodies = [
            "  leading", "trailing\n", "a\r\nb\r\n", "\ttabbed\t",
            "$HOME ${X} $(date) `id` {{name}}", "ťžčô", "😀👩🏽‍💻", "e\u{301}", "\u{E9}",
        ]
        var defs = WritingDefinitions.empty
        for (index, body) in bodies.enumerated() {
            try defs.addSnippet(name: "S\(index)", alias: "s\(index)", summary: "", body: body, restriction: .any)
            try defs.addSkill(name: "K\(index)", alias: "k\(index)", summary: "", instructions: body + "!", operation: .draft)
        }
        let decoded = try WritingDefinitions.decode(try defs.encoded())
        XCTAssertEqual(decoded, defs)
        for (index, body) in bodies.enumerated() {
            XCTAssertEqual(Array(decoded.snippets[index].body.unicodeScalars), Array(body.unicodeScalars), body)
            XCTAssertEqual(Array(decoded.skills[index].instructions.unicodeScalars), Array((body + "!").unicodeScalars))
        }
        XCTAssertEqual(try defs.encoded(), try defs.encoded()) // sortedKeys is deterministic
    }

    func testVersionRejection() throws {
        XCTAssertThrowsError(try WritingDefinitions.decode(Data(#"{"version":2,"snippets":[],"skills":[]}"#.utf8))) {
            XCTAssertEqual($0 as? DefinitionError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try WritingDefinitions.decode(Data(#"{"version":0,"snippets":[],"skills":[]}"#.utf8))) {
            XCTAssertEqual($0 as? DefinitionError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try WritingDefinitions.decode(Data(#"{"version":2,"future":true}"#.utf8))) {
            XCTAssertEqual($0 as? DefinitionError, .unsupportedVersion)
        }
        XCTAssertEqual(try WritingDefinitions.decode(Data(#"{"version":1,"snippets":[],"skills":[]}"#.utf8)), .empty)
        XCTAssertThrowsError(try WritingDefinitions.decode(Data("nope".utf8)))
    }

    func testTerminalClassificationFollowsBody() throws {
        var defs = WritingDefinitions.empty
        XCTAssertEqual(try snippet(&defs, alias: "one", body: "ls -la").terminalClassification, .singleLine)
        XCTAssertEqual(try snippet(&defs, alias: "two", body: "a\nb").terminalClassification, .multiline)
        if case .unsafe = try snippet(&defs, alias: "three", body: "a\tb").terminalClassification {} else { XCTFail("tab is unsafe") }
    }

    func testErrorDescriptionsPresent() {
        let all: [DefinitionError] = [.invalidAlias, .aliasReserved("x"), .aliasTaken("x"), .emptyName, .nameTooLong, .summaryTooLong,
                                      .emptyBody, .bodyTooLarge, .emptyInstructions, .instructionsTooLarge, .notFound, .builtInReadOnly, .unsupportedVersion]
        for error in all { XCTAssertFalse(error.errorDescription?.isEmpty ?? true) }
    }
}
