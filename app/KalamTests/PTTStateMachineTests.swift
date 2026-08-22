import XCTest
@testable import Kalam_test

/// K-14 regression pins for the push-to-talk hotkey state machine
/// (hold / toggle / doubleTap / holdOrToggle), extracted from `AppDelegate`
/// so the timing-sensitive transitions are headlessly testable.
///
/// Contract simulated in every test (exactly what `AppDelegate` does):
/// - after a `.start` event, the AppDelegate reports success via
///   `state.recordingDidStart(mode)` — it may NOT (failed start leaves the
///   machine idle);
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

    // MARK: - outcome contract

    func testFailedStartLeavesMachineIdle() {
        // AppDelegate reports NO recordingDidStart (guard failure: onboarding
        // incomplete, mic/ASR not ready). The machine must not be wedged.
        XCTAssertEqual(machine.handle(isDown: true, now: 0, activationMode: .holdOrToggle, state: &state),
                       [.start(.hold)])
        XCTAssertEqual(machine.handle(isDown: false, now: 0.1, activationMode: .holdOrToggle, state: &state), [])
        XCTAssertFalse(state.isRecording)
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

    // MARK: - K-37: system wake abandons live sessions

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
