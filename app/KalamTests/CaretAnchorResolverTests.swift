import XCTest
import CoreGraphics
@testable import Kalam_test

final class CaretAnchorResolverTests: XCTestCase {

    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let chip = CGSize(width: 64, height: 21)

    // MARK: validity gate

    func testNilRectIsInvalid() {
        XCTAssertFalse(CaretAnchorResolver.isValidCaretRect(nil))
    }

    func testZeroWidthRectIsInvalid() {
        XCTAssertFalse(CaretAnchorResolver.isValidCaretRect(CGRect(x: 10, y: 10, width: 0, height: 15)))
    }

    func testNonFiniteRectIsInvalid() {
        // Note: CGRect(x:y:width:height:) normalizes negative sizes to positive,
        // so a "negative height" case cannot be constructed; NaN coordinates
        // exercise the finite gate instead.
        XCTAssertFalse(CaretAnchorResolver.isValidCaretRect(
            CGRect(x: CGFloat.nan, y: 10, width: 2, height: 15)))
    }

    func testFiniteNonEmptyRectIsValid() {
        XCTAssertTrue(CaretAnchorResolver.isValidCaretRect(CGRect(x: 10, y: 10, width: 1.5, height: 15)))
    }

    // MARK: trailing placement

    func testChipTrailsToTheRightOfTheCaret() {
        let caret = CGRect(x: 200, y: 400, width: 1.5, height: 15)
        let anchor = CaretAnchorResolver.chipOrigin(caretRect: caret, screenFrame: screen, chipSize: chip)
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.flippedBelow, false)
        // x = maxX + gap (6pt), per the owner's trails-the-caret ruling.
        XCTAssertEqual(anchor?.x, caret.maxX + CaretAnchorResolver.trailingGap)
    }

    func testChipIsVerticallyCenteredOnTheCaretLine() {
        let caret = CGRect(x: 200, y: 400, width: 1.5, height: 15)
        let anchor = CaretAnchorResolver.chipOrigin(caretRect: caret, screenFrame: screen, chipSize: chip)
        XCTAssertEqual(anchor?.y, caret.midY - chip.height / 2)
    }

    // MARK: right-edge flip

    func testFlipBelowWhenCaretNearRightEdge() {
        // Caret ends 4pt from the right edge: no room to trail a 64pt chip.
        let caretX = screen.maxX - 4
        let caret = CGRect(x: caretX - 1.5, y: 400, width: 1.5, height: 15)
        let anchor = CaretAnchorResolver.chipOrigin(caretRect: caret, screenFrame: screen, chipSize: chip)
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.flippedBelow, true)
        // Flipped chip is right-aligned to the caret end minus margin.
        XCTAssertEqual(anchor?.x, min(caret.maxX, screen.maxX - CaretAnchorResolver.edgeMargin) - chip.width)
        XCTAssertEqual(anchor?.y, caret.minY - CaretAnchorResolver.belowGap - chip.height)
    }

    func testExactlyFittingChipDoesNotFlip() {
        // Chip ends exactly at the edge margin boundary: still trails.
        let caretX = screen.maxX - CaretAnchorResolver.edgeMargin - chip.width
        let caret = CGRect(x: caretX - CaretAnchorResolver.trailingGap - 1.5, y: 300, width: 1.5, height: 15)
        let originX = caret.maxX + CaretAnchorResolver.trailingGap
        let anchor = CaretAnchorResolver.chipOrigin(caretRect: caret, screenFrame: screen, chipSize: chip)
        XCTAssertEqual(anchor?.flippedBelow, false)
        XCTAssertEqual(anchor?.x, originX)
    }

    // MARK: clamping

    func testVerticalClampKeepsChipInsideScreen() {
        // Caret near the top of the screen: centered placement would poke above the frame.
        let caret = CGRect(x: 200, y: screen.maxY - 6, width: 1.5, height: 15)
        let anchor = CaretAnchorResolver.chipOrigin(caretRect: caret, screenFrame: screen, chipSize: chip)
        XCTAssertNotNil(anchor)
        if let y = anchor?.y {
            XCTAssertLessThanOrEqual(y + chip.height, screen.maxY)
            XCTAssertGreaterThanOrEqual(y, screen.minY + CaretAnchorResolver.edgeMargin)
        }
    }

    func testDegenerateScreenFrameReturnsNil() {
        let caret = CGRect(x: 100, y: 100, width: 1.5, height: 15)
        XCTAssertNil(CaretAnchorResolver.chipOrigin(caretRect: caret,
                                                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 5),
                                                    chipSize: chip))
    }
}
