# Bounded Audio Engine Start — Main-Thread Freeze Hardening

**Date:** 2026-09-09 · **Status:** IMPLEMENTED · **Scope:** `AudioRecorder.swift`, `KalamApp.swift`, `KalamTests/AudioStartPolicyTests.swift`

## Finding (from a reproduced freeze, Xcode log 2026-09-09)

`AVAudioEngine.start()` was called synchronously on the main thread inside
`startRecording` → `audio.startCollecting()`. When the HAL wedged mid-start
(USB mic device churn: `HALC_ProxyIOContext Start failed error 35` ×3,
`HALSystem no such object` ×8, `AVAudioIONodeImpl err = 1852797029`), the call
parked **indefinitely instead of throwing**. Result: frozen overlay timer,
unresponsive app, and an unquittable process (`NSApp.terminate` can never reach
`applicationWillTerminate` while the main thread is parked in CoreAudio).

The SwiftUI indicator surfaces were exonerated — six healthy
`listening → transcribing` cycles preceded the freeze, telemetry clean.

## Decision

1. **Off-main, bounded start.** `audio.startCollectingBounded()` runs the
   entire start (preflight → engine start → recovery retry → tap install) on a
   serial `engineOpQueue`, raced against a hard deadline
   (`AudioStartPolicy.timeoutMs = 2000`). The main thread can never block
   inside the HAL again.
2. **Pending-start state in the app layer.** Between key-down and commit the
   PTT machine stays idle. Key-up, Esc, a superseding press, quit, wake, and
   device changes during the window all abandon the attempt
   (`cancelPendingStartIfActive` / `audio.abandonPendingStart`).
3. **Timeout == failure.** Deadline elapsed → `endRetention(markComplete:
   false)` + "Microphone unavailable" toast + settings action + PTT idle.
   A half-live session is never committed.
4. **Superseded is silent.** `.superseded` outcomes (user canceled the press)
   surface no toast — consistent with D-1's "the user's action is the feedback".
5. **Self-clean contract.** An abandoned attempt that later returns (a wedged
   `engine.start()` has no cancellation surface) stops the engine and
   invalidates the graph; a late-started engine can never run unattended.
6. **Engine-access exclusivity invariant.** While `isStartInFlight`, ONLY the
   engineOpQueue block touches the engine. `finishStop` skips `engine.stop()`
   during flight; `refreshAudioInputAfterDeviceChange` defers the graph
   rebuild (invalidated flag ⇒ next press rebuilds); a superseding start waits
   for clearance inside its own budget, else reports `.timedOut`.
7. **Quit is unconditional.** `quit()` and `applicationWillTerminate` abandon
   the pending start first and deliberately never touch the engine — process
   death reclaims the mic indicator; the audio stack is the one thing that can
   hang and must never gate termination.
8. **Preflight fail-fast.** A dead default-input probe (off-main) fails before
   the graph is touched. The probe itself can block on a wedged HAL, which is
   why it runs inside the bounded window, never on main.
9. **Swift 6 fallout.** `startRecording` becoming `async` made direct
   `NSLock.lock()` in its body illegal; the partial-AX dedupe was extracted
   into the sync `claimFirstPartialAXLog(pid:)`.

## Parameters

- `AudioStartPolicy.timeoutMs = 2000` — covers worst observed Bluetooth start
  (~450 ms, `MicStallMonitor.graceMs`'s budget) with wide margin. Revisit only
  with a measured `toEngineMs` distribution near the margin.
- `inFlightWaitPollMs = 25` — supersede-wait poll cadence.
- `.failed` outcomes also force `invalidatePreparedState()` so the next press
  rebuilds a fresh graph instead of reusing failed engine state.

## Verification

- 7 headless pins in `AudioStartPolicyTests` (classification precedence,
  deadline boundary, self-clean contract, parameter sanity) — green.
- PTTStateMachine + AudioCaptureExchange suites untouched and green (38 cases
  total in the focused run); app target compiles with the async path.
- Manual hardware matrix still owed (unplug-mid-idle, device switch mid-press,
  sleep/wake with pending start, rapid double-press, quit during induced hang,
  Bluetooth worst case) — needs the running app.
