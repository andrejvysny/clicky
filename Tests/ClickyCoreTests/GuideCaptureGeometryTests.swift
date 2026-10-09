import XCTest
@testable import ClickyCore

final class GuideCaptureGeometryTests: XCTestCase {
    func testEdgeSlackClipsBeforeIntegralComparison() {
        let target = GuideRect(CGRect(x: -2, y: -1, width: 18.2, height: 19.1))
        XCTAssertEqual(GuidePixelMapping.comparisonRect(target, pixelWidth: 100, pixelHeight: 100),
                       CGRect(x: 0, y: 0, width: 17, height: 19))
    }

    func testFractionalTargetKeepsOriginalPixelGrid() {
        let target = GuideRect(CGRect(x: 17.7, y: 29.2, width: 80.6, height: 21.4))
        XCTAssertEqual(GuidePixelMapping.comparisonRect(target, pixelWidth: 400, pixelHeight: 300),
                       CGRect(x: 17, y: 29, width: 82, height: 22))
    }

    func testBottomRightSlackCannotChangeExpectedCaptureDimensions() {
        let target = GuideRect(CGRect(x: 90.5, y: 92.1, width: 11, height: 9.5))
        XCTAssertEqual(GuidePixelMapping.comparisonRect(target, pixelWidth: 100, pixelHeight: 100),
                       CGRect(x: 90, y: 92, width: 10, height: 8))
    }

    func testInvalidOrOutsideTargetHasNoComparisonRegion() {
        for target in [GuideRect(CGRect(x: -3, y: 0, width: 10, height: 10)),
                       GuideRect(CGRect(x: 100.1, y: 0, width: 1, height: 10)),
                       GuideRect(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10))] {
            XCTAssertNil(GuidePixelMapping.comparisonRect(target, pixelWidth: 100, pixelHeight: 100))
        }
        XCTAssertNil(GuidePixelMapping.comparisonRect(GuideRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
                                                     pixelWidth: 0, pixelHeight: 100))
    }

    func testEvidenceUsesIntegralPixelsOfWhollyContainedFractionalRegion() {
        let evidence = GuideRect(CGRect(x: 17.7, y: 29.2, width: 80.6, height: 21.4))
        XCTAssertEqual(GuidePixelMapping.evidenceComparisonRect(evidence, pixelWidth: 400, pixelHeight: 300),
                       CGRect(x: 17, y: 29, width: 82, height: 22))
    }

    func testEvidenceMayTouchImageEdgesWithoutExpandingCapture() {
        let fullImage = GuideRect(CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(GuidePixelMapping.evidenceComparisonRect(fullImage, pixelWidth: 100, pixelHeight: 80), fullImage.rect)
        let corner = GuideRect(CGRect(x: 99.25, y: 78.75, width: 0.75, height: 1.25))
        XCTAssertEqual(GuidePixelMapping.evidenceComparisonRect(corner, pixelWidth: 100, pixelHeight: 80),
                       CGRect(x: 99, y: 78, width: 1, height: 2))
    }

    func testEvidenceRejectsOvershootThatPointingWouldClip() {
        let overshoots = [CGRect(x: -0.1, y: 10, width: 20, height: 20),
                          CGRect(x: 10, y: -0.1, width: 20, height: 20),
                          CGRect(x: 90, y: 10, width: 10.1, height: 20),
                          CGRect(x: 10, y: 90, width: 20, height: 10.1)]
        for rect in overshoots {
            let evidence = GuideRect(rect)
            XCTAssertNotNil(GuidePixelMapping.comparisonRect(evidence, pixelWidth: 100, pixelHeight: 100))
            XCTAssertNil(GuidePixelMapping.evidenceComparisonRect(evidence, pixelWidth: 100, pixelHeight: 100))
        }
    }

    func testInvalidEvidenceAndInvalidImageDimensionsHaveNoRegion() throws {
        for rect in [CGRect(x: 1, y: 1, width: 0, height: 20),
                     CGRect(x: 1, y: 1, width: 20, height: 0),
                     CGRect(x: CGFloat.nan, y: 1, width: 20, height: 20),
                     CGRect(x: 1, y: 1, width: CGFloat.infinity, height: 20),
                     CGRect(x: 101, y: 1, width: 20, height: 20)] {
            XCTAssertNil(GuidePixelMapping.evidenceComparisonRect(GuideRect(rect), pixelWidth: 100, pixelHeight: 100))
        }
        let negative = try JSONDecoder().decode(GuideRect.self, from: Data(#"{"x":1,"y":1,"width":-1,"height":20}"#.utf8))
        XCTAssertNil(GuidePixelMapping.evidenceComparisonRect(negative, pixelWidth: 100, pixelHeight: 100))
        let valid = GuideRect(CGRect(x: 1, y: 1, width: 20, height: 20))
        for dimensions in [(0, 100), (100, 0), (-1, 100), (100, -1)] {
            XCTAssertNil(GuidePixelMapping.evidenceComparisonRect(valid, pixelWidth: dimensions.0, pixelHeight: dimensions.1))
        }
    }

    func testSubpixelEvidenceStillComparesOneOriginalPixel() {
        let evidence = GuideRect(CGRect(x: 40.25, y: 30.25, width: 0.1, height: 0.1))
        XCTAssertEqual(GuidePixelMapping.evidenceComparisonRect(evidence, pixelWidth: 100, pixelHeight: 100),
                       CGRect(x: 40, y: 30, width: 1, height: 1))
    }
}
