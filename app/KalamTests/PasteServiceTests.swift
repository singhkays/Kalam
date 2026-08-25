import AppKit
import XCTest
@testable import Kalam_test

/// clipboard restore on failed paste regression tests. The failure-path test fails on the pre-fix code
/// (throw path never restores the clipboard); the rest pin the restore
/// machinery and the change-count guard. pasteboard exposure minimization tests pin per-outcome restore
/// timing; cooperative pasteboard polling tests pin cooperative (non-blocking) commit polling.
/// All tests use an isolated named pasteboard so the user's real clipboard
/// is never touched.
@MainActor
final class PasteServiceTests: XCTestCase {

    private func makeIsolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("KalamPasteTests.\(UUID().uuidString)"))
    }

    func testFailurePathRestoresOriginalClipboard() async throws {
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

        do {
            try await service.paste("transcript-\(UUID().uuidString)")
            XCTFail("paste must throw when every strategy fails")
        } catch PasteServiceError.pasteExecutionFailed {
            // expected — all three strategies failed
        }

        // clipboard restore on failed paste + pasteboard exposure minimization: the failure path restores immediately (no grace delay),
        // so no runloop pumping is needed — assert directly.
        XCTAssertEqual(
            pasteboard.string(forType: .string), original,
            "clipboard restore on failed paste: the throw path must restore the original clipboard content"
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

    /// pasteboard exposure minimization pin: the Cmd+V path keeps a grace delay so the target app can read
    /// the pasteboard. Guards against a future over-correction that restores
    /// immediately on every path.
    func testCmdVPathHonorsGraceDelay() async throws {
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

        try await service.paste("transcript-\(UUID().uuidString)")

        // Immediately after paste: the transcript is still on the pasteboard
        // (grace period running — the target app hasn't "read" it yet).
        XCTAssertTrue(
            pasteboard.string(forType: .string)?.hasPrefix("transcript-") == true,
            "Cmd+V path must keep the transcript until the grace delay elapses"
        )

        // Yield to the main runloop past the grace period; restore must have
        // fired (Task.sleep suspends the test, letting the asyncAfter run).
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    /// pasteboard exposure minimization: the AX path never hands the pasteboard to the target app, so the
    /// snapshot restore must be immediate — no grace delay. RED on the pre-fix
    /// code, where every path waits `restoreDelay` (injected 0.3 s here).
    func testAccessibilityPathRestoresImmediately() async throws {
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

        try await service.paste("transcript-\(UUID().uuidString)")

        // No runloop pumping: the restore must already be complete.
        XCTAssertEqual(
            pasteboard.string(forType: .string), original,
            "pasteboard exposure minimization: AX success must restore the clipboard immediately (no grace delay)"
        )
    }

    /// cooperative pasteboard polling: the commit wait must yield the MainActor between polls. A
    /// main-queue sentinel queued before the wait must run *during* it —
    /// impossible while the old usleep loop holds the main thread.
    func testWaitForPasteboardCommitYieldsMainThread() async {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.pasteboard = pasteboard
        let service = PasteService(strategies: strategies)

        // A target changeCount that never arrives → the wait runs its full timeout.
        let unreachableTarget = pasteboard.changeCount + 999
        var sentinelRan = false
        DispatchQueue.main.async { sentinelRan = true }

        let started = Date()
        let committed = await service.waitForPasteboardCommit(
            pasteboard: pasteboard,
            targetChangeCount: unreachableTarget,
            timeoutSeconds: 0.1,
            pollIntervalSeconds: 0.005
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(committed, "unreachable target → timeout")
        XCTAssertGreaterThanOrEqual(elapsed, 0.09, "still bounded by the timeout")
        XCTAssertTrue(sentinelRan,
            "cooperative pasteboard polling: main-queue work must run during the wait (no usleep on the MainActor)")
    }

    /// cooperative pasteboard polling pin: the wait still detects the pasteboard advancing mid-wait.
    /// Sync + runloop pumping: the wait task's MainActor jobs run while the
    /// test pumps. The mid-wait write mirrors writeAndTrackPasteboardState's
    /// shape (clearContents + setString) — on this host clearContents bumps
    /// changeCount synchronously, setString alone may not.
    func testWaitForPasteboardCommitDetectsAdvanceDuringWait() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)
        let service = PasteService(strategies: PasteService.PasteStrategies(pasteboard: pasteboard))

        // Let the stale write settle, then target one changeCount beyond it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let target = pasteboard.changeCount + 1

        let resultBox = TestBox<Bool>()
        let waitTask = Task { resultBox.value = await service.waitForPasteboardCommit(
            pasteboard: pasteboard, targetChangeCount: target,
            timeoutSeconds: 1.0, pollIntervalSeconds: 0.005) }

        // Mid-wait, advance the pasteboard from the main thread.
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        pasteboard.clearContents()
        pasteboard.setString("committed-\(UUID().uuidString)", forType: .string)

        // Pump until the wait finishes (the wait sees the advance mid-poll).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && resultBox.value == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(resultBox.value, true,
            "cooperative pasteboard polling: the wait must observe a pasteboard advance that lands mid-wait")
    }

    /// cooperative pasteboard polling: canceling the task mid-wait aborts the polling promptly — the
    /// wait must not run its full timeout after cancellation.
    func testWaitForPasteboardCommitRespondsToCancellation() async throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)
        let service = PasteService(strategies: PasteService.PasteStrategies(pasteboard: pasteboard))

        // Unreachable target + a long timeout: only cancellation can end this.
        let unreachableTarget = pasteboard.changeCount + 999
        let task = Task { await service.waitForPasteboardCommit(
            pasteboard: pasteboard, targetChangeCount: unreachableTarget,
            timeoutSeconds: 5, pollIntervalSeconds: 0.005) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        let started = Date()
        let result = await task.value
        XCTAssertFalse(result, "canceled wait must return false")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
            "cooperative pasteboard polling: cancellation must abort the wait promptly, not run the full timeout")
    }

    /// stale-recording paste guard × clipboard restore on failed paste × pasteboard exposure minimization × cooperative pasteboard polling interplay: canceling the surrounding task
    /// aborts the paste before it dispatches (no Cmd+V, no AX) AND the defer
    /// restore still returns the clipboard to its original content. (A
    /// mid-wait cancel can't be staged headlessly through paste() on this
    /// host — named-pasteboard commits land synchronously, so the commit wait
    /// early-returns; wait-level cancellation is covered by
    /// testWaitForPasteboardCommitRespondsToCancellation.)
    func testPasteAbortsWhenCanceledAndRestoresClipboard() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        let original = "original-\(UUID().uuidString)"
        pasteboard.setString(original, forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = {
            XCTFail("Cmd+V must not be posted after cancellation")
            return true
        }
        strategies.insertTextViaAccessibility = { _ in
            XCTFail("AX insert must not run after cancellation")
            return nil
        }
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0.3
        let service = PasteService(strategies: strategies)

        let errorBox = TestBox<Error>()
        let task = Task {
            do {
                try await service.paste("transcript-\(UUID().uuidString)")
            } catch {
                errorBox.value = error
            }
        }
        // Cancel before the paste task starts dispatching: every path leads
        // to Task.checkCancellation() → CancellationError, and the defer
        // restore still runs.
        task.cancel()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && errorBox.value == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(errorBox.value is CancellationError,
            "paste must throw CancellationError when canceled")

        // The defer restore runs synchronously in the throw path (delay 0);
        // pump briefly in case the retry path is exercised.
        let restoreDeadline = Date().addingTimeInterval(1.0)
        while Date() < restoreDeadline {
            if pasteboard.string(forType: .string) == original { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), original,
            "clipboard restore on failed paste: the defer restore must still fire after cancellation")
    }

    // MARK: - record-time paste target capture (captured-element paste + routing)

    func testPasteIntoCapturedElementSucceedsWithoutTouchingPasteboard() async throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("user-copy-\(UUID().uuidString)", forType: .string)

        let element = AXUIElementCreateSystemWide()
        let insertedElement = TestBox<AXUIElement>()
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.insertTextIntoElement = { target, _ in
            insertedElement.value = target
            return nil
        }
        strategies.pasteboard = pasteboard
        let service = PasteService(strategies: strategies)

        try await service.paste(into: element, text: "transcript-\(UUID().uuidString)")

        XCTAssertNotNil(insertedElement.value, "the captured element must receive the insert")
        XCTAssertTrue(insertedElement.value === element, "insert must target the captured element")
        // The captured path bypasses the pasteboard entirely.
        XCTAssertEqual(
            pasteboard.string(forType: .string)?.hasPrefix("user-copy-"), true,
            "record-time paste target capture: the user's clipboard must be untouched by a captured-element paste"
        )
    }

    func testPasteIntoCapturedElementThrowsOnInsertFailure() async {
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.insertTextIntoElement = { _, _ in "element is gone" }
        let service = PasteService(strategies: strategies)

        do {
            try await service.paste(into: AXUIElementCreateSystemWide(), text: "transcript")
            XCTFail("captured-element paste must throw when the insert fails")
        } catch PasteServiceError.pasteExecutionFailed(let reason) {
            XCTAssertEqual(reason, "element is gone")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPasteIntoCapturedElementRequiresTrust() async {
        var insertCalled = false
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { false }
        strategies.insertTextIntoElement = { _, _ in
            insertCalled = true
            return nil
        }
        let service = PasteService(strategies: strategies)

        do {
            try await service.paste(into: AXUIElementCreateSystemWide(), text: "transcript")
            XCTFail("captured-element paste must require AX trust")
        } catch PasteServiceError.accessibilityNotTrusted {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(insertCalled, "no insert may run without AX trust")
    }

    func testPasteRoutingNoCaptureFallsBackToFrontmost() {
        let element = AXUIElementCreateSystemWide()
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: nil, capturedElement: element, frontmostPID: 42),
            .frontmost
        )
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: nil, capturedElement: nil, frontmostPID: 42),
            .frontmost
        )
    }

    func testPasteRoutingSameAppUsesFrontmost() {
        let element = AXUIElementCreateSystemWide()
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: 7, capturedElement: element, frontmostPID: 7),
            .frontmost
        )
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: 7, capturedElement: nil, frontmostPID: 7),
            .frontmost
        )
    }

    func testPasteRoutingSwitchedAppTargetsCapturedElement() {
        let element = AXUIElementCreateSystemWide()
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: 7, capturedElement: element, frontmostPID: 42),
            .capturedElement(element)
        )
    }

    // partial-AX target capture no-op Option A: partial-AX apps yield no element but DO yield a pid —
    // switching away must reactivate-and-paste, not degrade to frontmost-at-paste-time.
    func testPasteRoutingPidOnlySwitchedAppTargetsCapturedApp() {
        XCTAssertEqual(
            PasteService.PasteRouting.target(capturedPID: 7, capturedElement: nil, frontmostPID: 42),
            .capturedApp(7)
        )
    }
}

/// Mutable box so a Task closure can hand a result back to a sync test
/// without tripping Swift 6's captured-var concurrency rules.
private final class TestBox<T> {
    var value: T?
}
