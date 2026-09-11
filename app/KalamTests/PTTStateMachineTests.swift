import XCTest
@testable import Kalam_test

/// PTT state machine test coverage regression pins for the push-to-talk hotkey state machine
/// (hold / toggle / doubleTap / holdOrToggle), extracted from `AppDelegate`
/// so the timing-sensitive transitions are headlessly testable.
///
/// Contract simulated in every test (exactly what `AppDelegate` does):
/// - on a `.start` event, the AppDelegate latches `state.beginPending(mode)`
///   synchronously (the bounded engine start commits up to ~2 s later);
/// - on commit success it reports `state.commitPending()`; on any failure,
///   timeout, supersede, or pending-cancel it reports `state.rollbackPending()`
///   — a failed start leaves the machine idle;
/// - after a `.stop` event it reports via `state.recordingDidStop()`.
final class PTTStateMachineTests: XCTestCase {

    private var machine: PTTStateMachine!
    private var state: PTTStateMachine.State!

    override func setUp() {
        super.setUp()
        machine = PTTStateMachine()   // 0.45 s tap threshold, 0.35 s double-tap window
        state = PTTStateMachine.State()
    }

    // MARK: - hold

    func testHoldModeStartsOnDownStopsOnUp() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .hold, state: &state),
                       [.start(.hold)])
        state.recordingDidStart(.hold)
        XCTAssertEqual(machine.handle(isDown: false, now: 1.0, activationMode: .hold, state: &state),
                       [.stop])
    }

    func testHoldModeStrayKeyUpEmitsStopEvent() {
        // The AppDelegate's stopRecordingAndTranscribe() guards on isRecording,
        // so the machine may emit .stop unconditionally for hold mode.
        XCTAssertEqual(machine.handle(isDown: false, now: 0.5, activationMode: .hold, state: &state),
                       [.stop])
    }

    // MARK: - toggle

    func testToggleModeStartsOnFirstDownStopsOnSecondDown() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
        state.recordingDidStart(.toggle)
        XCTAssertEqual(machine.handle(isDown: true, now: 2.0, activationMode: .toggle, state: &state),
                       [.stop, .suppressNextKeyUp])
        state.recordingDidStop()
    }

    func testToggleKeyUpAfterToggleStopIsSuppressedOnce() {
        _ = machine.handle(isDown: true, now: 0, activationMode: .toggle, state: &state)
        state.recordingDidStart(.toggle)
        _ = machine.handle(isDown: true, now: 1.0, activationMode: .toggle, state: &state)
        state.recordingDidStop()
        // Key-up of the same physical press must be swallowed...
        XCTAssertEqual(machine.handle(isDown: false, now: 1.1, activationMode: .toggle, state: &state), [])
        // ...and only once: a fresh press starts normally.
        XCTAssertEqual(machine.handle(isDown: true, now: 2.0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
    }

    // MARK: - doubleTap

    func testDoubleTapSingleTapDoesNothing() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .doubleTap, state: &state), [])
        XCTAssertEqual(machine.handle(isDown: false, now: 0.1, activationMode: .doubleTap, state: &state), [])
        XCTAssertEqual(machine.handle(isDown: true, now: 2.0, activationMode: .doubleTap, state: &state), [])
    }

    func testDoubleTapWithinIntervalStartsToggle() {
        _ = machine.handle(isDown: true, now: 0, activationMode: .doubleTap, state: &state)
        _ = machine.handle(isDown: false, now: 0.1, activationMode: .doubleTap, state: &state)
        XCTAssertEqual(machine.handle(isDown: true, now: 0.3, activationMode: .doubleTap, state: &state),
                       [.start(.toggle)])
    }

    func testDoubleTapOutsideIntervalDoesNotStart() {
        _ = machine.handle(isDown: true, now: 0, activationMode: .doubleTap, state: &state)
        _ = machine.handle(isDown: false, now: 0.1, activationMode: .doubleTap, state: &state)
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .doubleTap, state: &state), [])
    }

    func testDoubleTapWhileRecordingStopsAndSuppresses() {
        state.recordingDidStart(.toggle)
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .doubleTap, state: &state),
                       [.stop, .suppressNextKeyUp])
        state.recordingDidStop()
        XCTAssertEqual(machine.handle(isDown: false, now: 1.1, activationMode: .doubleTap, state: &state), [])
    }

    func testDoubleTapWindowResetsAfterSuccessfulStart() {
        _ = machine.handle(isDown: true, now: 0, activationMode: .doubleTap, state: &state)
        _ = machine.handle(isDown: false, now: 0.1, activationMode: .doubleTap, state: &state)
        XCTAssertEqual(machine.handle(isDown: true, now: 0.3, activationMode: .doubleTap, state: &state),
                       [.start(.toggle)])
        state.recordingDidStart(.toggle)
        _ = machine.handle(isDown: true, now: 1.0, activationMode: .doubleTap, state: &state) // stop
        state.recordingDidStop()
        _ = machine.handle(isDown: false, now: 1.1, activationMode: .doubleTap, state: &state) // suppressed key-up
        // The successful start reset the tap window AND the suppressed key-up
        // must not re-arm it: a lone press must not start.
        XCTAssertEqual(machine.handle(isDown: true, now: 2.0, activationMode: .doubleTap, state: &state), [])
    }

    // MARK: - holdOrToggle

    func testHoldOrToggleShortTapConvertsToToggle() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.recordingDidStart(.hold)
        // Released before the 0.45 s threshold: keep recording, convert to toggle.
        XCTAssertEqual(machine.handle(isDown: false, now: 0.2, activationMode: .holdOrToggle, state: &state), [])
        XCTAssertEqual(state.recordingTriggerMode, .toggle)
        // Next key-down stops (toggle semantics), its key-up suppressed.
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .holdOrToggle, state: &state),
                       [.stop, .suppressNextKeyUp])
        state.recordingDidStop()
        XCTAssertEqual(machine.handle(isDown: false, now: 1.1, activationMode: .holdOrToggle, state: &state), [])
    }

    func testHoldOrToggleLongPressStops() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.recordingDidStart(.hold)
        XCTAssertEqual(machine.handle(isDown: false, now: 0.6, activationMode: .holdOrToggle, state: &state),
                       [.stop])
    }

    func testHoldOrToggleExtraKeyDownWhileRecordingIgnored() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.recordingDidStart(.hold)
        XCTAssertEqual(machine.handle(isDown: true, now: 0.1, activationMode: .holdOrToggle, state: &state), [])
    }

    // MARK: - pending window (bounded-start hardening)

    /// THE regression pin: in Hold-or-Toggle, the start tap's release lands
    /// before the bounded engine commit. The conversion must happen against
    /// the pending state so the NEXT single press stops (the shipped bug
    /// required two presses: the first was eaten by the stale idle read).
    func testHoldOrToggleQuickTapConvertsDuringPendingWindowAndCommitLatchesToggle() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.beginPending(.hold)
        // Release while the engine start is still in flight: converts the
        // pending hold to a latched toggle.
        XCTAssertEqual(machine.handle(isDown: false, now: 0.15, activationMode: .holdOrToggle, state: &state), [])
        XCTAssertEqual(state.pendingTriggerMode, .toggle)
        // The bounded start commits: whatever the window decided is latched.
        XCTAssertTrue(state.commitPending())
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.recordingTriggerMode, .toggle)
        // ONE press now stops — the shipped double-press bug is closed.
        XCTAssertEqual(machine.handle(isDown: true, now: 5.0, activationMode: .holdOrToggle, state: &state),
                       [.stop, .suppressNextKeyUp])
    }

    func testHoldOrToggleLongHoldDuringPendingEmitsStopForAbort() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.beginPending(.hold)
        // Release past the tap threshold while still pending: a normal hold
        // whose stop aborts the not-yet-live engine session.
        XCTAssertEqual(machine.handle(isDown: false, now: 0.6, activationMode: .holdOrToggle, state: &state),
                       [.stop])
    }

    func testHoldOrTogglePendingConvertedToggleStopsOnNextDown() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.beginPending(.hold)
        _ = machine.handle(isDown: false, now: 0.15, activationMode: .holdOrToggle, state: &state)
        XCTAssertEqual(state.pendingTriggerMode, .toggle)
        // A second press while the converted start is still pending aborts it.
        XCTAssertEqual(machine.handle(isDown: true, now: 0.4, activationMode: .holdOrToggle, state: &state),
                       [.stop, .suppressNextKeyUp])
    }

    func testToggleStopPressDuringPendingAbortsInsteadOfRestarting() {
        // The shipped bug's toggle variant: the machine's stale idle read made
        // a stop press during the pending window emit .start again — my
        // supersede path then RESTARTED the recording instead of stopping it.
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
        state.beginPending(.toggle)
        XCTAssertEqual(machine.handle(isDown: true, now: 0.2, activationMode: .toggle, state: &state),
                       [.stop, .suppressNextKeyUp])
        // The app aborts the pending start; the machine is idle for a fresh press.
        state.rollbackPending()
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
    }

    func testHoldSecondDownDuringPendingIgnoredAndUpAborts() {
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .hold, state: &state),
                       [.start(.hold)])
        state.beginPending(.hold)
        // Hold cannot double-start, in flight or live.
        XCTAssertEqual(machine.handle(isDown: true, now: 0.1, activationMode: .hold, state: &state), [])
        // The release of a pending hold aborts the not-yet-live session.
        XCTAssertEqual(machine.handle(isDown: false, now: 0.2, activationMode: .hold, state: &state),
                       [.stop])
    }

    func testCommitPendingWithoutPendingReturnsFalse() {
        XCTAssertFalse(state.commitPending())
        XCTAssertFalse(state.isRecording)
    }

    func testRollbackPendingRestoresIdleForFreshStart() {
        state.beginPending(.toggle)
        state.rollbackPending()
        XCTAssertFalse(state.isPending)
        XCTAssertFalse(state.isRecording)
        XCTAssertNil(state.recordingTriggerMode)
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
    }

    // MARK: - outcome contract

    func testFailedStartLeavesMachineIdle() {
        // AppDelegate latches a pending start synchronously and rolls it back
        // when the bounded start fails (guard failure, engine failure,
        // timeout). The machine must come back fully idle either way.
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        state.beginPending(.hold)
        XCTAssertEqual(machine.handle(isDown: false, now: 0.1, activationMode: .holdOrToggle, state: &state),
                       [])
        XCTAssertTrue(state.isPending)
        state.rollbackPending() // the app's failure path
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isPending)
        // A later press starts normally.
        XCTAssertEqual(machine.handle(isDown: true, now: 1.0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
    }

    func testResetForConfigurationChangeClearsTapWindow() {
        _ = machine.handle(isDown: true, now: 0, activationMode: .doubleTap, state: &state)
        _ = machine.handle(isDown: false, now: 0.1, activationMode: .doubleTap, state: &state)
        state.resetForConfigurationChange()
        XCTAssertEqual(machine.handle(isDown: true, now: 0.2, activationMode: .doubleTap, state: &state), [])
    }

    // MARK: - wake handler PTT field reset: system wake abandons live sessions

    func testAbandonActiveSessionEndsLiveRecording() {
        var state = PTTStateMachine.State()
        let localMachine = PTTStateMachine()

        // Start a toggle session the way AppDelegate does: event, then outcome report.
        let events = localMachine.handle(isDown: true, now: 100.0, activationMode: .toggle, state: &state)
        XCTAssertEqual(events, [.start(.toggle)])
        state.recordingDidStart(.toggle)
        XCTAssertTrue(state.isRecording)

        // System wake abandons the session: the machine must come back idle.
        state.abandonActiveSession()
        XCTAssertFalse(state.isRecording)
        XCTAssertNil(state.recordingTriggerMode)
        XCTAssertEqual(state.lastTapReleaseTime, 0)
        XCTAssertFalse(state.ignoreNextKeyUp)

        // The first post-wake press starts a FRESH recording (not a stop).
        XCTAssertEqual(localMachine.handle(isDown: true, now: 200.0, activationMode: .toggle, state: &state),
                       [.start(.toggle)])
    }

    func testResetForConfigurationChangeAloneDoesNotEndRecording() {
        // Pins WHY the wake path must not use resetForConfigurationChange:
        // it preserves isRecording by design (config flips mid-recording must
        // not kill the session).
        var state = PTTStateMachine.State()
        let localMachine = PTTStateMachine()
        _ = localMachine.handle(isDown: true, now: 100.0, activationMode: .toggle, state: &state)
        state.recordingDidStart(.toggle)

        state.resetForConfigurationChange()
        XCTAssertTrue(state.isRecording, "config-change reset must not end a live session; wake must call abandonActiveSession() instead")
    }
}
