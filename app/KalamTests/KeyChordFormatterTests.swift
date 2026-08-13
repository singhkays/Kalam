import XCTest
@testable import Kalam_test

/// K-30 (Compass): capture allowlist + display formatting for "Record shortcut…".
final class KeyChordFormatterTests: XCTestCase {

    private func keyDown(
        _ keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [],
        charactersIgnoringModifiers: String? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers ?? "",
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - Accepted chords

    func testModifierPlusLetter() {
        let chord = KeyChordFormatter.chord(from: keyDown(1, flags: [.option], charactersIgnoringModifiers: "s"))
        XCTAssertEqual(chord?.keyCode, 1)
        XCTAssertEqual(chord?.modifiersRaw, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(chord?.displayCompact, "⌥ S")
        XCTAssertEqual(chord?.displayVerbose, "Option + S")
        XCTAssertEqual(chord?.side, .either)
    }

    func testMultipleModifiersOrderIsControlOptionShiftCommand() {
        let chord = KeyChordFormatter.chord(
            from: keyDown(1, flags: [.command, .shift], charactersIgnoringModifiers: "s")
        )
        XCTAssertEqual(chord?.displayCompact, "⇧ + ⌘ S")
        XCTAssertEqual(chord?.displayVerbose, "Shift + Command + S")
    }

    func testBareRightCommandCapturesWithSide() {
        let chord = KeyChordFormatter.chord(from: keyDown(54, flags: [.command]))
        XCTAssertEqual(chord?.displayCompact, "Right ⌘")
        XCTAssertEqual(chord?.displayVerbose, "Right Command")
        XCTAssertEqual(chord?.side, .right)
    }

    func testBareLeftOptionCapturesWithSide() {
        let chord = KeyChordFormatter.chord(from: keyDown(58, flags: [.option]))
        XCTAssertEqual(chord?.displayCompact, "Left ⌥")
        XCTAssertEqual(chord?.side, .left)
    }

    func testFunctionKeyAcceptedWithoutModifier() {
        let chord = KeyChordFormatter.chord(from: keyDown(96, charactersIgnoringModifiers: "F5"))
        XCTAssertEqual(chord?.displayCompact, "F5")
    }

    // MARK: - Rejected chords (reject flash)

    func testEscapeReturnsNil() {
        XCTAssertNil(KeyChordFormatter.chord(from: keyDown(53, flags: [.command])))
    }

    func testBareLetterRejected() {
        XCTAssertNil(KeyChordFormatter.chord(from: keyDown(1, charactersIgnoringModifiers: "s")))
    }

    func testBareDigitRejected() {
        XCTAssertNil(KeyChordFormatter.chord(from: keyDown(18, charactersIgnoringModifiers: "1")))
    }

    func testUnmappedKeyRejected() {
        XCTAssertNil(KeyChordFormatter.chord(from: keyDown(48, charactersIgnoringModifiers: "\t"))) // Tab
    }

    func testFnKeyCodeRejectedAsBareModifier() {
        // fn is preset-only (unstable flagsChanged) — keyCode 63 must not capture.
        XCTAssertNil(KeyChordFormatter.chord(from: keyDown(63, flags: [.function])))
    }
}
