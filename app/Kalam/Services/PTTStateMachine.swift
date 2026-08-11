import Foundation

/// Pure decision logic for the push-to-talk hotkey state machine
/// (hold / toggle / doubleTap / holdOrToggle), extracted from `AppDelegate`
/// (K-14) so the timing-sensitive transitions are headlessly testable.
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
        fileprivate(set) var ignoreNextKeyUp = false
        fileprivate(set) var currentKeyDownTime: CFAbsoluteTime = 0
        fileprivate(set) var lastTapReleaseTime: CFAbsoluteTime = 0

        /// Report that a recording actually started. Call ONLY on
        /// `startRecording` success — after all guards.
        mutating func recordingDidStart(_ mode: TriggerMode) {
            isRecording = true
            recordingTriggerMode = mode
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
    func handle(isDown: Bool, now: CFAbsoluteTime, activationMode: ActivationMode, state: inout State) -> [Event] {
        if isDown {
            state.currentKeyDownTime = now
            switch activationMode {
            case .hold:
                return [.start(.hold)]
            case .toggle:
                return toggleKeyDown(state: &state)
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
            // guards on `isRecording` and no-ops when idle.
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
        if state.isRecording {
            return [.stop, .suppressNextKeyUp]
        }
        return [.start(.toggle)]
    }

    private func doubleTapKeyDown(now: CFAbsoluteTime, state: inout State) -> [Event] {
        if state.isRecording {
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
        guard !state.isRecording else { return [] }
        return [.start(.hold)]
    }

    private func holdOrToggleKeyUp(now: CFAbsoluteTime, state: inout State) -> [Event] {
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
