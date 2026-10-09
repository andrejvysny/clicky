import XCTest
@testable import ClickyCore

final class GuideDisplayConsentTests: XCTestCase {
    func testFirstRequestPromptsThenSameScopeIsReusedForTheSession() {
        var consent = GuideDisplayConsent()
        XCTAssertEqual(consent.decision(display: 1, provider: .claude, request: 1, preferenceAllows: true), .needsPrompt)
        consent.approve(display: 1, provider: .claude)
        XCTAssertEqual(consent.decision(display: 1, provider: .claude, request: 2, preferenceAllows: true), .granted)
    }

    func testNewDisplayOrProviderNeedsItsOwnApproval() {
        var consent = GuideDisplayConsent()
        consent.approve(display: 1, provider: .claude)
        XCTAssertEqual(consent.decision(display: 2, provider: .claude, request: 1, preferenceAllows: true), .needsPrompt)
        XCTAssertEqual(consent.decision(display: 1, provider: .codex, request: 1, preferenceAllows: true), .needsPrompt)
    }

    func testTextOnlyDeclinesOnlyThatRequestAndRevokeClears() {
        var consent = GuideDisplayConsent()
        consent.decline(request: 7)
        XCTAssertEqual(consent.decision(display: 1, provider: .claude, request: 7, preferenceAllows: true), .declined)
        XCTAssertEqual(consent.decision(display: 1, provider: .claude, request: 8, preferenceAllows: true), .needsPrompt)
        consent.approve(display: 1, provider: .claude); consent.revoke()
        XCTAssertNil(consent.grant)
        XCTAssertEqual(consent.decision(display: 1, provider: .claude, request: 9, preferenceAllows: false), .disallowed)
    }

    func testLegacyPersistedApprovalBecomesOnlyAPreference() throws {
        let name = "GuideDisplayConsentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "displaySharingApproved")
        GuideDisplayConsent.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: "displaySharingApproved"))
        XCTAssertTrue(defaults.bool(forKey: GuideDisplayConsent.preferenceKey))
        // A fresh process starts with no live grant regardless of the stored preference.
        XCTAssertNil(GuideDisplayConsent().grant)
    }
}
