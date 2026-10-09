import XCTest
import CoreGraphics
@testable import ClickyCore

final class ScreenPointingTests: XCTestCase {
    func testCaptureSizingCapsLongSideAndPixels() {
        let size = CaptureSizing.pixelSize(forPointSize: CGSize(width: 1440, height: 900), backingScale: 2)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1568)
        XCTAssertLessThanOrEqual(size.width * size.height, 1_150_000)
        XCTAssertEqual(CaptureSizing.pixelSize(forPointSize: CGSize(width: 400, height: 300), backingScale: 2), CGSize(width: 800, height: 600))
        XCTAssertEqual(CaptureSizing.pixelSize(forPointSize: CGSize(width: 400, height: 300), backingScale: 1), CGSize(width: 400, height: 300))
    }

    func testParsePointBoxAndNone() {
        let point = ScreenPointing.parse("Click Save.\n[POINT:120, 45:Save button]")
        XCTAssertEqual(point.text, "Click Save.")
        XCTAssertEqual(point.target, .point(x: 120, y: 45, label: "Save button"))
        XCTAssertEqual(ScreenPointing.parse("Here [BOX:10,20,300,40:Search field]").target, .box(x: 10, y: 20, width: 300, height: 40, label: "Search field"))
        let none = ScreenPointing.parse("Nothing to show.\n\n[POINT:none]")
        XCTAssertNil(none.target)
        XCTAssertEqual(none.text, "Nothing to show.")
    }

    func testParseMultipleMalformedAndPlainText() {
        let multiple = ScreenPointing.parse("A [POINT:1,2:one] B [BOX:3,4,5,6:two] C [POINT:abc]")
        XCTAssertEqual(multiple.target, .box(x: 3, y: 4, width: 5, height: 6, label: "two"))
        XCTAssertFalse(multiple.text.contains("["))
        let bad = ScreenPointing.parse("Text [POINT:abc] end [BOX:1,2,0,5:z]")
        XCTAssertNil(bad.target)
        XCTAssertEqual(bad.text, "Text  end")
        XCTAssertEqual(ScreenPointing.parse("array[0] stays").text, "array[0] stays")
        XCTAssertEqual(ScreenPointing.parse("a\n\n\n\nb [POINT:1,1:x]  \n").text, "a\n\nb")
    }

    func testVisibleStreamingText() {
        XCTAssertEqual(ScreenPointing.visibleStreamingText("Look here [PO"), "Look here")
        XCTAssertEqual(ScreenPointing.visibleStreamingText("Look here [POINT:12,3"), "Look here")
        XCTAssertEqual(ScreenPointing.visibleStreamingText("Look here [BOX:"), "Look here")
        let complete = ScreenPointing.visibleStreamingText("Look [POINT:1,2:x] more")
        XCTAssertFalse(complete.contains("[POINT"))
        XCTAssertEqual(complete, "Look  more")
        XCTAssertEqual(ScreenPointing.visibleStreamingText("array[0"), "array[0")
    }

    func testScreenRectMapsRetinaAndNegativeOrigin() throws {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = try XCTUnwrap(ScreenPointing.screenRect(for: .point(x: 728, y: 455, label: ""), imagePixelSize: CGSize(width: 1456, height: 910), capturedRegion: region))
        XCTAssertEqual(rect.midX, 720, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 450, accuracy: 0.01)
        XCTAssertEqual(rect.width, 44)
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let box = try XCTUnwrap(ScreenPointing.screenRect(for: .box(x: 153, y: 86, width: 307, height: 173, label: ""), imagePixelSize: CGSize(width: 1536, height: 864), capturedRegion: secondary))
        XCTAssertEqual(box.minX, -1920 + 153 * 1.25, accuracy: 0.01)
        XCTAssertEqual(box.minY, -200 + 86 * 1.25, accuracy: 0.01)
        XCTAssertEqual(box.width, 307 * 1.25, accuracy: 0.01)
        XCTAssertEqual(box.height, 173 * 1.25, accuracy: 0.01)
    }

    func testScreenRectToleranceAndMinimumBoxSize() throws {
        let image = CGSize(width: 1000, height: 500), region = CGRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertNil(ScreenPointing.screenRect(for: .point(x: 1050, y: 10, label: ""), imagePixelSize: image, capturedRegion: region))
        let clamped = try XCTUnwrap(ScreenPointing.screenRect(for: .point(x: 1010, y: 10, label: ""), imagePixelSize: image, capturedRegion: region))
        XCTAssertEqual(clamped.midX, 1000, accuracy: 0.01)
        let tiny = try XCTUnwrap(ScreenPointing.screenRect(for: .box(x: 100, y: 100, width: 2, height: 2, label: ""), imagePixelSize: image, capturedRegion: region))
        XCTAssertEqual(tiny.width, 16)
        XCTAssertNil(ScreenPointing.screenRect(for: .point(x: 1, y: 1, label: ""), imagePixelSize: .zero, capturedRegion: region))
    }

    func testScreenInclusionPreference() {
        XCTAssertEqual(ScreenInclusionPreference.allCases.map(\.displayName), ["Off", "Automatic"])
        XCTAssertTrue(ScreenInclusionPreference.always.startsIncluded)
        XCTAssertFalse(ScreenInclusionPreference.off.startsIncluded)
        XCTAssertEqual(ScreenInclusionPreference.stored("askEachTime"), .always)
        XCTAssertEqual(ScreenInclusionPreference.stored("off"), .off)
        XCTAssertNil(ScreenInclusionPreference.stored(nil))
        XCTAssertFalse(ScreenInclusionPreference.off.isAvailable)
    }
}

final class GuidePixelMappingTests: XCTestCase {
    private let region = CGRect(x: 100, y: 50, width: 800, height: 400)

    func testEdgeOvershootIsClampedNotRejected() throws {
        // A close button 6 px past the right edge of a 1600x800 capture (2% slack is 32 px).
        let rect = try XCTUnwrap(GuidePixelMapping.screenRect(GuideRect(CGRect(x: 1570, y: 10, width: 36, height: 20)),
                                                            pixelWidth: 1600, pixelHeight: 800, region: region))
        XCTAssertEqual(rect.maxX, region.maxX, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 100 + 1570 / 2, accuracy: 0.001)
    }

    func testTargetsOutsideSlackAreRejected() {
        XCTAssertNil(GuidePixelMapping.screenRect(GuideRect(CGRect(x: -40, y: 10, width: 20, height: 20)),
                                                  pixelWidth: 1600, pixelHeight: 800, region: region))
        XCTAssertNil(GuidePixelMapping.screenRect(GuideRect(CGRect(x: 10, y: 790, width: 20, height: 40)),
                                                  pixelWidth: 1600, pixelHeight: 800, region: region))
    }

    func testRetinaPixelsMapToPoints() throws {
        let rect = try XCTUnwrap(GuidePixelMapping.screenRect(GuideRect(CGRect(x: 200, y: 100, width: 40, height: 20)),
                                                            pixelWidth: 1600, pixelHeight: 800, region: region))
        XCTAssertEqual(rect, CGRect(x: 200, y: 100, width: 20, height: 10))
    }
}

final class DisplayTargetTests: XCTestCase {
    func testDisplayTargetRoundTripsItsIdentifier() {
        XCTAssertEqual(WindowCaptureTarget.display(69_734_208).displayIdentifier, 69_734_208)
        XCTAssertNil(WindowCaptureTarget(processIdentifier: 42, windowIdentifier: 7, applicationIdentifier: "display:1",
                                         applicationName: "Spoof").displayIdentifier, "a real window is never a display")
    }
}
