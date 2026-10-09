import XCTest
@testable import ClickyCore

final class SlashCommandTests: XCTestCase {
    // MARK: Parser

    func testParserCommands() {
        XCTAssertEqual(SlashParser.parse("/write hello"), .command(alias: "write", argument: "hello"))
        XCTAssertEqual(SlashParser.parse("/write\nmulti\nline"), .command(alias: "write", argument: "multi\nline"))
        XCTAssertEqual(SlashParser.parse("/write  two  spaces "), .command(alias: "write", argument: " two  spaces "))
        XCTAssertEqual(SlashParser.parse("/write\r\nx"), .command(alias: "write", argument: "x"))
        XCTAssertEqual(SlashParser.parse("/fix"), .command(alias: "fix", argument: ""))
        XCTAssertEqual(SlashParser.parse("/fix "), .command(alias: "fix", argument: ""))
        XCTAssertEqual(SlashParser.parse("/tmp is full"), .command(alias: "tmp", argument: "is full"))
        XCTAssertEqual(SlashParser.parse("/9-lives\ttab"), .command(alias: "9-lives", argument: "tab"))
    }

    func testParserLiteralEscape() {
        XCTAssertEqual(SlashParser.parse("//literal"), .literal("/literal"))
        XCTAssertEqual(SlashParser.parse("//"), .literal("/"))
        XCTAssertEqual(SlashParser.parse("///x"), .literal("//x"))
    }

    func testParserPlainText() {
        for draft in ["/usr/bin/env", "/Users/me", "/a.txt", "/Write x", " /write", "https://x", "", "/", "/x:y", "/ write", "/\u{301}x", "hello /write"] {
            XCTAssertEqual(SlashParser.parse(draft), .text(draft), draft)
        }
        XCTAssertEqual(SlashParser.parse("/" + String(repeating: "a", count: 33)), .text("/" + String(repeating: "a", count: 33)))
    }

    // MARK: Registry

    private func definitions() throws -> WritingDefinitions {
        var defs = WritingDefinitions.empty
        try defs.addSnippet(name: "Email signature", alias: "sig", summary: "", body: "Best,\nAndrej\nmore", restriction: .any)
        try defs.addSnippet(name: "Café address", alias: "addr", summary: "Where we meet", body: "1 Main St", restriction: .any)
        try defs.addSkill(name: "Formal", alias: "formal", summary: "Make it formal", instructions: "Be formal.", operation: .rewrite)
        try defs.addSkill(name: "Joke", alias: "joke", summary: "Draft a joke", instructions: "Be funny.", operation: .draft)
        return defs
    }

    func testEntryOrderAndFields() throws {
        let registry = SlashCommandRegistry(definitions: try definitions(), hasSelection: true)
        XCTAssertEqual(registry.entries.map(\.alias),
                       ["write", "rewrite", "fix", "shorten", "translate", "explain", "guide",
                        "professional", "reply", "formal", "joke", "sig", "addr"])
        let write = registry.entries[0]
        XCTAssertEqual([write.title, write.summary, write.argumentHint], ["Write", "Draft new text at the caret", "what to write"])
        XCTAssertTrue(write.requiresArgument && !write.requiresSelection)
        let fix = registry.entries[2]
        XCTAssertNil(fix.argumentHint)
        XCTAssertTrue(fix.requiresSelection && !fix.requiresArgument)
        let sig = registry.entries.last { $0.alias == "sig" }!
        XCTAssertEqual(sig.summary, "Best,") // first line
        XCTAssertNil(sig.argumentHint)
        XCTAssertEqual(registry.entries.last { $0.alias == "addr" }!.summary, "Where we meet")
        let formal = registry.entries.first { $0.alias == "formal" }!
        XCTAssertEqual(formal.argumentHint, "optional details")
        XCTAssertTrue(formal.requiresSelection)
        XCTAssertFalse(registry.entries.first { $0.alias == "joke" }!.requiresSelection)
    }

    func testSnippetSummaryTruncatedTo60() throws {
        var defs = WritingDefinitions.empty
        try defs.addSnippet(name: "Long", alias: "long", summary: "", body: String(repeating: "x", count: 100), restriction: .any)
        let registry = SlashCommandRegistry(definitions: defs, hasSelection: false)
        XCTAssertEqual(registry.entries.last!.summary.count, 60)
    }

    func testBadges() throws {
        let registry = SlashCommandRegistry(definitions: try definitions(), hasSelection: true)
        XCTAssertEqual(registry.entries.first { $0.alias == "write" }!.badge, "Action")
        XCTAssertEqual(registry.entries.first { $0.alias == "reply" }!.badge, "AI skill")
        XCTAssertEqual(registry.entries.first { $0.alias == "sig" }!.badge, "Snippet · No AI")
    }

    func testBuiltInSkillsAndReserved() {
        let skills = SlashCommandRegistry.builtInSkills
        XCTAssertEqual(skills.map(\.alias), ["professional", "reply"])
        XCTAssertTrue(skills.allSatisfy { $0.builtIn && $0.revision == 1 })
        XCTAssertEqual(skills.map(\.operation), [.rewrite, .draft])
        XCTAssertEqual(Set(skills.map(\.id)).count, 2)
        for alias in SlashAction.allCases.map(\.rawValue) + ["skills", "snippets", "settings", "help", "clicky", "professional", "reply"] {
            XCTAssertTrue(SlashCommandRegistry.reservedAliases.contains(alias), alias)
        }
    }

    func testAvailabilityWithoutSelection() throws {
        let registry = SlashCommandRegistry(definitions: try definitions(), hasSelection: false)
        func command(_ alias: String) -> SlashCommand { registry.entries.first { $0.alias == alias }! }
        for alias in ["rewrite", "fix", "shorten", "translate", "professional", "formal"] {
            XCTAssertFalse(command(alias).available, alias)
            XCTAssertEqual(command(alias).unavailableReason, "Select text before opening Quick Ask")
        }
        for alias in ["write", "explain", "guide", "reply", "joke", "sig", "addr"] {
            XCTAssertTrue(command(alias).available, alias)
            XCTAssertNil(command(alias).unavailableReason)
        }
        let withSelection = SlashCommandRegistry(definitions: try definitions(), hasSelection: true)
        XCTAssertTrue(withSelection.entries.allSatisfy(\.available))
    }

    func testSuggestionsRanking() throws {
        var defs = WritingDefinitions.empty
        try defs.addSnippet(name: "Alpha", alias: "wr", summary: "", body: "b", restriction: .any)
        try defs.addSnippet(name: "Beta", alias: "awrite", summary: "", body: "b", restriction: .any)
        try defs.addSkill(name: "Gamma", alias: "writer", summary: "", instructions: "i", operation: .draft)
        try defs.addSnippet(name: "Delta", alias: "zzz", summary: "Rewrite helper text", body: "b", restriction: .any)
        let registry = SlashCommandRegistry(definitions: defs, hasSelection: true)
        // exact < prefix < contains (action before snippet) < title/summary (skill before snippet)
        let aliases = registry.suggestions(for: "wr", limit: 20).map(\.alias)
        XCTAssertEqual(Array(aliases.prefix(6)), ["wr", "write", "writer", "rewrite", "awrite", "professional"])
    }

    func testSuggestionsKindOrderThenAlias() throws {
        var defs = WritingDefinitions.empty
        try defs.addSnippet(name: "N", alias: "fx-b", summary: "", body: "b", restriction: .any)
        try defs.addSnippet(name: "N", alias: "fx-a", summary: "", body: "b", restriction: .any)
        try defs.addSkill(name: "N", alias: "fx-s", summary: "", instructions: "i", operation: .draft)
        let registry = SlashCommandRegistry(definitions: defs, hasSelection: true)
        XCTAssertEqual(Array(registry.suggestions(for: "f").map(\.alias).prefix(4)), ["fix", "fx-s", "fx-a", "fx-b"])
        XCTAssertEqual(registry.suggestions(for: "fx").map(\.alias), ["fx-s", "fx-a", "fx-b"])
    }

    func testSuggestionsEmptyQueryAndLimit() throws {
        let registry = SlashCommandRegistry(definitions: try definitions(), hasSelection: true)
        XCTAssertEqual(registry.suggestions(for: "").map(\.alias), Array(registry.entries.map(\.alias).prefix(8)))
        XCTAssertEqual(registry.suggestions(for: "", limit: 3).count, 3)
        XCTAssertEqual(registry.suggestions(for: "", limit: 100).count, registry.entries.count)
        XCTAssertTrue(registry.suggestions(for: "zzzzqq").isEmpty)
    }

    func testSuggestionsCaseAndDiacriticInsensitive() throws {
        let registry = SlashCommandRegistry(definitions: try definitions(), hasSelection: true)
        XCTAssertEqual(registry.suggestions(for: "cafe").map(\.alias), ["addr"])
        XCTAssertEqual(registry.suggestions(for: "CAFÉ").map(\.alias), ["addr"])
        XCTAssertEqual(registry.suggestions(for: "SIG").first?.alias, "sig")
    }

    func testDisabledExcludedAndLookup() throws {
        var defs = try definitions()
        let sig = defs.snippets.first { $0.alias == "sig" }!
        let formal = defs.skills.first { $0.alias == "formal" }!
        try defs.setSnippetEnabled(id: sig.id, enabled: false)
        try defs.setSkillEnabled(id: formal.id, enabled: false)
        let registry = SlashCommandRegistry(definitions: defs, hasSelection: true)
        XCTAssertFalse(registry.entries.contains { $0.alias == "sig" || $0.alias == "formal" })
        XCTAssertTrue(registry.suggestions(for: "sig").isEmpty)
        XCTAssertEqual(registry.lookup("sig"), .disabled("Email signature"))
        XCTAssertEqual(registry.lookup("formal"), .disabled("Formal"))
        XCTAssertEqual(registry.lookup("nothing"), .unknown)
        guard case .command(let write) = registry.lookup("write") else { return XCTFail("write should resolve") }
        XCTAssertEqual(write.action, .write)
        guard case .command(let addr) = registry.lookup("addr") else { return XCTFail("addr should resolve") }
        XCTAssertEqual(addr.snippetID, defs.snippets.first { $0.alias == "addr" }!.id)
        XCTAssertEqual(addr.snippetRevision, 1)
        guard case .command(let joke) = registry.lookup("joke") else { return XCTFail("joke should resolve") }
        XCTAssertEqual(joke.skillRevision, 1)
        // the revision recorded reflects the bump from disabling then re-enabling
        try defs.setSnippetEnabled(id: sig.id, enabled: true)
        guard case .command(let again) = SlashCommandRegistry(definitions: defs, hasSelection: true).lookup("sig") else { return XCTFail() }
        XCTAssertEqual(again.snippetRevision, 3)
    }

    // MARK: Picker

    private func sample() -> [SlashCommand] {
        let registry = SlashCommandRegistry(definitions: .empty, hasSelection: true)
        return Array(registry.suggestions(for: "", limit: 3)) // write, rewrite, fix
    }

    func testPickerQueryRules() {
        XCTAssertEqual(SlashPickerState.query(draft: "/", caretUTF16: 1, hasMarkedText: false), "")
        XCTAssertEqual(SlashPickerState.query(draft: "/wr-1", caretUTF16: 5, hasMarkedText: false), "wr-1")
        XCTAssertNil(SlashPickerState.query(draft: "/wr", caretUTF16: 3, hasMarkedText: true))
        XCTAssertNil(SlashPickerState.query(draft: "/wr", caretUTF16: 2, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "/wr ", caretUTF16: 4, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "//", caretUTF16: 2, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "//x", caretUTF16: 3, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "x/wr", caretUTF16: 4, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "/Wr", caretUTF16: 3, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "/a.b", caretUTF16: 4, hasMarkedText: false))
        XCTAssertNil(SlashPickerState.query(draft: "", caretUTF16: 0, hasMarkedText: false))
    }

    func testVisibility() {
        var state = SlashPickerState()
        XCTAssertFalse(state.isVisible(query: nil, count: 3))
        XCTAssertFalse(state.isVisible(query: "w", count: 0))
        XCTAssertTrue(state.isVisible(query: "w", count: 1))
        state.update(query: "w", count: 3)
        XCTAssertTrue(state.isVisible(query: "w", count: 3))
    }

    func testTabCompletesWithoutSubmitting() {
        var state = SlashPickerState()
        state.update(query: "w", count: 3)
        XCTAssertEqual(state.handle(.tab, query: "w", suggestions: sample()), .complete(draft: "/write "))
        XCTAssertEqual(state.handle(.tab, query: "write", suggestions: sample()), .complete(draft: "/write "))
    }

    func testEnterCompletesPartialAndSubmitsExact() {
        var state = SlashPickerState()
        state.update(query: "wr", count: 3)
        XCTAssertEqual(state.handle(.enter, query: "wr", suggestions: sample()), .complete(draft: "/write "))
        state.update(query: "write", count: 3)
        XCTAssertEqual(state.handle(.enter, query: "write", suggestions: sample()), .submit)
        state.update(query: "write", count: 3)
        _ = state.handle(.down, query: "write", suggestions: sample())
        XCTAssertEqual(state.handle(.enter, query: "write", suggestions: sample()), .complete(draft: "/rewrite "))
    }

    func testUnavailableCommandStillCompletes() throws {
        let registry = SlashCommandRegistry(definitions: .empty, hasSelection: false)
        let list = registry.suggestions(for: "fix")
        XCTAssertFalse(list[0].available)
        var state = SlashPickerState()
        state.update(query: "fi", count: list.count)
        XCTAssertEqual(state.handle(.tab, query: "fi", suggestions: list), .complete(draft: "/fix "))
    }

    func testEscapeDismissesUntilQueryChanges() {
        var state = SlashPickerState()
        state.update(query: "w", count: 3)
        XCTAssertEqual(state.handle(.escape, query: "w", suggestions: sample()), .dismiss)
        XCTAssertFalse(state.isVisible(query: "w", count: 3))
        state.update(query: "w", count: 3)
        XCTAssertFalse(state.isVisible(query: "w", count: 3))
        XCTAssertEqual(state.handle(.enter, query: "w", suggestions: sample()), .passThrough)
        XCTAssertEqual(state.handle(.escape, query: "w", suggestions: sample()), .passThrough)
        state.update(query: "wr", count: 3)
        XCTAssertTrue(state.isVisible(query: "wr", count: 3))
        // leaving and returning to the dismissed query shows it again
        _ = state.handle(.escape, query: "wr", suggestions: sample())
        state.update(query: nil, count: 0)
        state.update(query: "wr", count: 3)
        XCTAssertTrue(state.isVisible(query: "wr", count: 3))
    }

    func testUpDownWrapAround() {
        var state = SlashPickerState()
        state.update(query: "", count: 3)
        XCTAssertEqual(state.highlighted, 0)
        XCTAssertEqual(state.handle(.up, query: "", suggestions: sample()), .moveHighlight)
        XCTAssertEqual(state.highlighted, 2)
        XCTAssertEqual(state.handle(.down, query: "", suggestions: sample()), .moveHighlight)
        XCTAssertEqual(state.highlighted, 0)
        _ = state.handle(.down, query: "", suggestions: sample())
        XCTAssertEqual(state.highlighted, 1)
        XCTAssertEqual(state.handle(.tab, query: "", suggestions: sample()), .complete(draft: "/rewrite "))
    }

    func testHighlightResetsOnQueryChangeAndClamps() {
        var state = SlashPickerState()
        state.update(query: "", count: 5)
        _ = state.handle(.down, query: "", suggestions: Array(sample()))
        XCTAssertEqual(state.highlighted, 1)
        state.update(query: "", count: 5)
        XCTAssertEqual(state.highlighted, 1) // same query keeps position
        state.update(query: "r", count: 5)
        XCTAssertEqual(state.highlighted, 0)
        _ = state.handle(.up, query: "r", suggestions: sample())
        state.update(query: "r", count: 2) // shrinking list clamps
        XCTAssertEqual(state.highlighted, 1)
        state.update(query: "r", count: 0)
        XCTAssertEqual(state.highlighted, 0)
    }

    func testPassThroughWhenHidden() {
        var state = SlashPickerState()
        for key in [SlashPickerState.PickerKey.up, .down, .tab, .enter, .escape] {
            XCTAssertEqual(state.handle(key, query: nil, suggestions: sample()), .passThrough)
            XCTAssertEqual(state.handle(key, query: "w", suggestions: []), .passThrough)
        }
        XCTAssertEqual(state, SlashPickerState())
    }
}
