import Foundation
import CoreGraphics

/// K-48 Task 7: pure geometry for the at-the-caret chip.
///
/// The chip TRAILS the caret (owner ruling, study v2): text, then caret bar, then chip,
/// occupying empty space ahead of the insertion point. Placement lives in AppKit screen
/// coordinates (bottom-left origin), matching DictationOverlayController.flipAXRect output.
///
/// The AX calls (selected-text range -> AXBoundsForRange) live in the controller layer;
/// this type stays unit-testable and free of ApplicationServices.
enum CaretAnchorResolver {

    struct Anchor: Equatable {
        /// Chip origin (left edge), AppKit coordinates.
        var x: CGFloat
        /// Chip origin (bottom edge), AppKit coordinates.
        var y: CGFloat
        /// True when the chip dropped BELOW the caret line because the caret sits
        /// within the right-edge margin (no room to trail).
        var flippedBelow: Bool
    }

    static let trailingGap: CGFloat = 6
    static let edgeMargin: CGFloat = 8
    static let belowGap: CGFloat = 4

    /// Validity gate for an AX-produced caret rect: present, finite, non-degenerate.
    static func isValidCaretRect(_ rect: CGRect?) -> Bool {
        guard let rect else { return false }
        guard rect.width > 0, rect.height > 0 else { return false }
        return !(rect.minX.isNaN || rect.minY.isNaN
                 || rect.width.isInfinite || rect.height.isInfinite)
    }

    /// Computes the chip origin for a caret rect inside a screen frame.
    /// Returns nil when the caret rect fails the validity gate or the frame is degenerate.
    static func chipOrigin(caretRect: CGRect, screenFrame: CGRect, chipSize: CGSize) -> Anchor? {
        guard isValidCaretRect(caretRect),
              screenFrame.width >= chipSize.width,
              screenFrame.height >= chipSize.height else { return nil }

        let defaultX = caretRect.maxX + trailingGap
        let centeredY = caretRect.midY - chipSize.height / 2

        // Room to trail? Place after the caret, vertically centered on the text line.
        if defaultX + chipSize.width <= screenFrame.maxX - edgeMargin {
            let clampedY = min(max(centeredY, screenFrame.minY + edgeMargin),
                               screenFrame.maxY - chipSize.height - edgeMargin)
            return Anchor(x: defaultX, y: clampedY, flippedBelow: false)
        }

        // Right-edge flip: drop below the caret line, right-aligned to the caret end.
        let flippedX = max(screenFrame.minX + edgeMargin,
                           min(caretRect.maxX, screenFrame.maxX - edgeMargin) - chipSize.width)
        let flippedY = max(screenFrame.minY + edgeMargin, caretRect.minY - belowGap - chipSize.height)
        return Anchor(x: flippedX, y: flippedY, flippedBelow: true)
    }
}
