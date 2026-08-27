import Foundation

/// Identity of one dictation session, minted by `RecordingSessionTracker`
/// when a recording commits. Every session-scoped lifecycle event carries it;
/// events naming any session other than the live one are dropped BY POLICY.
public typealias SessionID = UUID

/// K-52: pure decision layer for the dictation lifecycle
/// (`idle → warming → recording → finalizing → transcribing → inserting` plus
/// terminal resting states). Ported from the Jot audit P0 class:
///
/// * **P0 #1 — rapid re-record dropped a COMPLETED transcript.** The machine
///   makes superseding a session with committed text a legal-but-guarded
///   move: the only legal path emits `preserveTranscript` — a persisted
///   transcript is NEVER destroyed.
/// * **P0 #2 — Esc was a silent no-op during `transcribing`.** `escPressed`
///   is legal in every active state, with ASR-unfinished Esc mapping to
///   cancel + discard (a cancelled dictation leaves NO trace, per the
///   zero-retention posture) and delivered-text Esc mapping to hold.
///
/// Contract (same split as `PTTStateMachine`): the machine owns only
/// *decision* state and emits effects; `KalamApp` applies them in order.
/// Zero side effects, fully headless-testable. `transition` returns `nil`
/// for illegal moves AND for stale events — both mean "change nothing".
public enum DictationStateMachine {

    /// Apply one lifecycle event to `state`.
    ///
    /// * Returns the next state plus ordered effects for the caller to apply.
    /// * Returns `nil` for illegal transitions and for session-scoped events
    ///   whose UUID does not name the live session (stale by policy).
    public static func transition(_ state: DictationState, _ event: DictationEvent) -> DictationTransition? {
        // Start events own the interrupt path (rapid re-record / restart).
        switch event {
        case .keyDown(let new), .newSessionRequested(let new):
            return begin(state, newSession: new)
        default:
            break
        }

        // Terminal states are resting states: nothing but a start applies.
        guard state.phase != nil else { return nil }

        // Stale-session policy: a session-scoped callback naming any session
        // other than the live one is dropped, regardless of phase. This is
        // the generalized generation-pin for ALL async callbacks (K-52).
        if let named = event.session, named != state.session { return nil }

        switch (state, event) {
        // — warming: engine starting, no capture credited yet —
        case (.warming(let s), .captureStarted(_, let locked)):
            return DictationTransition(next: .recording(session: s, locked: locked))
        case (.warming(let s), .keyUp):
            // Released before capture was credited: nothing to tear down but
            // the start work itself.
            return DictationTransition(next: .cancelled(session: s, reason: .abandoned),
                                       effects: [.cancelWork(sessions: [s])])
        case (.warming(let s), .escPressed):
            return DictationTransition(next: .cancelled(session: s, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [s])])

        // — recording: capture live —
        case (.recording(let s, _), .keyUp):
            return DictationTransition(next: .finalizing(session: s))
        case (.recording(let s, _), .escPressed):
            return DictationTransition(next: .cancelled(session: s, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [s]), .discardAudio(session: s)])

        // — finalizing: stop task in flight (post-roll + drain + fetch) —
        case (.finalizing(let s), .captureEnded(_, .delivered)):
            return DictationTransition(next: .transcribing(session: s))
        case (.finalizing(let s), .captureEnded(_, .noSpeech)):
            return DictationTransition(next: .done(session: s, outcome: .empty))
        case (.finalizing(let s), .captureEnded(_, .failed)):
            return DictationTransition(next: .failed(session: s, reason: .capture))
        case (.finalizing(let s), .escPressed):
            // No transcript can exist yet (audio not fetched): cancel + drop
            // the in-flight bytes. Cancelled dictations leave NO trace.
            return DictationTransition(next: .cancelled(session: s, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [s]), .discardAudio(session: s)])

        // — transcribing: trim/quality guard + ASR + post-processing —
        case (.transcribing(let s), .asrStarted):
            // Marker event: records that the ASR leg is live. Matrix-pinned.
            return DictationTransition(next: .transcribing(session: s))
        case (.transcribing(let s), .asrFinished(_, .text)):
            // Text COMMITTED: from here on the transcript can never be
            // destroyed by a lifecycle event — only delivered or parked.
            return DictationTransition(next: .inserting(session: s))
        case (.transcribing(let s), .asrFinished(_, .empty)):
            return DictationTransition(next: .done(session: s, outcome: .empty))
        case (.transcribing(let s), .asrFinished(_, .failed)):
            return DictationTransition(next: .failed(session: s, reason: .asr))
        case (.transcribing(let s), .escPressed):
            // ASR unfinished: cancel the task, abandon the audio. No trace.
            return DictationTransition(next: .cancelled(session: s, reason: .userEsc),
                                       effects: [.cancelWork(sessions: [s]), .discardAudio(session: s)])

        // — inserting: committed text on its way to the target —
        case (.inserting(let s), .insertSucceeded(_, let outcome)):
            return DictationTransition(next: .done(session: s, outcome: outcome))
        case (.inserting(let s), .insertFailed):
            // Paste failed: park the transcript instead of destroying it. The
            // paste-time error surface already owns the user's attention, so
            // no extra chip notice.
            return DictationTransition(next: .done(session: s, outcome: .held),
                                       effects: [.preserveTranscript(session: s, notice: .never)])
        case (.inserting(let s), .escPressed):
            // Text delivered: surface the hold, then cancel downstream side
            // effects (the in-flight paste leg).
            return DictationTransition(next: .done(session: s, outcome: .held),
                                       effects: [.preserveTranscript(session: s, notice: .now),
                                                 .cancelWork(sessions: [s])])

        // — target drift: paste-time routing owns target stability (the
        //   captured-element / captured-app fallbacks); explicit no-op. —
        case (.inserting(let s), .targetChanged):
            return DictationTransition(next: .inserting(session: s))

        default:
            return nil
        }
    }

    /// Start/interrupt path. A start is legal from rest (fresh session) and
    /// from every pre-recording active phase; from `recording` it is illegal
    /// (the PTT layer never starts a second live recording — `startRecording`
    /// guards `!isRecording`).
    private static func begin(_ state: DictationState, newSession new: SessionID) -> DictationTransition? {
        switch state {
        case .idle, .done, .cancelled, .failed:
            return DictationTransition(next: .warming(session: new))
        case .warming(let old):
            // Start superseded a start: no capture credited, nothing to save.
            return DictationTransition(next: .warming(session: new),
                                       effects: [.cancelWork(sessions: [old])])
        case .recording:
            return nil
        case .finalizing(let old):
            // Audio in flight, no transcript exists: drop the bytes.
            return DictationTransition(next: .warming(session: new),
                                       effects: [.cancelWork(sessions: [old]),
                                                 .discardAudio(session: old)])
        case .transcribing(let old):
            // Re-record during ASR (manual-gate round 3 finding): the plan's
            // queue-or-hold policy. Do NOT cancel the ASR — a cancelled
            // chunked-ASR call never returns text, so a preserve effect here
            // would hold nothing. Let it finish: the commit point records
            // the text even though the session is now stale, the deferred
            // preserve materializes the held chip, and the PASTE leg (not
            // the record) is stopped by the session-currency gate.
            // (Esc from transcribing is the DIFFERENT case — explicit user
            // cancel → discard, handled by escPressed below.)
            return DictationTransition(next: .warming(session: new),
                                       effects: [.preserveTranscript(session: old, notice: .deferredUntilSettled)])
        case .inserting(let old):
            // Text IS committed: harvest it, THEN cancel the superseded paste
            // leg. Effects are ordered — preserve before cancel.
            return DictationTransition(next: .warming(session: new),
                                       effects: [.preserveTranscript(session: old, notice: .deferredUntilSettled),
                                                 .cancelWork(sessions: [old])])
        }
    }
}

// MARK: - Vocabulary

/// Coarse phase of the live session; `nil` on the `DictationState` resting cases.
public enum DictationPhase: Equatable {
    case idle
    case warming
    case recording(locked: Bool)
    case finalizing
    case transcribing
    case inserting
}

/// How a transcript reached a user-visible destination.
public enum PasteOutcome: Equatable {
    /// Inserted into the target.
    case pasted
    /// Parked in the held chip awaiting an explicit Paste action.
    case held
    /// Nothing survived trim / quality guard / ASR.
    case empty
}

/// Why a session produced no transcript.
public enum DiscardReason: Equatable {
    case userEsc
    /// Key-up before capture was credited.
    case abandoned
    case superseded
}

/// Why a session failed.
public enum DictationFailure: Equatable {
    case capture
    case asr
}

/// Full lifecycle state. The three terminal cases are RESTING states — the
/// next `keyDown` starts a fresh session from any of them (there is no
/// separate reset event to forget).
public enum DictationState: Equatable {
    case idle
    case warming(session: SessionID)
    case recording(session: SessionID, locked: Bool)
    case finalizing(session: SessionID)
    case transcribing(session: SessionID)
    case inserting(session: SessionID)
    case done(session: SessionID, outcome: PasteOutcome)
    case cancelled(session: SessionID, reason: DiscardReason)
    case failed(session: SessionID, reason: DictationFailure)

    /// True while some session owns live work (start events may interrupt).
    public var isActive: Bool { phase != nil }

    public var phase: DictationPhase? {
        switch self {
        case .idle, .done, .cancelled, .failed:
            return nil
        case .warming:
            return .warming
        case .recording(_, let locked):
            return .recording(locked: locked)
        case .finalizing:
            return .finalizing
        case .transcribing:
            return .transcribing
        case .inserting:
            return .inserting
        }
    }

    public var session: SessionID? {
        switch self {
        case .idle:
            return nil
        case .warming(let s),
             .finalizing(let s),
             .transcribing(let s),
             .inserting(let s),
             .done(let s, _),
             .cancelled(let s, _),
             .failed(let s, _):
            return s
        case .recording(let s, _):
            return s
        }
    }
}

/// Result of the stop/fetch leg.
public enum CaptureResult: Equatable {
    case delivered
    case noSpeech
    case failed
}

/// Result of the ASR leg. The `.text` payload is intentionally NOT carried in
/// `DictationState` — the app stores committed text (logs stay privacy-safe).
public enum ASRResult: Equatable {
    case text(String)
    case empty
    case failed
}

public enum DictationEvent: Equatable {
    /// User intent to begin; also THE re-record interrupt when a session is
    /// already active (P0 #1 window). Legal from rest and from every active
    /// phase except `recording`.
    case keyDown(session: SessionID)
    /// Engine credited live; `locked` mirrors the PTT trigger mode
    /// (toggle = latched). Informational.
    case captureStarted(session: SessionID, locked: Bool)
    /// PTT layer decided: stop and transcribe.
    case keyUp(session: SessionID)
    case captureEnded(session: SessionID, result: CaptureResult)
    /// Marker that the ASR call went out.
    case asrStarted(session: SessionID)
    case asrFinished(session: SessionID, result: ASRResult)
    /// Environment observation with no session of its own: applies to
    /// whatever is live, dropped at rest.
    case escPressed
    /// Alias of `keyDown` for system-initiated restarts (same interrupt
    /// semantics); kept as distinct vocabulary per the K-52 interface.
    case newSessionRequested(session: SessionID)
    /// Environment observation: frontmost app changed mid-leg. Explicit
    /// no-op — paste-time routing owns target stability.
    case targetChanged
    case insertFailed(session: SessionID)
    /// Not in the original K-52 vocabulary; required to reach
    /// `done(outcome:)` from `inserting`.
    case insertSucceeded(session: SessionID, outcome: PasteOutcome)

    /// The session this callback belongs to, or `nil` for the two
    /// environment observations (`escPressed`, `targetChanged`).
    public var session: SessionID? {
        switch self {
        case .keyDown(let s),
             .captureStarted(let s, _),
             .keyUp(let s),
             .captureEnded(let s, _),
             .asrStarted(let s),
             .asrFinished(let s, _),
             .newSessionRequested(let s),
             .insertFailed(let s),
             .insertSucceeded(let s, _):
            return s
        case .escPressed, .targetChanged:
            return nil
        }
    }
}

/// How the held-transcript chip should surface after a preserve.
public enum HoldNoticePolicy: Equatable {
    /// Present the chip now.
    case now
    /// A newer session owns the capsule — present once the machine rests.
    case deferredUntilSettled
    /// Another surface already owns the user's attention (e.g. the
    /// accessibility error on paste failure).
    case never
}

/// Ordered side-effect request. The machine never touches audio, ASR, or UI.
public enum DictationEffect: Equatable {
    /// A committed transcript exists for `session`: deliver or park it, never
    /// destroy. The app resolves delivery (captured-element auto-insert when
    /// the target is still addressable, held chip otherwise).
    case preserveTranscript(session: SessionID, notice: HoldNoticePolicy)
    /// Cancel in-flight ASR/paste tasks for these sessions.
    case cancelWork(sessions: [SessionID])
    /// Abandon in-memory audio for `session` — a cancelled dictation leaves
    /// no trace (buffers are never persisted, per the zero-retention posture).
    case discardAudio(session: SessionID)
}

public struct DictationTransition: Equatable {
    public let next: DictationState
    public var effects: [DictationEffect]

    public init(next: DictationState, effects: [DictationEffect] = []) {
        self.next = next
        self.effects = effects
    }
}

// MARK: - Privacy-safe logging

/// Log-friendly descriptions that NEVER include transcript text — safe for
/// `Logger` interpolation with `privacy: .public` and for test diff output.
extension DictationState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .warming(let s): return "warming(\(s.logTag))"
        case .recording(let s, let locked): return "recording(\(s.logTag), locked=\(locked))"
        case .finalizing(let s): return "finalizing(\(s.logTag))"
        case .transcribing(let s): return "transcribing(\(s.logTag))"
        case .inserting(let s): return "inserting(\(s.logTag))"
        case .done(let s, let o): return "done(\(s.logTag), \(o))"
        case .cancelled(let s, let r): return "cancelled(\(s.logTag), \(r))"
        case .failed(let s, let r): return "failed(\(s.logTag), \(r))"
        }
    }
}

extension DictationEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .keyDown(let s): return "keyDown(\(s.logTag))"
        case .captureStarted(let s, let locked): return "captureStarted(\(s.logTag), locked=\(locked))"
        case .keyUp(let s): return "keyUp(\(s.logTag))"
        case .captureEnded(let s, let r): return "captureEnded(\(s.logTag), \(r))"
        case .asrStarted(let s): return "asrStarted(\(s.logTag))"
        case .asrFinished(let s, let r):
            let shape: String
            switch r {
            case .text: shape = "text(…)"   // payload intentionally elided
            case .empty: shape = "empty"
            case .failed: shape = "failed"
            }
            return "asrFinished(\(s.logTag), \(shape))"
        case .escPressed: return "escPressed"
        case .newSessionRequested(let s): return "newSessionRequested(\(s.logTag))"
        case .targetChanged: return "targetChanged"
        case .insertFailed(let s): return "insertFailed(\(s.logTag))"
        case .insertSucceeded(let s, let o): return "insertSucceeded(\(s.logTag), \(o))"
        }
    }
}

extension PasteOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pasted: return "pasted"
        case .held: return "held"
        case .empty: return "empty"
        }
    }
}

extension DiscardReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .userEsc: return "userEsc"
        case .abandoned: return "abandoned"
        case .superseded: return "superseded"
        }
    }
}

extension DictationFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .capture: return "capture"
        case .asr: return "asr"
        }
    }
}

extension CaptureResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .delivered: return "delivered"
        case .noSpeech: return "noSpeech"
        case .failed: return "failed"
        }
    }
}

private extension SessionID {
    /// Short opaque tag for logs — never user content.
    var logTag: String { String(uuidString.prefix(8)) }
}
