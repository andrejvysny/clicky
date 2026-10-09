import XCTest
@testable import ClickyCore

final class GuidePixelsTests: XCTestCase {
    private func image(width: Int = 48, height: Int = 24, value: UInt8 = 255) -> [UInt8] {
        [UInt8](repeating: value, count: width * height * 4)
    }
    private func pixels(_ bytes: [UInt8], width: Int = 48, height: Int = 24) -> GuidePixels {
        GuidePixels(width: width, height: height, rgba: Data(bytes))!
    }
    private func paint(_ bytes: inout [UInt8], x: Range<Int>, y: Range<Int>, value: UInt8, width: Int = 48) {
        for row in y { for column in x { for channel in 0..<3 { bytes[(row * width + column) * 4 + channel] = value } } }
    }

    func testIdenticalAndScatteredNoiseLookAlike() {
        var noisy = image()
        paint(&noisy, x: 3..<4, y: 2..<3, value: 0)      // one antialiased pixel
        paint(&noisy, x: 30..<31, y: 15..<17, value: 0)  // a caret blink
        XCTAssertTrue(pixels(image()).looksLike(pixels(image())))
        XCTAssertTrue(pixels(image()).looksLike(pixels(noisy)))
    }

    func testSmallDecisiveChangeIsNotDilutedByALargeRectangle() {
        let width = 600, height = 300
        var checked = image(width: width, height: height)
        paint(&checked, x: 100..<106, y: 100..<106, value: 0, width: width) // a 36-pixel checkmark
        XCTAssertFalse(pixels(image(width: width, height: height), width: width, height: height)
            .looksLike(pixels(checked, width: width, height: height)))
    }

    func testSubtleShiftLooksAlikeButAReplacedControlDoesNot() {
        XCTAssertTrue(pixels(image(value: 255)).looksLike(pixels(image(value: 240))))
        var replaced = image()
        paint(&replaced, x: 0..<48, y: 0..<24, value: 120)
        XCTAssertFalse(pixels(image()).looksLike(pixels(replaced)))
    }

    func testDifferentSizesNeverLookAlike() {
        XCTAssertFalse(pixels(image()).looksLike(pixels(image(width: 24, height: 24), width: 24, height: 24)))
        XCTAssertNil(GuidePixels(width: 2, height: 2, rgba: Data(count: 3)))
    }
}
