import Foundation

/// Pure decision logic for the push-to-talk hotkey state machine
/// (hold / toggle / doubleTap / holdOrToggle), extracted from `AppDelegate`
/// (PTT state machine test coverage) so the timing-sensitive transitions are headlessly testable.
///
/// The machine owns only *decision* state and emits events; `AppDelegate`
/// owns all side effects (audio, ASR, paste, overlay, chime) and reports
/// recording outcomes back through `State.recordingDidStart(_:)` /
/// `State.recordingDidStop()` — a failed start (guard failure inside
/// `startRecording`) leaves the machine idle, exactly like the old inline
/// code, where the flags were only set after all guards passed.
struct PTTStateMachine {

    /// How a recording session was triggered (mirrors the former
    /// `AppDelegate.RecordingTriggerMode`).
    enum TriggerMode {
        case hold
        case toggle
    }

    /// Side-effect request emitted by `handle`. `AppDelegate` applies the
    /// returned array in order.
    enum Event: Equatable {
        /// Begin recording with the given trigger mode.
        case start(TriggerMode)
        /// End the current recording and transcribe.
        case stop
        /// The next key-up is the release of the same physical press that
        /// already stopped the recording — swallow it.
        case suppressNextKeyUp
    }

    /// Decision state. Field setters are `fileprivate(set)`: `handle`
    /// mutates via `inout` (same file), `AppDelegate` may only read and must
    /// report outcomes through the helpers below — the sync contract
    /// (start-success / stops) is compile-checked.
    struct State {
        fileprivate(set) var isRecording = false
        fileprivate(set) var recordingTriggerMode: TriggerMode?
        /// A `.start` event whose bounded engine start is still in flight
        /// (main-thread freeze hardening: the commit lands up to ~2 s after
        /// key-down). Non-nil while pending. The machine treats pending as
        /// in-progress for every key decision during the window, so a stop
        /// press or a quick-tap conversion can never race a stale idle read.
        /// `pendingTriggerMode` is live decision state: the holdOrToggle
        /// quick-tap release CONVERTS it to `.toggle` mid-flight, and the
        /// eventual commit latches whatever the window decided.
        fileprivate(set) var pendingTriggerMode: TriggerMode?
        fileprivate(set) var ignoreNextKeyUp = false
        fileprivate(set) var currentKeyDownTime: CFAbsoluteTime = 0
        fileprivate(set) var lastTapReleaseTime: CFAbsoluteTime = 0

        /// True while a started recording's bounded engine start is in flight.
        var isPending: Bool { pendingTriggerMode != nil }

        /// Report that a recording actually started. Call ONLY on
        /// `startRecording` success — after all guards.
        mutating func recordingDidStart(_ mode: TriggerMode) {
            isRecording = true
            recordingTriggerMode = mode
        }

        /// Latch a `.start` event synchronously: the bounded engine start is
        /// now in flight and every key event until commit/rollback decides
        /// against this pending start (stop press aborts; holdOrToggle quick
        /// release converts). Called by the app exactly where it receives
        /// the machine's `.start` — before any async work.
        mutating func beginPending(_ mode: TriggerMode) {
            pendingTriggerMode = mode
        }

        /// Commit the pending start (bounded engine start succeeded). Latches
        /// whatever trigger mode the pending window decided (the holdOrToggle
        /// quick-tap release may have converted a pending hold to toggle).
        /// Returns false when there is no pending start — the attempt was
        /// rolled back while the engine was starting (cancel, wake, quit);
        /// the caller must tear the engine down and drop the session.
        @discardableResult
        mutating func commitPending() -> Bool {
            guard let mode = pendingTriggerMode else { return false }
            pendingTriggerMode = nil
            isRecording = true
            recordingTriggerMode = mode
            return true
        }

        /// Roll the pending start back to idle. Called on start failure,
        /// timeout, supersede, and every pending-cancel path — a failed start
        /// leaves the machine idle exactly like the pre-hardening contract.
        mutating func rollbackPending() {
            pendingTriggerMode = nil
            isRecording = false
            recordingTriggerMode = nil
        }

        /// Report that the recording ended (stop / cancel paths).
        mutating func recordingDidStop() {
            isRecording = false
            recordingTriggerMode = nil
        }

        /// Apply `.suppressNextKeyUp`.
        mutating func suppressNextKeyUp() {
            ignoreNextKeyUp = true
        }

        /// PTT configuration changed — clear timing state (mirrors the old
        /// observer reset at `KalamApp.swift:192–193`).
        mutating func resetForConfigurationChange() {
            lastTapReleaseTime = 0
            ignoreNextKeyUp = false
        }

        /// wake handler PTT field reset: system wake abandons any session that was live across sleep.
        /// Unlike `resetForConfigurationChange` (timing flags only, deliberately
        /// keeps a live session), this ENDS the session: `isRecording` must be
        /// false afterwards so the first post-wake keypress starts a fresh
        /// recording instead of acting as a STOP on a junk clip. A pending
        /// (not yet committed) bounded start is abandoned with it.
        mutating func abandonActiveSession() {
            recordingDidStop()
            pendingTriggerMode = nil
            lastTapReleaseTime = 0
            ignoreNextKeyUp = false
        }
    }

    /// Hold shorter than this (holdOrToggle mode) converts to toggle.
    let holdOrToggleTapThreshold: CFTimeInterval
    /// Max gap between the two taps (doubleTap mode).
    let doubleTapInterval: CFTimeInterval

    init(holdOrToggleTapThreshold: CFTimeInterval = 0.45,
         doubleTapInterval: CFTimeInterval = 0.35) {
        self.holdOrToggleTapThreshold = holdOrToggleTapThreshold
        self.doubleTapInterval = doubleTapInterval
    }

    /// Feed one hotkey event into the machine. `now` is injected so tests
    /// control time; the production caller passes `CFAbsoluteTimeGetCurrent()`.
    ///
    /// Pending-window semantics (bounded-start hardening): while a started
    /// recording's engine start is still in flight (`state.isPending`), every
    /// decision reads the pending start as in-progress — a toggle/holdOrToggle
    /// stop press ABORTS the pending start instead of being eaten by a stale
    /// idle read, and a holdOrToggle quick-tap release still converts the
    /// pending hold to toggle (the commit latches the converted mode).
    func handle(isDown: Bool, now: CFAbsoluteTime, activationMode: PTTActivationMode, state: inout State) -> [Event] {
        if isDown {
            state.currentKeyDownTime = now
            switch activationMode {
            case .hold:
                // Hold cannot double-start: a second down during an in-flight
                // or live session is a no-op (the old code emitted .start and
                // let startRecording's guard no-op it — same outcome, decided here).
                if state.isRecording || state.isPending { return [] }
                return [.start(.hold)]
            case .toggle:
                if state.isRecording || state.isPending {
                    // Includes the pending window: a stop press during the
                    // bounded start aborts the attempt instead of restarting it.
                    return [.stop, .suppressNextKeyUp]
                }
                return [.start(.toggle)]
            case .doubleTap:
                return doubleTapKeyDown(now: now, state: &state)
            case .holdOrToggle:
                return holdOrToggleKeyDown(state: &state)
            }
        }

        if state.ignoreNextKeyUp {
            state.ignoreNextKeyUp = false
            return []
        }

        switch activationMode {
        case .hold:
            // Unconditional, like the old code: `stopRecordingAndTranscribe`
            // routes a pending-window stop to the pending-abort path and
            // no-ops when idle.
            return [.stop]
        case .toggle:
            return []
        case .doubleTap:
            state.lastTapReleaseTime = now
            return []
        case .holdOrToggle:
            return holdOrToggleKeyUp(now: now, state: &state)
        }
    }

    private func toggleKeyDown(state: inout State) -> [Event] {
        if state.isRecording || state.isPending {
            return [.stop, .suppressNextKeyUp]
        }
        return [.start(.toggle)]
    }

    private func doubleTapKeyDown(now: CFAbsoluteTime, state: inout State) -> [Event] {
        if state.isRecording || state.isPending {
            return [.stop, .suppressNextKeyUp]
        }
        guard state.lastTapReleaseTime > 0 else { return [] }
        guard (now - state.lastTapReleaseTime) <= doubleTapInterval else { return [] }
        state.lastTapReleaseTime = 0
        return [.start(.toggle)]
    }

    private func holdOrToggleKeyDown(state: inout State) -> [Event] {
        if state.isRecording, state.recordingTriggerMode == .toggle {
            return [.stop, .suppressNextKeyUp]
        }
        // A pending start already converted to toggle behaves like a latched
        // toggle session: the next press aborts it. A pending .hold keeps the
        // hold semantics (only its own release stops it).
        if state.isPending, state.pendingTriggerMode == .toggle {
            return [.stop, .suppressNextKeyUp]
        }
        guard !state.isRecording, !state.isPending else { return [] }
        return [.start(.hold)]
    }

    private func holdOrToggleKeyUp(now: CFAbsoluteTime, state: inout State) -> [Event] {
        // Pending window: the start tap's release lands BEFORE the bounded
        // commit (freeze hardening), so the quick-tap→toggle conversion must
        // read the pending state, not the stale idle one. A long hold in the
        // window is a normal hold whose stop aborts the not-yet-live engine.
        if state.isPending {
            if (now - state.currentKeyDownTime) < holdOrToggleTapThreshold {
                state.pendingTriggerMode = .toggle
                return []
            }
            return [.stop]
        }
        guard state.isRecording else { return [] }
        guard state.recordingTriggerMode == .hold else { return [] }
        let pressDuration = now - state.currentKeyDownTime
        if pressDuration < holdOrToggleTapThreshold {
            state.recordingTriggerMode = .toggle
            return []
        }
        return [.stop]
    }
}
