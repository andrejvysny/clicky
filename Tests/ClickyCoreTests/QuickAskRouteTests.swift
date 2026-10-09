import XCTest
@testable import ClickyCore

final class QuickAskRouteTests: XCTestCase {
    private func definitions() throws -> (WritingDefinitions, SavedSnippet, CustomSkill) {
        var definitions = WritingDefinitions.empty
        let snippet = try definitions.addSnippet(name: "Docker logs", alias: "docker-logs", summary: "",
                                                 body: "docker compose logs --follow --tail 200", restriction: .terminalOnly)
        let skill = try definitions.addSkill(name: "Polite", alias: "polite", summary: "", instructions: "Be polite.", operation: .rewrite)
        return (definitions, snippet, skill)
    }

    private func route(_ draft: String, selection: Bool = false, target: Bool = true) throws -> QuickAskRoute {
        QuickAskRoute.route(draft: draft, definitions: try definitions().0, hasSelection: selection, hasEditableTarget: target)
    }

    func testSlashAndNaturalLanguageWriteNormalizeToTheSameRoute() throws {
        XCTAssertEqual(try route("/write an email asking whether the internship is still available"),
                       .write(instruction: "an email asking whether the internship is still available", skill: nil))
        XCTAssertEqual(try route("Write an email asking whether the internship is still available"),
                       .write(instruction: "Write an email asking whether the internship is still available", skill: nil))
        XCTAssertEqual(try route("Write an email", target: false), .chat("Write an email"), "no editable target keeps chat")
        XCTAssertEqual(try route("/write x", target: false), .write(instruction: "x", skill: nil), "explicit command still drafts a preview")
    }

    func testRewriteRequiresSelection() throws {
        XCTAssertEqual(try route("/rewrite make this shorter and more professional", selection: true),
                       .rewrite(instruction: "make this shorter and more professional", skill: nil))
        guard case .localError = try route("/rewrite shorter") else { return XCTFail("needs selection") }
        XCTAssertEqual(try route("make this shorter", selection: true), .rewrite(instruction: "make this shorter", skill: nil))
        XCTAssertEqual(try route("Rewrite it formally", selection: false), .chat("Rewrite it formally"))
        guard case .rewrite = try route("/fix", selection: true) else { return XCTFail("fix routes to rewrite") }
        guard case .localError = try route("/translate", selection: true) else { return XCTFail("translate needs a language") }
    }

    func testSnippetsSkillsAndLocalErrors() throws {
        let (definitions, snippet, skill) = try definitions()
        XCTAssertEqual(QuickAskRoute.route(draft: "/docker-logs", definitions: definitions, hasSelection: false, hasEditableTarget: true),
                       .snippet(snippet))
        XCTAssertEqual(QuickAskRoute.route(draft: "/polite", definitions: definitions, hasSelection: true, hasEditableTarget: true),
                       .rewrite(instruction: "Apply the skill.", skill: skill))
        guard case .localError(let unknown) = try route("/nope") else { return XCTFail() }
        XCTAssertTrue(unknown.contains("//"))
        guard case .localError = try route("/write") else { return XCTFail("missing argument") }
        XCTAssertEqual(try route("//write literally"), .chat("/write literally"))
        XCTAssertEqual(try route("/usr/local/bin is missing"), .chat("/usr/local/bin is missing"))
        XCTAssertEqual(try route("/explain what is this"), .chat("what is this"))
        var disabled = definitions
        try disabled.setSnippetEnabled(id: snippet.id, enabled: false)
        guard case .localError = QuickAskRoute.route(draft: "/docker-logs", definitions: disabled, hasSelection: false, hasEditableTarget: true)
        else { return XCTFail("disabled snippet") }
    }
}
