import XCTest
@testable import ClickyCore

final class GuidanceDebugRequestTests: XCTestCase {
    private func parse(_ string: String) throws -> GuidanceDebugRequest { try GuidanceDebugRequest.parse(URL(string: string)!) }
    private let base = "clicky-debug://guide?x=10&y=20&w=100&h=40&text=Click%20here"

    func testValidClick() throws {
        XCTAssertEqual(try parse(base + "&expect=click"),
                       .show(target: CGRect(x: 10, y: 20, width: 100, height: 40), instruction: "Click here", expected: .click(button: 0)))
        XCTAssertEqual(try parse(base + "&expect=rightclick"),
                       .show(target: CGRect(x: 10, y: 20, width: 100, height: 40), instruction: "Click here", expected: .click(button: 1)))
    }

    func testValidKeyWithModifiers() throws {
        XCTAssertEqual(try parse(base + "&expect=key&key=k&mods=cmd,shift"),
                       .show(target: CGRect(x: 10, y: 20, width: 100, height: 40), instruction: "Click here", expected: .key(code: 40, modifiers: 1179648)))
    }

    func testCancel() throws { XCTAssertEqual(try parse("clicky-debug://cancel"), .cancel) }

    func testRejectsInvalidRequests() {
        let bad = [
            "https://guide?x=1&y=1&w=10&h=10&text=a&expect=click",
            "clicky-debug://guide?x=10&y=20&w=100&h=40&expect=click",
            "clicky-debug://guide?x=10&y=20&w=100&h=40&text=\(String(repeating: "a", count: 201))&expect=click",
            "clicky-debug://guide?x=10&y=20&w=0&h=40&text=a&expect=click",
            "clicky-debug://guide?x=NaN&y=20&w=100&h=40&text=a&expect=click",
            "clicky-debug://guide?x=abc&y=20&w=100&h=40&text=a&expect=click",
            base + "&expect=key&key=nope",
            base + "&expect=key&key=k&mods=hyper",
            base + "&expect=hover",
            "clicky-debug://other",
        ]
        for string in bad {
            XCTAssertThrowsError(try parse(string), string) { XCTAssertTrue($0 is AskError) }
        }
    }
}
