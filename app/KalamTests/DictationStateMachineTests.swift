import XCTest
@testable import Kalam_test

/// K-52: exhaustive policy coverage for the dictation lifecycle machine.
///
/// The core is the matrix test: EVERY (state, event) pair is checked against
/// an independently written policy oracle, so a new enum case breaks this
/// file's compilation instead of silently escaping policy. The focused tests
/// pin the two Jot-audit P0 behaviors by name.
final class DictationStateMachineTests: XCTestCase {
    /// Fixed UUIDs so failure messages are stable.
    private let a = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0A))
    private let b = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0B))
    private let c = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0C))

    private var states: [DictationState] {
        [
            .idle,
            .warming(session: a),
            .recording(session: a, locked: false),
            .recording(session: a, locked: true),
            .finalizing(session: a),
            .transcribing(session: a),
            .inserting(session: a),
            .done(session: a, outcome: .pasted),
            .done(session: a, outcome: .held),
            .done(session: a, outcome: .empty),
            .cancelled(session: a, reason: .userEsc),
            .failed(session: a, reason: .asr),
        ]
    }

    private var events: [DictationEvent] {
        [
            .keyDown(session: b),
            .newSessionRequested(session: b),
            .captureStarted(session: a, locked: false),
            .keyUp(session: a),
            .captureEnded(session: a, result: .delivered),
            .asrStarted(session: a),
            .asrFinished(session: a, result: .text("hello")),
            .escPressed,
            .targetChanged,
            .insertFailed(session: a),
            .insertSucceeded(session: a, outcome: .pasted),
            .keyUp(session: b),                       // stale
            .asrFinished(session: b, result: .empty), // stale
        ]
    }

    // MARK: - P0 #1: the 200 ms re-record pin

    /// start → … → inserting → re-record: the FIRST transcript is pasted-or-
    /// held, NEVER dropped. This is the plan's exemplar regression pin.
    func testRapidReRecordWithDeliveredTranscriptPreservesIt() {
        var s = DictationState.idle
        for event in walk(to: .inserting(session: a)) {
            s = DictationStateMachine.transition(s, event)!.next
        }
        XCTAssertEqual(s, .inserting(session: a))

        let t = DictationStateMachine.transition(s, .newSessionRequested(session: b))
        XCTAssertNotNil(t, "a new session requested while text is committed must be a LEGAL move, never a drop")
        XCTAssertEqual(t?.next, .warming(session: b))
        XCTAssertEqual(t?.effects.first, .preserveTranscript(session: a, notice: .deferredUntilSettled),
                       "the committed transcript must be preserved BEFORE the old paste leg is cancelled")
        XCTAssertTrue(t?.effects.contains(.cancelWork(sessions: [a])) ?? false)

        // Same policy for the PTT-driven path.
        let t2 = DictationStateMachine.transition(s, .keyDown(session: b))
        XCTAssertEqual(t2, t, "keyDown and newSessionRequested share interrupt semantics")
    }

    /// Text committed during `inserting` can only ever leave that phase via a
    /// transition that preserves it — the never-destroyed property.
    func testCommittedTranscriptCanOnlyLeaveInsertingViaPreserve() {
        for event in events {
            guard let t = DictationStateMachine.transition(.inserting(session: a), event) else { continue }

            if t.next == .inserting(session: a) {
                continue // explicit no-op (targetChanged): nothing exited
            }

            if case .warming = t.next {
                // Legal start-interrupt (P0 #1): the ONLY exit is preserve-first.
                XCTAssertEqual(t.effects.first, .preserveTranscript(session: a, notice: .deferredUntilSettled),
                               "start-interrupt from inserting must preserve BEFORE cancelling: \(event)")
                continue
            }

            switch t.next {
            case .done(_, .pasted):
                break // delivered — nothing left to preserve
            case .done(_, .held):
                XCTAssertTrue(t.effects.contains(.preserveTranscript(session: a, notice: .now)) ||
                              t.effects.contains(.preserveTranscript(session: a, notice: .never)),
                              "leaving inserting for held requires a preserve effect: \(event)")
            default:
                XCTFail("inserting must never collapse to \(t.next) via \(event)")
            }
        }
    }

    /// Re-record while ASR is still in flight (manual-gate round 3): the
    /// plan's queue-or-hold policy — the ASR is NOT cancelled (a cancelled
    /// chunked-ASR call never yields text, so there would be nothing to
    /// hold); instead the interrupt defers a preserve, fulfilled when the
    /// ASR commits. Distinguishes re-record (preserve) from Esc (cancel).
    func testReRecordDuringASRDefersPreservationWithoutCancelling() {
        let t = DictationStateMachine.transition(.transcribing(session: a), .keyDown(session: b))
        XCTAssertEqual(t?.next, .warming(session: b))
        XCTAssertEqual(t?.effects, [.preserveTranscript(session: a, notice: .deferredUntilSettled)])
    }

    // MARK: - P0 #2: Esc in every active state

    func testEscIsLiveInEveryActiveState() throws {
        // ASR-unfinished states: cancel + discard; nothing to preserve.
        for state in [DictationState.warming(session: a), .recording(session: a, locked: false),
                      .finalizing(session: a), .transcribing(session: a)] {
            let t = try XCTUnwrap(DictationStateMachine.transition(state, .escPressed),
                                  "Esc must not be a no-op in \(state)")
            XCTAssertEqual(t.next, .cancelled(session: a, reason: .userEsc))
            XCTAssertTrue(t.effects.contains(.cancelWork(sessions: [a])))
            if state.phase != .warming {
                XCTAssertTrue(t.effects.contains(.discardAudio(session: a)),
                              "cancel in \(state) must abandon the audio bytes")
            }
        }

        // Text delivered: Esc surfaces the hold, then cancels downstream.
        let t = try XCTUnwrap(DictationStateMachine.transition(.inserting(session: a), .escPressed))
        XCTAssertEqual(t.next, .done(session: a, outcome: .held))
        XCTAssertEqual(t.effects, [.preserveTranscript(session: a, notice: .now),
                                   .cancelWork(sessions: [a])])
    }

    func testEscAtRestIsDropped() {
        XCTAssertNil(DictationStateMachine.transition(.idle, .escPressed))
        XCTAssertNil(DictationStateMachine.transition(.done(session: a, outcome: .pasted), .escPressed))
        XCTAssertNil(DictationStateMachine.transition(.cancelled(session: a, reason: .userEsc), .escPressed))
        XCTAssertNil(DictationStateMachine.transition(.failed(session: a, reason: .asr), .escPressed))
    }

    // MARK: - Happy paths

    func testHoldHappyPath() {
        var s = DictationState.idle
        for event in walk(to: .done(session: a, outcome: .pasted)) {
            let t = DictationStateMachine.transition(s, event)
            XCTAssertNotNil(t, "legal step \(event) from \(s)")
            s = t!.next
        }
        XCTAssertEqual(s, .done(session: a, outcome: .pasted))
    }

    func testToggleLockedFlagIsCarried() {
        let s = DictationStateMachine.transition(.idle, .keyDown(session: a))
        let t = DictationStateMachine.transition(s!.next, .captureStarted(session: a, locked: true))
        XCTAssertEqual(t?.next, .recording(session: a, locked: true))
    }

    func testKeyUpBeforeCaptureCreditsIsAbandoned() {
        let t = DictationStateMachine.transition(.warming(session: a), .keyUp(session: a))
        XCTAssertEqual(t?.next, .cancelled(session: a, reason: .abandoned))
        XCTAssertEqual(t?.effects, [.cancelWork(sessions: [a])])
    }

    func testNoSpeechAndFailureExits() {
        XCTAssertEqual(DictationStateMachine.transition(.finalizing(session: a), .captureEnded(session: a, result: .noSpeech))?.next,
                       .done(session: a, outcome: .empty))
        XCTAssertEqual(DictationStateMachine.transition(.transcribing(session: a), .asrFinished(session: a, result: .empty))?.next,
                       .done(session: a, outcome: .empty))
        XCTAssertEqual(DictationStateMachine.transition(.transcribing(session: a), .asrFinished(session: a, result: .failed))?.next,
                       .failed(session: a, reason: .asr))
        XCTAssertEqual(DictationStateMachine.transition(.finalizing(session: a), .captureEnded(session: a, result: .failed))?.next,
                       .failed(session: a, reason: .capture))
    }

    // MARK: - Staleness & rest

    func testStaleSessionEventsAreDroppedByPolicy() {
        let activeStates: [DictationState] = [
            .warming(session: a),
            .recording(session: a, locked: false),
            .finalizing(session: a),
            .transcribing(session: a),
            .inserting(session: a),
        ]
        let staleEvents: [DictationEvent] = [
            .keyUp(session: b),
            .captureEnded(session: b, result: .delivered),
            .asrStarted(session: b),
            .asrFinished(session: b, result: .text("old")),
            .insertSucceeded(session: b, outcome: .pasted),
            .insertFailed(session: b),
        ]
        for state in activeStates {
            for event in staleEvents {
                XCTAssertNil(DictationStateMachine.transition(state, event),
                             "stale event \(event) against \(state) must be dropped BY POLICY")
            }
        }
    }

    func testTerminalsAreRestingStates() {
        let terminals: [DictationState] = [
            .done(session: a, outcome: .pasted),
            .done(session: a, outcome: .held),
            .done(session: a, outcome: .empty),
            .cancelled(session: a, reason: .userEsc),
            .failed(session: a, reason: .asr),
        ]
        for terminal in terminals {
            // Only starts apply, and they start a FRESH session.
            for start in [DictationEvent.keyDown(session: c), .newSessionRequested(session: c)] {
                let t = DictationStateMachine.transition(terminal, start)
                XCTAssertEqual(t?.next, .warming(session: c))
                XCTAssertTrue(t?.effects.isEmpty ?? false)
            }
            // Everything else is dropped.
            for event in events where event.session == a {
                XCTAssertNil(DictationStateMachine.transition(terminal, event),
                             "non-start \(event) against resting \(terminal) must be dropped")
            }
            XCTAssertNil(DictationStateMachine.transition(terminal, .escPressed))
        }
    }

    /// A start while a recording is LIVE is illegal: the PTT layer guarantees
    /// a second `startRecording` cannot run (`!isRecording` guard).
    func testStartWhileRecordingIsIllegal() {
        for start in [DictationEvent.keyDown(session: b), .newSessionRequested(session: b)] {
            for locked in [false, true] {
                XCTAssertNil(DictationStateMachine.transition(.recording(session: a, locked: locked), start))
            }
        }
    }

    /// Same-session start events are impossible from the tracker (a fresh
    /// UUID is minted per session). Pin the documented semantics anyway: if
    /// one ever arrived, the machine treats it as an interrupt of that same
    /// session — never a silent drop.
    func testSameSessionStartIsTreatedAsInterrupt() {
        let t = DictationStateMachine.transition(.transcribing(session: a), .keyDown(session: a))
        XCTAssertEqual(t?.next, .warming(session: a))
        XCTAssertEqual(t?.effects, [.preserveTranscript(session: a, notice: .deferredUntilSettled)])
    }

    // MARK: - Exhaustive matrix vs the policy oracle

    /// Every (state, event) pair must match this independently written table.
    /// Adding an enum case breaks THIS switch's exhaustiveness first.
    private func expected(_ s: DictationState, _ e: DictationEvent) -> DictationTransition? {
        switch e {
        case .keyDown(let n), .newSessionRequested(let n):
            switch s {
            case .idle, .done, .cancelled, .failed:
                return DictationTransition(next: .warming(session: n))
            case .warming(let old):
                return DictationTransition(next: .warming(session: n),
                                           effects: [.cancelWork(sessions: [old])])
            case .recording:
                return nil
            case .finalizing(let old):
                return DictationTransition(next: .warming(session: n),
                                           effects: [.cancelWork(sessions: [old]), .discardAudio(session: old)])
            case .transcribing(let old):
                return DictationTransition(next: .warming(session: n),
                                           effects: [.preserveTranscript(session: old, notice: .deferredUntilSettled)])
            case .inserting(let old):
                return DictationTransition(next: .warming(session: n),
                                           effects: [.preserveTranscript(session: old, notice: .deferredUntilSettled),
                                                     .cancelWork(sessions: [old])])
            }
        default:
            break
        }
        guard s.phase != nil else { return nil }
        if let named = e.session, named != s.session { return nil }

        switch (s, e) {
        case (.warming(let x), .captureStarted(_, let locked)):
            return DictationTransition(next: .recording(session: x, locked: locked))
        case (.warming(let x), .keyUp):
            return DictationTransition(next: .cancelled(session: x, reason: .abandoned),
                                       effects: [.cancelWork(sessions: [x])])
        case (.warming(let x), .escPressed):
            return DictationTransition(next: .cancelled(session: x, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [x])])
        case (.recording(let x, _), .keyUp):
            return DictationTransition(next: .finalizing(session: x))
        case (.recording(let x, _), .escPressed):
            return DictationTransition(next: .cancelled(session: x, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [x]), .discardAudio(session: x)])
        case (.finalizing(let x), .captureEnded(_, .delivered)):
            return DictationTransition(next: .transcribing(session: x))
        case (.finalizing(let x), .captureEnded(_, .noSpeech)):
            return DictationTransition(next: .done(session: x, outcome: .empty))
        case (.finalizing(let x), .captureEnded(_, .failed)):
            return DictationTransition(next: .failed(session: x, reason: .capture))
        case (.finalizing(let x), .escPressed):
            return DictationTransition(next: .cancelled(session: x, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [x]), .discardAudio(session: x)])
        case (.transcribing(let x), .asrStarted):
            return DictationTransition(next: .transcribing(session: x))
        case (.transcribing(let x), .asrFinished(_, .text)):
            return DictationTransition(next: .inserting(session: x))
        case (.transcribing(let x), .asrFinished(_, .empty)):
            return DictationTransition(next: .done(session: x, outcome: .empty))
        case (.transcribing(let x), .asrFinished(_, .failed)):
            return DictationTransition(next: .failed(session: x, reason: .asr))
        case (.transcribing(let x), .escPressed):
            return DictationTransition(next: .cancelled(session: x, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [x]), .discardAudio(session: x)])
        case (.inserting(let x), .insertSucceeded(_, let outcome)):
            return DictationTransition(next: .done(session: x, outcome: outcome))
        case (.inserting(let x), .insertFailed):
            return DictationTransition(next: .done(session: x, outcome: .held),
                                       effects: [.preserveTranscript(session: x, notice: .never)])
        case (.inserting(let x), .escPressed):
            return DictationTransition(next: .done(session: x, outcome: .held),
                                       effects: [.preserveTranscript(session: x, notice: .now),
                                                 .cancelWork(sessions: [x])])
        case (.inserting(let x), .targetChanged):
            return DictationTransition(next: .inserting(session: x))
        default:
            return nil
        }
    }

    func testFullMatrixMatchesPolicyOracle() {
        for state in states {
            for event in events {
                let got = DictationStateMachine.transition(state, event)
                let want = expected(state, event)
                XCTAssertEqual(got, want, "state=\(state) event=\(event)")
            }
        }
    }

    func testAppliedTransitionsNeverLoseTheSession() {
        for state in states where state.phase != nil {
            for event in events {
                if let t = DictationStateMachine.transition(state, event) {
                    XCTAssertNotNil(t.next.session, "applied transition from \(state) via \(event) lost its session")
                }
            }
        }
    }

    func testLogDescriptionsNeverContainTranscriptText() {
        let d = "\(DictationEvent.asrFinished(session: a, result: .text("SECRET-TRANSCRIPT")))"
        XCTAssertFalse(d.contains("SECRET-TRANSCRIPT"), "log description leaked user text: \(d)")
        XCTAssertTrue(d.contains("text(…)"))
    }

    // MARK: - Helpers

    /// The canonical legal walk from `.idle` to `target`.
    private func walk(to target: DictationState) -> [DictationEvent] {
        let toInserting: [DictationEvent] = [
            .keyDown(session: a),
            .captureStarted(session: a, locked: false),
            .keyUp(session: a),
            .captureEnded(session: a, result: .delivered),
            .asrStarted(session: a),
            .asrFinished(session: a, result: .text("hello")),
        ]
        if target == .inserting(session: a) {
            return toInserting
        }
        return toInserting + [.insertSucceeded(session: a, outcome: .pasted)]
    }
}
