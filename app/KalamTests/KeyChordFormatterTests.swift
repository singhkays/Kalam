import XCTest
@testable import Kalam_test

/// settings redesign (settings UI): capture allowlist + display formatting for "Record shortcut…".
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

    private func flagsChanged(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        ))
    }

    func testBareRightOptionCommitsOnceOnReleaseWithRightSide() throws {
        XCTAssertTrue(ShortcutCapture.eventMask.contains(.flagsChanged))
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.handle(try flagsChanged(61, [.option])), .waiting)
        let result = capture.handle(try flagsChanged(61, []))
        XCTAssertEqual(result, .commit(KeyChord(
            keyCode: 61, modifiersRaw: NSEvent.ModifierFlags.option.rawValue,
            side: .right, displayVerbose: "Right Option", displayCompact: "Right ⌥"
        )))
        XCTAssertEqual(capture.handle(try flagsChanged(61, [])), .waiting)
    }

    func testCommandThenKCommitsChordExactlyOnce() throws {
        var capture = ShortcutCapture()
        let commandK = keyDown(40, flags: [.command], charactersIgnoringModifiers: "k")
        XCTAssertEqual(capture.handle(try flagsChanged(55, [.command])), .waiting)
        XCTAssertEqual(capture.handle(commandK), .commit(KeyChord(
            keyCode: 40, modifiersRaw: NSEvent.ModifierFlags.command.rawValue,
            side: .either, displayVerbose: "Command + K", displayCompact: "⌘ K"
        )))
        XCTAssertEqual(capture.handle(try flagsChanged(55, [])), .waiting)
        XCTAssertEqual(capture.handle(commandK), .waiting)
    }

    func testEscapeCancelsPendingModifier() throws {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.handle(try flagsChanged(61, [.option])), .waiting)
        XCTAssertEqual(capture.handle(keyDown(53, flags: [.option])), .cancel)
        XCTAssertEqual(capture.handle(try flagsChanged(61, [])), .waiting)
    }

    func testUnsupportedKeyDoesNotTurnIntoBareModifierOnRelease() throws {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.handle(keyDown(40, charactersIgnoringModifiers: "k")), .reject)
        XCTAssertEqual(capture.handle(try flagsChanged(63, [.function])), .reject)
        _ = capture.handle(try flagsChanged(63, []))
        XCTAssertEqual(capture.handle(try flagsChanged(56, [.shift])), .reject)
        _ = capture.handle(try flagsChanged(56, []))
        XCTAssertEqual(capture.handle(try flagsChanged(61, [.option])), .waiting)
        XCTAssertEqual(capture.handle(keyDown(48, flags: [.option], charactersIgnoringModifiers: "\t")), .reject)
        XCTAssertEqual(capture.handle(try flagsChanged(61, [])), .waiting)
        XCTAssertEqual(capture.handle(keyDown(96, charactersIgnoringModifiers: "F5")),
                       .commit(KeyChord(keyCode: 96, modifiersRaw: 0, side: .either, displayVerbose: "F5", displayCompact: "F5")))
    }

    func testOverlappingModifiersDoNotCommitAsLoneModifier() throws {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.handle(try flagsChanged(58, [.option])), .waiting)
        XCTAssertEqual(capture.handle(try flagsChanged(61, [.option])), .waiting)
        XCTAssertEqual(capture.handle(try flagsChanged(58, [.option])), .waiting)
        XCTAssertEqual(capture.handle(try flagsChanged(61, [])), .waiting)
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
