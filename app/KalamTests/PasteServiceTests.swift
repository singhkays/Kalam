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

        service.restoreClipboardIfNeeded(snapshot, insertedState: inserted)

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

        service.restoreClipboardIfNeeded(snapshot, insertedState: inserted)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string), userCopy,
            "guard must preserve the user's own new copy over the stale restore"
        )
    }
}
