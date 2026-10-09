import AppKit
import XCTest
@testable import ClickyGuideNative

/// `WritingClipboard` against a private named pasteboard: ownership checks and unknown-delivery lifecycle.
@MainActor
final class WritingClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("clicky.tests." + UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("user clipboard", forType: .string)
    }

    override func tearDown() async throws { pasteboard.releaseGlobally() }

    func testStagingIsRefusedWhenAnotherAppChangedTheClipboardAfterTheSnapshot() throws {
        let clipboard = WritingClipboard(pasteboard: pasteboard)
        let snapshot = try XCTUnwrap(clipboard.snapshot())
        pasteboard.clearContents(); pasteboard.setString("newer copy", forType: .string)
        XCTAssertNil(clipboard.stage("insert", preserving: snapshot))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer copy")
    }

    func testConfirmedPasteRestoresTheUserClipboard() throws {
        let clipboard = WritingClipboard(pasteboard: pasteboard)
        let staged = try XCTUnwrap(clipboard.stage("insert", preserving: XCTUnwrap(clipboard.snapshot())))
        XCTAssertEqual(pasteboard.string(forType: .string), "insert")
        XCTAssertTrue(clipboard.restore(staged))
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
    }

    func testUnknownDeliveryKeepsStagedTextAndTheNextPasteRestoresTheOriginal() throws {
        let clipboard = WritingClipboard(pasteboard: pasteboard)
        let first = try XCTUnwrap(clipboard.stage("first", preserving: XCTUnwrap(clipboard.snapshot())))
        clipboard.leaveUnsettled(first)
        XCTAssertEqual(pasteboard.string(forType: .string), "first", "a late paste still inserts the intended text")
        // A second insertion before the first settles carries the user's original clipboard forward.
        let second = try XCTUnwrap(clipboard.stage("second", preserving: XCTUnwrap(clipboard.snapshot())))
        XCTAssertTrue(clipboard.restore(second))
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        XCTAssertNil(clipboard.unsettled)
    }

    func testUnsettledTextIsForgottenOnceTheUserCopiesSomethingElse() throws {
        let clipboard = WritingClipboard(pasteboard: pasteboard)
        let staged = try XCTUnwrap(clipboard.stage("first", preserving: XCTUnwrap(clipboard.snapshot())))
        clipboard.leaveUnsettled(staged)
        pasteboard.clearContents(); pasteboard.setString("user copied later", forType: .string)
        let next = try XCTUnwrap(clipboard.stage("second", preserving: XCTUnwrap(clipboard.snapshot())))
        XCTAssertTrue(clipboard.restore(next))
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied later")
    }
}
