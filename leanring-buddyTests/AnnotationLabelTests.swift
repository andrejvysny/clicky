import AppKit
import Testing
@testable import Clicky

@MainActor
struct AnnotationLabelTests {
    @Test func twoDigitValueIncludesCellInsets() throws {
        let pill = AnnotationLabelViews.pill(text: "12", color: .systemBlue)
        let field = try #require(pill.subviews.first as? NSTextField)
        let required = field.sizeThatFits(NSSize(width: 240, height: 100))
        #expect(field.frame.width >= required.width)
        #expect(field.frame.height >= required.height)
        #expect(pill.frame.width == field.frame.width + 20)
        #expect(pill.frame.height == field.frame.height + 8)
    }

    @Test func shortUnicodeValueFitsWithoutTruncation() throws {
        let pill = AnnotationLabelViews.pill(text: "12 µm", color: .systemBlue)
        let field = try #require(pill.subviews.first as? NSTextField)
        #expect(field.frame.width >= field.sizeThatFits(NSSize(width: 240, height: 100)).width)
        #expect(field.stringValue == "12 µm")
    }

    @Test func longValueRemainsBounded() throws {
        let text = String(repeating: "1234567890", count: 1000)
        let pill = AnnotationLabelViews.pill(text: text, color: .systemBlue)
        let field = try #require(pill.subviews.first as? NSTextField)
        #expect(pill.frame.width <= AnnotationLabelViews.maxLabelWidth)
        #expect(pill.frame.width.isFinite && pill.frame.height.isFinite)
        #expect(field.maximumNumberOfLines == 1)
        #expect(field.lineBreakMode == .byTruncatingMiddle)
        #expect(field.stringValue == text)
    }
}
