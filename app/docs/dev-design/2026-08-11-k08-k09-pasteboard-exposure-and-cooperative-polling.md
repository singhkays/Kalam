# K-08 + K-09 Implementation Plan — Pasteboard Exposure Window & Cooperative Commit Polling

> **For agentic workers:** execute task-by-task; checkboxes track progress. Read `app/docs/IMPROVEMENT_PLAN.md` protocol first (status legend, claim → verify → ✅). Re-verify every line number and re-read each file right before editing — the shared-repo tree drifts (sibling sessions commit on the same `main`). Run all commands from the repo root `/Volumes/My Shared Files/GitHub/Kalam`.

**Goal:** (K-08) minimize the time transcript text sits on the user's pasteboard after a paste — currently up to ~0.5 s after Cmd+V on every pasteboard path, even when the pasteboard was never handed to the target app; and (K-09) replace `waitForPasteboardCommit`'s main-thread-blocking `usleep` loop (up to 150 ms on the MainActor) with cooperative `Task.sleep` polling so the UI never stalls during a paste.

**Architecture:** Both changes are confined to `app/Kalam/Services/PasteService.swift` plus two call sites in `KalamApp.swift` and the existing `KalamTests/PasteServiceTests.swift` seam (`PasteStrategies` injectable closures + isolated named `NSPasteboard` — already in place from K-02, commit `4eb50a1`).

1. **K-08:** `PasteService.paste` tracks which strategy consumed the transcript (`PasteOutcome`). Only the **Cmd+V path** hands the pasteboard to the target app, so it alone keeps a short, configurable grace delay before the snapshot restore; the **AX path and the failure path restore immediately** (the target never read the pasteboard). The Cmd+V default grace shrinks 0.5 s → 0.15 s. The K-02 defer-restore and its guard (changeCount equality + string equality) are untouched.
2. **K-09:** `waitForPasteboardCommit` becomes `async` and polls with `Task.sleep` (same timeout/poll interval semantics, same parameter names), yielding the MainActor between polls. `paste(_:)` becomes `async throws`; the two `KalamApp` call sites drop their now-unneeded `MainActor.run` wrapper (the transcription task is already MainActor-inherited). Cancellation is preserved: a K-01 cancellation during the commit wait aborts the paste via `Task.checkCancellation()`, and the K-02 defer still restores the clipboard.

**Tech Stack:** Swift 6, AppKit (`NSPasteboard`, CGEvent, AXUIElement), XCTest (`KalamTests` target, module `Kalam_test`), Xcode 16 folder-synchronized groups (new files auto-join targets — no pbxproj edits).

## Global Constraints

- **Never log transcript text** — counts/status only with `privacy: .public` (repo rule, IMPROVEMENT_PLAN "What looks solid").
- **Do not weaken the clipboard-restore guard** (changeCount equality + string equality) — hard invariant in AGENTS.md. This plan only changes *when* the restore runs, never *whether it is safe*.
- **Do not change the CGEvent-unicode-first path.** Short transcripts (≤ 200 UTF-16 units) never touch the pasteboard today and must keep that property — K-08's exposure window only exists on the Cmd+V fallback path.
- **No new entitlements, no network code.**
- **No `Task.detached`** (repo concurrency posture). The async wait stays MainActor-isolated; `NSPasteboard` is not `Sendable` and never leaves the actor.
- **Concurrent-session rules (shared VirtIOFS):** `PasteService.swift` may carry sibling edits; re-check `git status` before editing, stage only your hunks (awk-extract + `git apply --cached` technique from the `kalam-app-development` skill — never `git add -A`).
- **Line numbers below were verified 2026-08-11** against the post-K-02 tree: `paste(_:)` ≈ `PasteService.swift:56–94` (defer at ~77, `waitForPasteboardCommit` call at ~70), `restoreClipboardIfNeeded` ≈ `:97–109` (asyncAfter at ~99), `writeAndTrackPasteboardState` ≈ `:111–121`, `waitForPasteboardCommit` ≈ `:123–138` (usleep loop ~130–136). Call sites: `KalamApp.swift:1049–1053` (initial paste) and `:1066–1070` (fallback paste). Re-locate before editing.
- **Test commands (from repo root):**
  - Targeted: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO`
  - Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Full suite: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Engine (unchanged by this plan, but run as a sanity gate): `./scripts/test-engine.sh`

---

## Current state (verified 2026-08-11)

`paste(_:)` flow today (post K-02):

```
guard isProcessTrusted()
→ postUnicodeText(text)? return        // pasteboard never touched
→ PasteboardSnapshot(pasteboard)       // snapshot of user's clipboard
→ writeAndTrackPasteboardState(...)    // transcript onto the pasteboard
→ _ = waitForPasteboardCommit(...)     // K-09: sync usleep loop, up to 150 ms, MainActor-blocking
→ defer { restoreClipboardIfNeeded(...) }   // K-02: unconditional from snapshot time
→ postCmdV()? return                   // target reads pasteboard during event processing
→ insertTextViaAccessibility(text)? return  // target never reads the pasteboard
→ throw PasteServiceError.pasteExecutionFailed
```

`restoreClipboardIfNeeded` runs `DispatchQueue.main.asyncAfter(.now() + strategies.restoreDelay)` (`restoreDelay = 0.5` default) with the guard. **All three post-snapshot outcomes wait the same 0.5 s**, so the transcript lingers up to ~0.5 s even on the AX-success and failure paths where no app ever read it.

`PasteStrategies` (K-02 seam, unchanged by this plan except the `restoreDelay` default and doc comment): `isProcessTrusted`, `postUnicodeText`, `postCmdV`, `insertTextViaAccessibility`, `pasteboard`, `restoreDelay: TimeInterval = 0.5`.

Callers of `paste(_:)`: exactly two, both in `KalamApp.swift` inside the actor-inherited transcription `Task` (`KalamApp.swift:1049–1053`, `:1066–1070`, each `try await MainActor.run { try self.paster.paste(postProcessed); self.overlay.showSuccessAndAutoHide() }`). `KalamTestRunner.swift` does not use `PasteService`. The K-01 cancellation path already catches `CancellationError` (`KalamApp.swift:1085`) — a cancellation thrown from `paste` is handled today.

---

## Decision & rejected alternatives (K-08)

**Chosen: per-outcome restore timing + shorter Cmd+V grace.** Add a private `PasteOutcome` enum set as `paste` progresses; the `defer`-scheduled restore reads it:

- `.cmdV` → keep a grace delay (`strategies.restoreDelay`, default **0.15 s**, down from 0.5) so the target app has time to read the pasteboard during/after Cmd+V event processing.
- `.accessibility` / `.failed` → **restore synchronously, delay 0**. Neither path ever handed the pasteboard to the target app, so a grace period is pure exposure.

This is the literal reading of the plan row's "shorten the window / restore sooner": 0 delay where the pasteboard was never consumed, 3.3× shorter where it was.

- **Rejected — "restore immediately on every path":** the Cmd+V key event is delivered asynchronously and some apps (browsers, async paste handlers) read the pasteboard after event dispatch. Zero grace risks empty pastes; 0.15 s is ~10× the typical synchronous read and matches the existing commit-wait timeout as a defensible upper bound.
- **Rejected — "wait until the target app has read the pasteboard":** `NSPasteboard` exposes no read notification; `changeCount` moves only on writes. Not implementable. The existing guard already covers the write case (user copies something new → skip restore, preserve the newer content).
- **Rejected — "keep 0.5 s everywhere":** leaves the documented exposure on the most common fallback path and does nothing for the AX/failure paths.

**Scope note:** the pasteboard path is only exercised when `postUnicodeText` fails (transcripts > 200 UTF-16 units, or unicode event posting failure). Short dictations go CGEvent-unicode and never touch the pasteboard — unchanged. The K-08 window is worst-case `waitForPasteboardCommit` (≤ 150 ms) + grace (0.15 s) ≈ 0.3 s, down from ≈ 0.65 s, and 0 on AX/failure.

## Decision & rejected alternatives (K-09)

**Chosen: `waitForPasteboardCommit` becomes `async`, polling with `Task.sleep`.** Same signature names (`timeoutSeconds: TimeInterval = 0.15`, `pollIntervalSeconds: TimeInterval = 0.005`), same early-return and timeout semantics; each poll cycle `try? await Task.sleep(...)` yields the MainActor, so the runloop (overlay animations, UI) keeps servicing between polls. `paste(_:)` becomes `async throws`; the KalamApp call sites call it directly (the transcription task is MainActor-inherited, so the `MainActor.run` wrapper is redundant — and the async-body `MainActor.run` overload is deprecated on macOS 15 SDK, so dropping it also avoids a deprecation warning).

- **Rejected — `DispatchSourceTimer` / `withCheckedContinuation`:** more machinery, manual cancellation plumbing, no benefit over `Task.sleep`, which is the Swift-6-idiomatic cooperative sleep and is automatically cancellation-aware.
- **Rejected — waiting off the MainActor (background task polling `NSPasteboard`):** `NSPasteboard` is not `Sendable`; `PasteService` is `@MainActor`. Moving the wait off-actor requires copying data out of the actor or unsafe `nonisolated(unsafe)` hacks — overkill for a bounded ≤ 150 ms wait whose only defect is blocking the main thread. Cooperative sleep on the actor fixes the defect with zero isolation changes.

---

## Task 1: K-08 — per-outcome restore timing + shorter Cmd+V grace

**Files:**
- Modify: `app/Kalam/Services/PasteService.swift`
- Modify: `app/KalamTests/PasteServiceTests.swift` (2 existing direct calls of `restoreClipboardIfNeeded` gain the `outcome:` parameter; 1 new RED test; 1 new pin test)

**Interfaces:**
- Produces: private `PasteOutcome` enum; `restoreClipboardIfNeeded(_:insertedState:outcome:)` (3-arg); `PasteStrategies.restoreDelay` default `0.5` → `0.15` (doc comment: "grace delay for the Cmd+V path only"). `paste(_:)` signature unchanged at this stage (still sync — the async migration is Task 2).
- Consumes: nothing new.

- [ ] **Step 1: Write the RED test — `testAccessibilityPathRestoresImmediately`**

Append to `PasteServiceTests.swift`:

```swift
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
```

Run the targeted suite; **expect RED** (`paste` returns with the transcript still on the pasteboard — restore is scheduled +0.3 s later).

- [ ] **Step 2: Implement per-outcome restore timing**

In `PasteService.swift`:

1. Add the private enum (above `paste(_:)`):

```swift
/// Which strategy consumed the transcript, deciding how long it may sit on
/// the pasteboard before the snapshot restore (K-08). Only the Cmd+V path
/// hands the pasteboard to the target app, so only it keeps a grace delay.
private enum PasteOutcome {
    case cmdV              // target app is expected to read the pasteboard
    case accessibility     // text delivered via AX — pasteboard never consumed
    case failed            // every strategy failed — nothing consumed it
}
```

2. Track the outcome in `paste(_:)` — the `defer` reads it at scope exit, so it is set before each `return`/`throw`:

```swift
    var outcome = PasteOutcome.failed
    defer { restoreClipboardIfNeeded(snapshot, insertedState: insertedState, outcome: outcome) }

    if strategies.postCmdV() {
        Self.logger.info("Paste succeeded via Cmd+V")
        outcome = .cmdV
        return
    }

    if let error = strategies.insertTextViaAccessibility(text) {
        Self.logger.warning("Paste failed after AX fallback: \(error, privacy: .public)")
        throw PasteServiceError.pasteExecutionFailed(reason: error)
    }

    Self.logger.info("Paste succeeded via Accessibility")
    outcome = .accessibility
```

3. Rework `restoreClipboardIfNeeded` to take the outcome and restore synchronously on non-CmdV paths:

```swift
    func restoreClipboardIfNeeded(
        _ snapshot: PasteboardSnapshot,
        insertedState: InsertedPasteboardState,
        outcome: PasteOutcome
    ) {
        // K-08: only the Cmd+V path hands the pasteboard to the target app, so
        // only it keeps a (short) grace delay for the app to read it. The AX
        // path and failures restore immediately — the transcript never needs to
        // linger. The changeCount + string-equality guard is unchanged.
        let delay: TimeInterval = outcome == .cmdV ? strategies.restoreDelay : 0

        let restore: @MainActor () -> Void = {
            let pasteboard = self.strategies.pasteboard
            guard pasteboard.changeCount == insertedState.changeCount,
                  pasteboard.string(forType: .string) == insertedState.text
            else {
                Self.logger.info("Clipboard restore skipped because pasteboard changed after Kalam write")
                return
            }
            snapshot.restore(to: pasteboard)
            Self.logger.info("Clipboard restored after paste")
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { restore() }
        } else {
            restore()
        }
    }
```

4. Change the `restoreDelay` default and its doc comment in `PasteStrategies`:

```swift
        /// Grace delay before restoring the user's clipboard after a Cmd+V
        /// paste, giving the target app time to read the pasteboard. Only the
        /// Cmd+V path uses this; AX/failure paths restore immediately (K-08).
        var restoreDelay: TimeInterval = 0.15
```

(The `DispatchQueue.main.asyncAfter { restore() }` closure pattern is unchanged from the current code and already compiles under Swift 6; if the compiler still asks, the explicit `@MainActor` annotation on `restore` resolves it.)

- [ ] **Step 3: Update the two existing direct calls**

In `PasteServiceTests.swift`, the two tests that call `restoreClipboardIfNeeded(snapshot, insertedState:)` directly gain the `outcome:` argument — use `.cmdV` (the delay path; both keep their injected `restoreDelay = 0.05` and existing runloop-pump polling):

- `testRestoreReturnsOriginalWhenPasteboardUnchanged` (~line 74): `service.restoreClipboardIfNeeded(snapshot, insertedState: inserted, outcome: .cmdV)`
- `testRestoreSkippedWhenUserCopiesNewContent` (~line 99): `service.restoreClipboardIfNeeded(snapshot, insertedState: inserted, outcome: .cmdV)`

The K-02 guard semantics they pin are unchanged — both must stay green.

- [ ] **Step 4: Add the pin test — `testCmdVPathHonorsGraceDelay`**

```swift
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
```

- [ ] **Step 5: Run the targeted suite, expect GREEN**

`xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO`

All 6 tests green (RED test now passes; both K-02 guard tests unchanged; pin test green).

- [ ] **Step 6: Commit**

```bash
cd /Volumes/My\ Shared\ Files/GitHub/Kalam
git status --short app/Kalam/Services/PasteService.swift app/KalamTests/PasteServiceTests.swift
# stage ONLY your hunks — never git add -A (shared repo)
git add -p app/Kalam/Services/PasteService.swift app/KalamTests/PasteServiceTests.swift
git commit -m "fix(K-08): restore clipboard immediately on AX/failure paths; shorten Cmd+V grace to 0.15s"
```

---

## Task 2: K-09 — cooperative pasteboard-commit polling (async migration)

**Files:**
- Modify: `app/Kalam/Services/PasteService.swift`
- Modify: `app/Kalam/KalamApp.swift` (2 call sites)
- Modify: `app/KalamTests/PasteServiceTests.swift` (1 existing test becomes async; 3 new tests)

**Interfaces:**
- Produces: `waitForPasteboardCommit(...) async -> Bool` (same parameter names/defaults); `paste(_ text: String) async throws` (was sync `throws`).
- Consumes: the two KalamApp call sites; `testFailurePathRestoresOriginalClipboard` (must await).

> **RED note:** the new tests are written against the async API, so they are a **compile-time RED** against the current sync code (a signature change cannot have a runtime-RED test on the old API). The runtime assertions inside them still guard the regression once the API lands.

- [ ] **Step 1: Write the new tests (compile-RED)**

Append to `PasteServiceTests.swift`:

```swift
/// K-09: the commit wait must yield the MainActor between polls. A
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
    let sentinelRan = expectation(description: "main-queue work ran during commit wait")
    DispatchQueue.main.async { sentinelRan.fulfill() }

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
    XCTAssertEqual(sentinelRan.fulfillmentCount, 1,
        "K-09: main-queue work must run during the wait (no usleep on the MainActor)")
}

/// K-09 pin: the wait still detects the pasteboard advancing mid-wait.
func testWaitForPasteboardCommitDetectsAdvanceDuringWait() async {
    let pasteboard = makeIsolatedPasteboard()
    pasteboard.clearContents()
    pasteboard.setString("stale", forType: .string)
    let service = PasteService(strategies: PasteService.PasteStrategies(pasteboard: pasteboard))

    let target = pasteboard.changeCount + 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        pasteboard.setString("committed-\(UUID().uuidString)", forType: .string)
    }

    let started = Date()
    let committed = await service.waitForPasteboardCommit(
        pasteboard: pasteboard, targetChangeCount: target,
        timeoutSeconds: 0.5, pollIntervalSeconds: 0.005)
    XCTAssertTrue(committed, "must observe the advance before the timeout")
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
}

/// K-01 × K-02 × K-09 interplay: canceling the surrounding task during the
/// commit wait aborts the paste (no Cmd+V, no AX) AND the defer still
/// restores the clipboard immediately.
func testPasteAbortsWhenCanceledDuringCommitWait() async throws {
    let pasteboard = makeIsolatedPasteboard()
    pasteboard.clearContents()
    let original = "original-\(UUID().uuidString)"
    pasteboard.setString(original, forType: .string)

    var strategies = PasteService.PasteStrategies()
    strategies.isProcessTrusted = { true }
    strategies.postUnicodeText = { _ in false }
    strategies.postCmdV = { _ in
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

    let task = Task { try await service.paste("transcript-\(UUID().uuidString)") }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()

    do {
        _ = try await task.value
        XCTFail("paste must throw CancellationError when canceled during the commit wait")
    } catch is CancellationError {
        // expected
    }

    XCTAssertEqual(pasteboard.string(forType: .string), original,
        "K-02: the defer restore must still fire after cancellation (immediate on the failure path)")
}
```

(Do not delete the file's doc comment — extend it: the class comment at the top should mention the K-08/K-09 coverage.)

- [ ] **Step 2: Make `waitForPasteboardCommit` and `paste(_:)` async**

In `PasteService.swift`, replace the sync loop:

```swift
    func waitForPasteboardCommit(
        pasteboard: NSPasteboard,
        targetChangeCount: Int,
        timeoutSeconds: TimeInterval = 0.15,
        pollIntervalSeconds: TimeInterval = 0.005
    ) async -> Bool {
        if targetChangeCount <= pasteboard.changeCount {
            return true
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // K-09: cooperative sleep — yields the MainActor between polls so
            // the UI and overlay animations never stall. Cancellation aborts
            // promptly; the caller decides what that means.
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            if Task.isCancelled { return false }
            if pasteboard.changeCount >= targetChangeCount {
                return true
            }
        }
        return false
    }
```

Then in `paste(_:)`:

1. `func paste(_ text: String) throws` → `func paste(_ text: String) async throws`
2. `_ = waitForPasteboardCommit(...)` → `_ = await waitForPasteboardCommit(...)`
3. Immediately after the wait, before the `defer` block:

```swift
        // K-09/K-01: the wait is cooperative, so a canceled transcription task
        // (new recording started) reaches this point — abort the paste; the
        // defer below still restores the clipboard (K-02).
        try Task.checkCancellation()
```

(The `defer { restoreClipboardIfNeeded(...) }` from Task 1 stays exactly where it is — after the cancellation check — so a canceled paste still restores with `outcome == .failed` → immediate.)

- [ ] **Step 3: Update the two KalamApp call sites**

Both call sites sit inside the actor-inherited transcription `Task` (MainActor-isolated — the comment at `KalamApp.swift:946–947` documents this), so the `MainActor.run` wrapper is redundant and the async-body overload is deprecated on macOS 15 SDK. Replace:

```swift
                do {
                    try await MainActor.run {
                        try self.paster.paste(postProcessed)
                        self.overlay.showSuccessAndAutoHide()
                    }
```

with:

```swift
                do {
                    try await self.paster.paste(postProcessed)
                    self.overlay.showSuccessAndAutoHide()
```

…and the same at the fallback site (`:1066–1070`). The surrounding `catch is CancellationError { return }` (`:1085`) already handles the new cancellation path. Do not touch the `await MainActor.run { self.overlay.showError(...) }` blocks in the catch paths (`:1079–1082`, `:1089–`) — those run sync bodies and stay valid.

- [ ] **Step 4: Update `testFailurePathRestoresOriginalClipboard` to async**

`PasteServiceTests.swift:16–44` — the only existing test calling `paste`. Change the signature to `func testFailurePathRestoresOriginalClipboard() async throws` and replace the `XCTAssertThrowsError(try service.paste(...))` block with:

```swift
        do {
            try await service.paste("transcript-\(UUID().uuidString)")
            XCTFail("paste must throw when every strategy fails")
        } catch PasteServiceError.pasteExecutionFailed {
            // expected — all three strategies failed
        }

        // K-02 + K-08: the failure path restores immediately (no grace delay),
        // so no runloop pumping is needed — assert directly.
        XCTAssertEqual(
            pasteboard.string(forType: .string), original,
            "K-02: the throw path must restore the original clipboard content"
        )
```

…and delete the now-unneeded 1-second poll loop (`:35–39`). Keep `strategies.restoreDelay = 0.05` or drop it — the failure path ignores it now.

- [ ] **Step 5: Build + targeted suite, expect GREEN**

```bash
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO
```

Expect `BUILD SUCCEEDED`, no new warnings, all PasteServiceTests green (4 old semantics tests + 4 new: `testAccessibilityPathRestoresImmediately`, `testCmdVPathHonorsGraceDelay`, `testWaitForPasteboardCommitYieldsMainThread`, `testWaitForPasteboardCommitDetectsAdvanceDuringWait`, `testPasteAbortsWhenCanceledDuringCommitWait`).

- [ ] **Step 6: Commit**

```bash
cd /Volumes/My\ Shared\ Files/GitHub/Kalam
git status --short app/Kalam/Services/PasteService.swift app/Kalam/KalamApp.swift app/KalamTests/PasteServiceTests.swift
# KalamApp.swift carries unrelated in-flight edits (onboarding etc.) — stage ONLY your hunks
git add -p app/Kalam/Services/PasteService.swift app/Kalam/KalamApp.swift app/KalamTests/PasteServiceTests.swift
git commit -m "perf(K-09): cooperative pasteboard-commit polling — no main-thread stall during paste"
```

---

## Task 3: Full verification, plan statuses, docs

- [ ] **Step 1: Full automated verification**

```bash
./scripts/test-engine.sh                                       # 32/32 — unchanged by this plan
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Full Xcode suite green (includes `PasteServiceTests`, `OnboardingFlowTests`, `FluidAudioOfflineModeTests`, `RealModelSmokeTests`-skippable behavior).

- [ ] **Step 2: Manual verification (🧑 human gate — the doc's K-08/K-09 verifies)**

1. **Pasteboard exposure (K-08):** enable Accessibility, pick a model, open TextEdit. Dictate a **long** transcript (> 200 UTF-16 units — short ones go CGEvent-unicode and never touch the pasteboard). In a Terminal, run a pasteboard poller in a loop (`while true; do pbpaste | head -c 60; echo; sleep 0.02; done`) while dictating. Confirm: the transcript appears on the pasteboard for at most ~150 ms after the Cmd+V paste, then the original clipboard content returns; end-to-end paste still works in TextEdit (transcript lands exactly once).
2. **Grace still works (K-08 pin):** repeat the long dictation into a browser text field or any app with an async paste handler; confirm the pasted text is complete (the 0.15 s grace wasn't too short). If an app pastes empty, bump `restoreDelay` (document the app + value in the PR) rather than reverting the per-outcome logic.
3. **No main-thread stall (K-09):** with a long transcript, `sample <Kalam pid> 2 -file /tmp/kalam-sample.txt` during the paste (or Instruments Time Profiler). Confirm no main-thread run longer than ~10 ms in the paste window; the overlay's waveform/animations must stay smooth while the commit wait runs. The automated `testWaitForPasteboardCommitYieldsMainThread` is the primary regression guard; this is the on-device confirmation.
4. **Cancellation smoke (K-01 interplay):** toggle mode — record a long segment, release, and tap-start a new recording before the paste fires. Confirm the old transcript is NOT pasted and the clipboard is restored (original content back).

- [ ] **Step 3: Flip statuses + note in IMPROVEMENT_PLAN.md**

In `app/docs/IMPROVEMENT_PLAN.md`:
- K-08 row: `⬜` → `🔄` (if not already flipped at plan authoring)
- K-09 row: `⬜` → `🔄`
- Add a note line after the K-05/K-06 note (line ~28), matching its format:
  `> **K-08 / K-09 (2026-08-11):** dev plan authored → app/docs/dev-design/2026-08-11-k08-k09-pasteboard-exposure-and-cooperative-polling.md. Statuses flipped to 🔄 pending execution.`
- Flip to `✅` only after Tasks 1–3 all pass, per the plan protocol.

- [ ] **Step 4: Commit the docs**

```bash
cd /Volumes/My\ Shared\ Files/GitHub/Kalam
git add app/docs/IMPROVEMENT_PLAN.md app/docs/dev-design/2026-08-11-k08-k09-pasteboard-exposure-and-cooperative-polling.md
git commit -m "docs(K-08/K-09): dev plan authored; statuses flipped to in-progress"
```

---

## Verification matrix

| # | Check | Command / action | Expect |
|---|---|---|---|
| 1 | K-08 RED | `-only-testing:KalamTests/PasteServiceTests` after Task 1 Step 1 | `testAccessibilityPathRestoresImmediately` fails (transcript still on pasteboard) |
| 2 | K-08 | targeted suite after Task 1 Step 5 | 6/6 green, incl. both K-02 guard tests |
| 3 | K-09 | targeted suite after Task 2 Step 5 | all 9 tests green; build succeeds, no new warnings |
| 4 | Engine sanity | `./scripts/test-engine.sh` | 32/32 green (unchanged) |
| 5 | Full suite | `xcodebuild test … CODE_SIGNING_ALLOWED=NO` | all green |
| 6 | K-08 manual | pbpaste poller during long dictation into TextEdit | exposure ≤ ~150 ms post-paste; original content returns; paste lands once |
| 7 | K-09 manual | `sample` during paste + overlay animation | no main-thread stall; animations smooth |
| 8 | K-01 interplay | toggle-mode restart during transcription | no stale paste; clipboard restored |
| 9 | Plan statuses | IMPROVEMENT_PLAN.md | K-08/K-09 `✅` only after 1–8 pass |

## What must NOT change (regression checklist)

- The unicode-first path (short transcripts never touch the pasteboard).
- The restore guard: `changeCount == insertedState.changeCount && string == insertedState.text`.
- The `effectiveChangeCount` quirk in `writeAndTrackPasteboardState` (protects against changeCount not advancing).
- K-02's defer semantics: restore scheduled unconditionally once the snapshot is taken — the new `outcome` only selects the delay.
- No transcript text in any log line; no new entitlements; no network code.
