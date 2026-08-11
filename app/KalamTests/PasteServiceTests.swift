import AppKit
import XCTest
@testable import Kalam_test

/// K-02 regression tests. The failure-path test fails on the pre-fix code
/// (throw path never restores the clipboard); the rest pin the restore
/// machinery and the change-count guard. All tests use an isolated named
/// pasteboard so the user's real clipboard is never touched.
@MainActor
final class PasteServiceTests: XCTestCase {

    private func makeIsolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("KalamPasteTests.\(UUID().uuidString)"))
    }

    func testFailurePathRestoresOriginalClipboard() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        let original = "original-\(UUID().uuidString)"
        pasteboard.setString(original, forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { false }                                   // Cmd+V fails
        strategies.insertTextViaAccessibility = { _ in "forced failure" } // AX insert fails
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0.05
        let service = PasteService(strategies: strategies)

        XCTAssertThrowsError(try service.paste("transcript-\(UUID().uuidString)"))

        // The defer-scheduled restore runs ~restoreDelay later; poll briefly and
        // pump the main run loop so the main-queue asyncAfter can fire.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string), original,
            "K-02: the throw path must restore the original clipboard content"
        )
    }

    func testSnapshotRoundTripRestoresOriginalContent() {
        let pasteboard = makeIsolatedPasteboard()
        let original = "original-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)

        let snapshot = PasteService.PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcript-\(UUID().uuidString)", forType: .string)
        XCTAssertNotEqual(pasteboard.string(forType: .string), original)

        snapshot.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testRestoreReturnsOriginalWhenPasteboardUnchanged() {
        let pasteboard = makeIsolatedPasteboard()
        let original = "original-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)
        let snapshot = PasteService.PasteboardSnapshot(pasteboard: pasteboard)

        let service = PasteService(strategies: PasteService.PasteStrategies(
            pasteboard: pasteboard, restoreDelay: 0.05))
        let inserted = service.writeAndTrackPasteboardState(pasteboard: pasteboard, text: "transcript-\(UUID().uuidString)")
        XCTAssertTrue(pasteboard.string(forType: .string)?.hasPrefix("transcript-") == true)

        service.restoreClipboardIfNeeded(snapshot, insertedState: inserted, outcome: .cmdV)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testRestoreSkippedWhenUserCopiesNewContent() {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = PasteService.PasteboardSnapshot(pasteboard: pasteboard)

        let service = PasteService(strategies: PasteService.PasteStrategies(
            pasteboard: pasteboard, restoreDelay: 0.05))
        let inserted = service.writeAndTrackPasteboardState(pasteboard: pasteboard, text: "transcript")

        // User copies something new before the scheduled restore fires.
        pasteboard.clearContents()
        let userCopy = "user-copied-\(UUID().uuidString)"
        pasteboard.setString(userCopy, forType: .string)

        service.restoreClipboardIfNeeded(snapshot, insertedState: inserted, outcome: .cmdV)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string), userCopy,
            "guard must preserve the user's own new copy over the stale restore"
        )
    }

    /// K-08 pin: the Cmd+V path keeps a grace delay so the target app can read
    /// the pasteboard. Guards against a future over-correction that restores
    /// immediately on every path.
    func testCmdVPathHonorsGraceDelay() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        let original = "original-\(UUID().uuidString)"
        pasteboard.setString(original, forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { true }                                     // Cmd+V succeeds
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0.3
        let service = PasteService(strategies: strategies)

        try service.paste("transcript-\(UUID().uuidString)")

        // Immediately after paste: the transcript is still on the pasteboard
        // (grace period running — the target app hasn't "read" it yet).
        XCTAssertTrue(
            pasteboard.string(forType: .string)?.hasPrefix("transcript-") == true,
            "Cmd+V path must keep the transcript until the grace delay elapses"
        )

        // Pump the main runloop past the grace period; restore must have fired.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    /// K-08: the AX path never hands the pasteboard to the target app, so the
    /// snapshot restore must be immediate — no grace delay. RED on the pre-fix
    /// code, where every path waits `restoreDelay` (injected 0.3 s here).
    func testAccessibilityPathRestoresImmediately() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        let original = "original-\(UUID().uuidString)"
        pasteboard.setString(original, forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { false }                                    // Cmd+V fails
        strategies.insertTextViaAccessibility = { _ in nil }               // AX succeeds
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0.3                                      // long grace — must NOT apply here
        let service = PasteService(strategies: strategies)

        try service.paste("transcript-\(UUID().uuidString)")

        // No runloop pumping: the restore must already be complete.
        XCTAssertEqual(
            pasteboard.string(forType: .string), original,
            "K-08: AX success must restore the clipboard immediately (no grace delay)"
        )
    }
}
