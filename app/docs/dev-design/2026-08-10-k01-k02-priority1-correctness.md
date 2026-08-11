# K-01 & K-02 — Priority 1 Correctness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (or execute inline in this session) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Manual (🧑) verification steps must be performed by a human reviewer; an agent must NOT mark a task complete on self-report alone.**

**Goal:** Fix the two Priority‑1 correctness bugs from `docs/IMPROVEMENT_PLAN.md`: (K‑01) a new recording must cancel the in-flight transcription/paste from the previous session so stale text is never pasted, and (K‑02) the clipboard snapshot must be restored on *every* paste path so the user's clipboard is never left holding the transcript.

**Architecture:** Two surgical changes, both regression-tested. K‑01 gets a one-line cancellation at the top of `startRecording()` (the doc's fix) plus a small hardening layer: a `RecordingSessionTracker` generation counter that the transcription task checks immediately before dispatching a paste, so the "no stale paste" guarantee is a hard invariant rather than a cooperative-cancellation timing race. K‑02 restructures `PasteService.paste(_:)` to schedule the clipboard restore with `defer` the moment the transcript is written to the pasteboard, and introduces a small injectable `PasteStrategies` seam so the failure path is unit-testable headlessly (real CGEvents/AX calls are never executed in tests).

**Tech Stack:** Swift 6, AppKit (NSPasteboard, CGEvent, AXUIElement), XCTest (`KalamTests` target, module `Kalam_test`), Xcode 16 folder-synchronized groups (new files auto-join targets — no pbxproj edits), `scripts/test-engine.sh` for the engine package.

## Global Constraints

- **Never log transcript text.** All new logging must be counts/status with `privacy: .public` only (repo rule — see IMPROVEMENT_PLAN "What looks solid").
- **No new entitlements, no network code.** Sandbox + hardened runtime + library validation must remain untouched.
- **Preserve the clipboard-restore guard semantics** (changeCount equality + string equality) on success paths — do not weaken it.
- **Dirty tree:** the engine-extraction refactor is uncommitted in this shared VirtIOFS repo (e.g. `app/Kalam/KalamApp.swift` already has unstaged changes). Never `git add -A`. When committing a file that carries unrelated in-flight edits (`KalamApp.swift`), stage only your hunks with `git add -p`. Re-check `git status` before every commit (concurrent sessions may commit in between).
- **Line numbers:** verified against the current tree on 2026-08-10: `startRecording` = `KalamApp.swift:855–913`, `stopRecordingAndTranscribe` = `:915–1080`, `cancelRecording` = `:1082–1104`, `transcriptionTask` decl = `:123`, `PasteService.paste` = `PasteService.swift:53–83`. Re-locate if they drift.
- **Test commands (run from repo root `/Volumes/My Shared Files/GitHub/Kalam`):**
  - Engine: `./scripts/test-engine.sh`
  - Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Single test class: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO`
  - Full suite: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- **New files** go in `app/Kalam/` (app code) or `app/KalamTests/` (tests) — folder-synchronized groups pick them up automatically.
- **Status rule:** flip `K-01`/`K-02` to `✅` in `docs/IMPROVEMENT_PLAN.md` only after implementation AND every verification step (automated + manual) passes.

---

### Task 1: K-01 core fix — cancel the in-flight task when a new recording starts

**Objective:** A new `startRecording` aborts the previous session's transcription/paste task so stale text can never land after a new recording begins.

**Files:**
- Modify: `app/Kalam/KalamApp.swift:855–857` (`startRecording(triggerMode:)`)

**Context:** `transcriptionTask` (`Task<Void, Never>?`, `KalamApp.swift:123`) is canceled in `stopRecordingAndTranscribe()` (`:934`) and `cancelRecording()` (`:1095`) but never in `startRecording()` (`:855–913`). The task body cooperatively checks `Task.isCancelled` at `:940`, `:968`, `:998`, `:1032` and `Task.sleep` at `:1031`/`:1048` throws `CancellationError` (caught `:1071`) — so canceling the task at start prevents every paste dispatch that would fire after the new recording begins.

- [ ] **Step 1: Add the cancel as the first statement of `startRecording`**

In `app/Kalam/KalamApp.swift`, change:

```swift
    @discardableResult
    private func startRecording(triggerMode: RecordingTriggerMode) -> Bool {
        guard !isRecording else { return false }
```

to:

```swift
    @discardableResult
    private func startRecording(triggerMode: RecordingTriggerMode) -> Bool {
        // K-01: a new recording supersedes any in-flight transcription/paste from
        // the previous session — abort it so stale text is never pasted.
        transcriptionTask?.cancel()
        guard !isRecording else { return false }
```

(Canceling when `transcriptionTask` is nil or already complete is a no-op; canceling a mid-recording start attempt's stale task is exactly what we want.)

- [ ] **Step 2: Build**

Run: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: `BUILD SUCCEEDED`, no new warnings.

- [ ] **Step 3: Manual verification (🧑 human gate — the doc's K-01 verify)**

1. Enable toggle mode; ensure Accessibility is trusted and the ASR model is ready.
2. Open TextEdit, place the cursor. Copy a sentinel string (`SENTINEL-1`) to the clipboard first.
3. Record a **long** segment A (several sentences — long ASR time widens the race window), release. Overlay shows "Transcribing".
4. **Immediately tap-start recording B** (before A's paste fires). Record a short phrase, stop.
5. Wait ~3 s. Confirm: **only B's text appears, exactly once** — A's text is never pasted, there is no double paste, and the overlay never shows success for A.

Expected with the fix: B's text only. (Without the fix: A's stale text can paste after B begins.)

- [ ] **Step 4: Commit**

```bash
cd /Volumes/My Shared Files/GitHub/Kalam
git status --short app/Kalam/KalamApp.swift
# KalamApp.swift carries unrelated in-flight refactor edits — stage ONLY your hunk:
git add -p app/Kalam/KalamApp.swift   # select the startRecording hunk only
git commit -m "fix: cancel in-flight transcription when a new recording starts (K-01)"
```

---

### Task 2: K-01 hardening — recording-generation gate + regression test

**Objective:** Make "no stale paste" a hard invariant: the transcription task records which recording it belongs to and refuses to paste if a newer recording has started — and pin that invariant with a unit test (K-14 coverage for K-01).

**Files:**
- Create: `app/Kalam/RecordingSessionTracker.swift`
- Create: `app/KalamTests/RecordingSessionTrackerTests.swift`
- Modify: `app/Kalam/KalamApp.swift` (property ~`:123`; increment in `startRecording` before `:890`; capture in `stopRecordingAndTranscribe` ~`:931–938`; gate after `:1032`)

- [ ] **Step 1: Write the failing test**

Create `app/KalamTests/RecordingSessionTrackerTests.swift`:

```swift
import XCTest
@testable import Kalam_test

final class RecordingSessionTrackerTests: XCTestCase {
    func testBeginNewRecordingAdvancesGeneration() {
        var tracker = RecordingSessionTracker()
        let first = tracker.beginNewRecording()
        XCTAssertEqual(first, 1)
        XCTAssertTrue(tracker.isCurrent(first))

        let second = tracker.beginNewRecording()
        XCTAssertEqual(second, 2)
        XCTAssertFalse(
            tracker.isCurrent(first),
            "K-01: a superseded recording's generation must no longer be current"
        )
        XCTAssertTrue(tracker.isCurrent(second))
    }

    func testCurrentGenerationReturnsLatest() {
        var tracker = RecordingSessionTracker()
        _ = tracker.beginNewRecording()
        _ = tracker.beginNewRecording()
        XCTAssertEqual(tracker.currentGeneration(), 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/RecordingSessionTrackerTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "cannot find 'RecordingSessionTracker' in scope".

- [ ] **Step 3: Create the tracker**

Create `app/Kalam/RecordingSessionTracker.swift`:

```swift
import Foundation

/// Monotonically increasing session counter for dictation recordings.
///
/// Each successful `startRecording` advances the counter and the in-flight
/// transcription task captures the generation of the recording it belongs to.
/// Immediately before dispatching a paste the task asks `isCurrent(_:)`; if a
/// newer recording has started, the old task is stale and must not paste (K-01).
struct RecordingSessionTracker {
    private var current = 0

    /// Starts a new dictation session, returning its generation.
    @discardableResult
    mutating func beginNewRecording() -> Int {
        current += 1
        return current
    }

    /// The generation of the latest dictation session.
    func currentGeneration() -> Int {
        current
    }

    /// True if `generation` belongs to the latest dictation session.
    func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}
```

- [ ] **Step 4: Wire it into `AppDelegate`**

In `app/Kalam/KalamApp.swift`:

4a. Add the property right after the `transcriptionTask` declaration (`:123`):

```swift
    private var transcriptionTask: Task<Void, Never>?
    private var recordingSessions = RecordingSessionTracker()
```

4b. In `startRecording(triggerMode:)`, right before `isRecording = true` (`:890`), advance the session:

```swift
        _ = recordingSessions.beginNewRecording()
        isRecording = true
        recordingTriggerMode = triggerMode
```

4c. In `stopRecordingAndTranscribe()`, capture the generation before creating the task (near `:931–938`):

```swift
        let pttDown = self.pttDownTime
        let pttUp = self.pttUpTime
        let generation = recordingSessions.currentGeneration()

        transcriptionTask?.cancel()

        // Run as an actor-inherited task instead of Task.detached so Swift 6 does not
        // send MainActor app state into an unisolated closure. Add post-roll to preserve trailing phonemes.
        transcriptionTask = Task(priority: .userInitiated) { [weak self, pttDown, pttUp, generation] in
```

4d. Add the gate right after the cancellation check that follows the paste-wait sleep (`:1032`):

```swift
                try await Task.sleep(nanoseconds: UInt64(pasteDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard self.recordingSessions.isCurrent(generation) else {
                    self.logger.info("Paste suppressed: recording superseded by a newer session")
                    return
                }
                stageMark("paste-wait")
```

(The task body is actor-inherited, so reading `self.recordingSessions` is MainActor-safe. The paste-fallback path is covered by the existing `Task.isCancelled` check at `:1049`; a single gate at the first dispatch is sufficient.)

- [ ] **Step 5: Run tests — verify they pass**

Run: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/RecordingSessionTrackerTests CODE_SIGNING_ALLOWED=NO`
Expected: 2 passed.

- [ ] **Step 6: Regression + build**

Run: `./scripts/test-engine.sh` (from repo root) — Expected: 32/32 green.
Run: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Manual verification (🧑 human gate)**

Repeat Task 1 Step 3 (toggle-mode double-start scenario). Additionally, verify normal single-shot dictation still pastes exactly once.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/My Shared Files/GitHub/Kalam
git add app/Kalam/RecordingSessionTracker.swift app/KalamTests/RecordingSessionTrackerTests.swift
git add -p app/Kalam/KalamApp.swift   # select ONLY the Task 2 hunks (property, beginNewRecording, generation capture, gate)
git commit -m "fix: gate paste on recording generation so stale transcripts never land (K-01)"
```

---

### Task 3: K-02 test seams — injectable strategies + isolated pasteboard (no behavior change)

**Objective:** Make `PasteService`'s failure path unit-testable headlessly. Real CGEvent/AX calls must never run in tests, so the three posting strategies, the AX-trust check, the pasteboard, and the restore delay become injectable with production defaults. Behavior is identical when constructed normally.

**Files:**
- Modify: `app/Kalam/Services/PasteService.swift`

- [ ] **Step 1: Add the `PasteStrategies` seam and make helpers static**

In `app/Kalam/Services/PasteService.swift`:

1a. Add inside `PasteService`, before `init`-less properties (after `private let logger`):

```swift
    /// Injectable behavior for paste strategies. Production defaults are the real
    /// CGEvent/AX implementations; tests inject fakes so no real keystrokes or
    /// accessibility calls are ever posted (K-02 regression coverage).
    struct PasteStrategies {
        var isProcessTrusted: () -> Bool = { AXIsProcessTrusted() }
        var postUnicodeText: (String) -> Bool = { PasteService.postUnicodeTextIfPossible($0) }
        var postCmdV: () -> Bool = { PasteService.postCmdV() }
        var insertTextViaAccessibility: (String) -> String? = { PasteService.insertTextViaAccessibility($0) }
        var pasteboard: NSPasteboard = .general
        var restoreDelay: TimeInterval = 0.5
    }

    private let strategies: PasteStrategies
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "PasteService")

    init(strategies: PasteStrategies = PasteStrategies()) {
        self.strategies = strategies
    }
```

1b. Change the instance `private let logger` (line 22) to be removed (replaced by the static one above), and update the two existing `logger` references inside `postCmdV` (`:140`) and `postUnicodeTextIfPossible` (`:160`, `:167`) to `Self.logger`.

1c. Make the three posting helpers static (they hold no instance state; `AccessibilityFocusResolver.resolveFocusedElement` is already static):

- `private func postCmdV() -> Bool` → `private static func postCmdV() -> Bool`
- `private func postUnicodeTextIfPossible(_ text: String) -> Bool` → `private static func postUnicodeTextIfPossible(_ text: String) -> Bool`
- `private func insertTextViaAccessibility(_ text: String) -> String?` → `private static func insertTextViaAccessibility(_ text: String) -> String?`

1d. Thread the pasteboard through the restore/wait helpers and drop `private` from the test-visible members:

- `private struct PasteboardSnapshot` → `struct PasteboardSnapshot` (init and `restore(to:)` are already internal)
- `private struct InsertedPasteboardState` → `struct InsertedPasteboardState`
- `private func restoreClipboardIfNeeded(...)` → `func restoreClipboardIfNeeded(...)`, body change:

```swift
    func restoreClipboardIfNeeded(_ snapshot: PasteboardSnapshot, insertedState: InsertedPasteboardState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + strategies.restoreDelay) {
            let pasteboard = strategies.pasteboard
            guard pasteboard.changeCount == insertedState.changeCount,
                  pasteboard.string(forType: .string) == insertedState.text
            else {
                Self.logger.info("Clipboard restore skipped because pasteboard changed after Kalam write")
                return
            }
            snapshot.restore(to: pasteboard)
            Self.logger.info("Clipboard restored after paste")
        }
    }
```

- `private func waitForPasteboardCommit(targetChangeCount:timeoutSeconds:pollIntervalSeconds:)` → `func waitForPasteboardCommit(targetChangeCount:timeoutSeconds:pollIntervalSeconds:)`, and replace both `NSPasteboard.general` reads (`:118`, `:123`) with `strategies.pasteboard` (or add a `pasteboard: NSPasteboard` parameter and pass `strategies.pasteboard` from `paste(_:)` — either is fine; parameter version keeps it explicit).

- [ ] **Step 2: Build**

Run: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/My Shared Files/GitHub/Kalam
git status --short app/Kalam/Services/PasteService.swift   # must be clean except your edits
git add app/Kalam/Services/PasteService.swift
git commit -m "refactor: add injectable paste strategies for testability (K-02)"
```

---

### Task 4: K-02 regression tests — write the failing test first (RED)

**Objective:** Prove K-02 with tests. The wiring test (`testFailurePathRestoresOriginalClipboard`) reproduces the exact bug — it must FAIL on current code — and three tests pin the restore machinery and its safety guard.

**Files:**
- Create: `app/KalamTests/PasteServiceTests.swift`

- [ ] **Step 1: Write the tests**

Create `app/KalamTests/PasteServiceTests.swift`:

```swift
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
        NSPasteboard(name: "KalamPasteTests.\(UUID().uuidString)")!
    }

    func testFailurePathRestoresOriginalClipboard() throws {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        let original = "original-\(UUID().uuidString)"
        pasteboard.setString(original, forType: .string)

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { false }                                  // Cmd+V fails
        strategies.insertTextViaAccessibility = { _ in "forced failure" } // AX insert fails
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0.05
        let service = PasteService(strategies: strategies)

        XCTAssertThrowsError(try service.paste("transcript-\(UUID().uuidString)"))

        // The defer-scheduled restore runs ~restoreDelay later; poll briefly.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            usleep(10_000)
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

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

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
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        let service = PasteService(strategies: PasteService.PasteStrategies(
            pasteboard: pasteboard, restoreDelay: 0.05))
        let inserted = service.writeAndTrackPasteboardState(pasteboard: pasteboard, text: "transcript-\(UUID().uuidString)")
        XCTAssertTrue(pasteboard.string(forType: .string)?.hasPrefix("transcript-") == true)

        service.restoreClipboardIfNeeded(snapshot, insertedState: inserted)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == original { break }
            usleep(10_000)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testRestoreSkippedWhenUserCopiesNewContent() {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

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
            usleep(10_000)
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string), userCopy,
            "guard must preserve the user's own new copy over the stale restore"
        )
    }
}
```

> Note: `PasteStrategies`'s memberwise initializer is synthesized with defaults in declaration order, so `PasteStrategies(pasteboard:restoreDelay:)` works only because the earlier properties have defaults. If the compiler complains, construct with all six members or use `var s = PasteService.PasteStrategies(); s.pasteboard = ...` (as in the first test).

- [ ] **Step 2: Run tests — verify the wiring test FAILS**

Run: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO`

Expected: `testFailurePathRestoresOriginalClipboard` **FAILS** ("K-02: the throw path must restore the original clipboard content" — transcript is still on the pasteboard) and the other three tests PASS. This failing test is the reproduction of K-02; do not commit until Task 5 turns it green.

---

### Task 5: K-02 core fix — unconditional clipboard restore (GREEN)

**Objective:** Once the transcript is written to the pasteboard, schedule the restore on every exit path (`defer`), closing the throw path that currently leaks the transcript onto the user's clipboard.

**Files:**
- Modify: `app/Kalam/Services/PasteService.swift:53–83` (`paste(_:)`)

- [ ] **Step 1: Apply the defer-style fix**

Change `paste(_:)` from (current):

```swift
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let insertedPasteboardState = writeAndTrackPasteboardState(pasteboard: pasteboard, text: text)
        _ = waitForPasteboardCommit(targetChangeCount: insertedPasteboardState.changeCount)

        if postCmdV() {
            logger.info("Paste succeeded via Cmd+V")
            restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState)
            return
        }

        if let error = insertTextViaAccessibility(text) {
            logger.warning("Paste failed after AX fallback: \(error, privacy: .public)")
            throw PasteServiceError.pasteExecutionFailed(reason: error)
        }

        logger.info("Paste succeeded via Accessibility")
        restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState)
```

to:

```swift
        let pasteboard = strategies.pasteboard
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let insertedPasteboardState = writeAndTrackPasteboardState(pasteboard: pasteboard, text: text)
        _ = waitForPasteboardCommit(targetChangeCount: insertedPasteboardState.changeCount)

        // K-02: the transcript now sits on the user's pasteboard. Restoring the
        // original clipboard content is unconditional from this point — every exit
        // path (Cmd+V success, AX insert success, or any failure) schedules the
        // restore. Previously the throw path left the transcript on the clipboard.
        defer { restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState) }

        if strategies.postCmdV() {
            Self.logger.info("Paste succeeded via Cmd+V")
            return
        }

        if let error = strategies.insertTextViaAccessibility(text) {
            Self.logger.warning("Paste failed after AX fallback: \(error, privacy: .public)")
            throw PasteServiceError.pasteExecutionFailed(reason: error)
        }

        Self.logger.info("Paste succeeded via Accessibility")
```

Also update the `AXIsProcessTrusted()` guard and the unicode path at the top of `paste(_:)` to use the strategies (`strategies.isProcessTrusted()`, `strategies.postUnicodeText(text)`).

The restore guard (`restoreClipboardIfNeeded`) still protects the user: if they copy something new within the restore window, the changeCount/string check skips the restore.

- [ ] **Step 2: Run the new tests — verify all pass**

Run: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/PasteServiceTests CODE_SIGNING_ALLOWED=NO`
Expected: 4 passed (including the previously failing wiring test).

- [ ] **Step 3: Regression + build**

Run: `./scripts/test-engine.sh` — Expected: 32/32 green.
Run: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual verification of the failure path (🧑 human gate)**

1. With the app built from this branch, temporarily force the Cmd+V strategy to fail: in `PasteService.swift` change the `postCmdV` default to `var postCmdV: () -> Bool = { false }` (one line; **revert immediately after this test**).
2. Ensure Accessibility is trusted and the ASR model is ready. Copy a sentinel string to the clipboard.
3. Focus an app with no text insertion point (e.g. Finder desktop), dictate a short phrase, wait for the error overlay ("Enable Accessibility to paste").
4. After ~1 s check the clipboard: **the sentinel must be back** (original content restored; transcript cleared). Also confirm the transcript text does not appear in the pasteboard's items.
5. Revert the temporary `postCmdV` change and rebuild.

(With the pre-fix code, step 4 leaves the transcript on the clipboard indefinitely — this is the K-02 data-leak scenario.)

- [ ] **Step 5: Commit**

```bash
cd /Volumes/My Shared Files/GitHub/Kalam
git add app/Kalam/Services/PasteService.swift app/KalamTests/PasteServiceTests.swift
git commit -m "fix: restore clipboard on every paste path, incl. failures (K-02)"
```

---

### Task 6: Full verification + status update

**Objective:** Run the complete gate and mark K-01/K-02 done in the improvement plan only when everything is verified.

- [ ] **Step 1: Full automated suite**

Run: `./scripts/test-engine.sh` — Expected: 32/32 green.
Run: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — Expected: full suite passes, including `KalamTests/PasteServiceTests` and `KalamTests/RecordingSessionTrackerTests`.

- [ ] **Step 2: Manual verification pass (🧑 human gate — both items)**

- K-01: repeat Task 1 Step 3 toggle-mode scenario + one normal single-shot dictation (pastes exactly once).
- K-02: repeat Task 5 Step 4 forced-failure scenario; also verify the normal success path restores the clipboard ~0.5 s after a real paste.

- [ ] **Step 3: Update `docs/IMPROVEMENT_PLAN.md`**

Flip `K-01` and `K-02` status from `⬜` to `✅` in the Priority 1 table. Leave `K-03`–`K-21` untouched.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/My Shared Files/GitHub/Kalam
git status --short   # confirm only intended files are modified
git add app/docs/IMPROVEMENT_PLAN.md
git commit -m "docs: mark K-01, K-02 verified (priority 1 correctness fixes)"
```

(If `app/docs/IMPROVEMENT_PLAN.md` is still untracked, confirm with the user whether it should be committed or kept local before adding it.)

---

## Risks, trade-offs & open questions

- **Cooperative cancellation is timing-dependent; the generation gate is the hard guarantee.** The one-line cancel (Task 1) relies on the task body's `Task.isCancelled` checkpoints. The gate (Task 2) makes "no paste after a new recording" an invariant checked immediately before dispatch, independent of cancellation timing. The microscopic window between the gate check and the synchronous paste dispatch is inherent to cooperative cancellation and identical to the pre-existing cancel-check window; it is not practically reachable via UI timing (paste delay is ≥20 ms).
- **`postCmdV()` returns `true` after posting events even if the target app ignores Cmd+V** — so today the K-02 throw path is reached mainly when CGEvent creation fails. The fix makes the restore unconditional regardless, which is the structural fix the doc asks for. The related "restore sooner once change-count confirms" idea is K-08 (Priority 3) — the new `strategies.restoreDelay` seam is where that tweak will land.
- **`PasteService` gains a static logger and static posting helpers.** Verified stateless today; the DI seam is deliberately minimal (no protocols, no subclassing).
- **Tests use an isolated named `NSPasteboard`** — the user's real clipboard is never touched by the suite. The polling loops cap at 1 s; a busy CI host could in theory delay the asyncAfter past the deadline — if flaky, raise the poll deadline to 2 s.
- **Dirty shared tree:** `KalamApp.swift` carries the in-flight engine-extraction refactor. Every commit touching it must use `git add -p`. If the refactor gets committed by a concurrent session mid-task, re-verify line numbers and re-run `git status` before each commit.
- **Out of scope:** K-03…K-21 (architecture, security, CI, hygiene). K-08/K-09/K-14 are related but tracked separately in the plan doc.
