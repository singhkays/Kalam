# K-12 Implementation Plan — Clean App Relaunch Lifecycle (`NSWorkspace` + orderly termination)

> **For agentic workers:** execute task-by-task; checkboxes track progress. Read `app/docs/IMPROVEMENT_PLAN.md` protocol first (status legend, claim → verify → ✅). Re-verify every line number and re-read each file right before editing — the shared-repo tree drifts (sibling sessions commit on the same `main`; `KalamApp.swift`/`OnboardingFlow.swift`/`OnboardingFlowTests.swift` had uncommitted sibling hunks at plan time). Run all commands from the repo root `/Volumes/My Shared Files/GitHub/Kalam`. Do not `git add -A`; stage only your hunks. `error: fsmonitor_ipc__send_query …` on commit is cosmetic on this mount.

**Goal:** Replace `AppRelauncher`'s `open -n` + unconditional `exit(0)` with a sandbox-sanctioned `NSWorkspace.openApplication` launch that terminates the current instance orderly (`NSApp.terminate` → `applicationWillTerminate` runs) and **only after the new instance's launch succeeded** — a failed launch must keep the app alive and log, never leave the user with no app.

**Architecture:** `AppRelauncher` gains an injectable `Strategy` seam (two `@Sendable` closures: `launchNewInstance` / `terminate`; same testable-seam pattern as `PasteService.PasteStrategies` from K-02) so the orchestration is unit-testable headlessly with no real processes. The live strategy uses `NSWorkspace.shared.openApplication(at:configuration:)` with `createsNewApplicationInstance = true` (mirrors `open -n`; semantically REQUIRED — without it LaunchServices re-activates the still-running current instance and the relaunch becomes a plain quit) and terminates via `NSApp.terminate(nil)` on the main thread, gated on launch success. `SMAppService` is evaluated and rejected (login-item/agent registration API — not a relaunch API; see Decision).

**Tech Stack:** Swift 6, AppKit (`NSWorkspace.OpenConfiguration` — macOS 10.15+, deployment target 14.6 ✓; `NSApp`), `OSLog` (`Logger` — replaces the K-16 `print()`), XCTest (`KalamTests`, module `Kalam_test`), Xcode folder-synchronized groups (new test file auto-joins the test target — no pbxproj edits).

## Global Constraints

- **Never log transcript or audio content** — the relaunch error string is an OS-provided error description, not user content; log with `privacy: .public` (matches `AudioCaptureExchange`/`PasteService` conventions).
- **No new entitlements, no network code, no `Task.detached`** — `NSWorkspace.openApplication` is the sandbox-sanctioned launch API (the old `/usr/bin/open` `Process` hop is a removal, not a replacement requirement).
- **Keep the fresh-instance semantics** — `createsNewApplicationInstance = true` is a hard requirement, not a cosmetic flag (see Goal/Architecture). Comment it in code; do not remove.
- **`relaunch()` stays source-compatible** — `KalamApp.swift:454–456` (`relaunchAppAction: { AppRelauncher.relaunch() }`) and `OnboardingFlow.swift:440–442` (`relaunchApp()` → `relaunchAppAction()`) must compile unchanged; the strategy becomes a defaulted parameter.
- **Orderly termination is the point of the fix** — `NSApp.terminate(nil)` runs `AppDelegate.applicationWillTerminate` (`KalamApp.swift:275`: cancels `transcriptionTask`, removes all observers). `exit(0)` skipped all of it.
- **Tree stays buildable at every commit** — unlike K-10's intentionally-red commits, the K-12 RED is a *compile* failure (tests reference `AppRelauncher.Strategy`, which doesn't exist yet) that would break the whole test target for sibling sessions on the shared repo; the documented K-09 precedent covers this ("document that in the plan rather than forcing a runtime RED"). Tests + implementation therefore commit together in Task 2.
- **Concurrent-session rules (shared VirtIOFS):** `AppRelauncher.swift` is clean at plan time (2026-08-11) but re-check `git status` before editing; `IMPROVEMENT_PLAN.md` must be re-read before adding notes (a sibling may have inserted one).
- **Line numbers below were verified 2026-08-11** against the current tree (`git log -1` HEAD = `00518cd`). Re-locate before editing.
- **Test commands (from repo root):**
  - Targeted new tests: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AppRelauncherTests CODE_SIGNING_ALLOWED=NO`
  - Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Full suite: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Engine sanity (unchanged by this plan): `./scripts/test-engine.sh` (expect 41 green)

---

## Current state (verified 2026-08-11)

`app/Kalam/AppRelauncher.swift` (19 lines, entire file):

```swift
import Foundation

enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
        } catch {
            print("Failed to relaunch app automatically: \(error.localizedDescription)")
        }

        exit(0)
    }
}
```

Two defects (the K-12 finding's substance):

1. **`exit(0)` runs unconditionally** — it sits *outside* the `do/catch`. If the new instance fails to launch, the app still quits: the user is left with no app, no UI, and only a `print()` in the logs. There is no retry path.
2. **`exit(0)` skips the orderly termination lifecycle** — `NSApp.terminate` → `applicationWillTerminate` (`KalamApp.swift:275`) cancels the in-flight `transcriptionTask` and removes every `NotificationCenter` observer. `exit(0)` bypasses all of it.
3. (Hygiene, overlaps K-16) The failure path is a raw `print()` — the K-16 row lists `AppRelauncher.swift:14` as one of its 14 `print()` sites.

**Call path (single UI trigger):** `KalamApp.swift:454–456` passes `relaunchAppAction: { AppRelauncher.relaunch() }` into `OnboardingFlowController`. The controller's `relaunchApp()` (`OnboardingFlow.swift:440–442`) is invoked only by the Accessibility step's **"Quit & Reopen Kalam"** button (`OnboardingFlow.swift:860`, rendered when `accessibilitySetupState == .enabledPendingRelaunch`, set at `:437` when the user confirms AX enablement but `AXIsProcessTrusted()` still fails). After relaunch, the fresh process is AX-trusted and onboarding resumes with the step green.

**Test surface:** `KalamTests` has zero references to `AppRelauncher` (verified 2026-08-11). `OnboardingFlowTests.swift:255` passes `relaunchAppAction: {}` — unaffected by this plan (source-compatible). The new seam is safe.

**Docs:** `app/docs/DEVELOPER_GUIDE.md` has no `AppRelauncher`/`relaunch` mention (rg-verified). Repo-root `AGENTS.md:39` describes it as "`AppRelauncher` — `open -n` relaunch (K-12 candidate)" — updated in Task 3.

## Decision & rejected alternatives

**Chosen: `NSWorkspace.openApplication(at:configuration:)` + gated `NSApp.terminate(nil)`, behind an injectable `Strategy` seam.**

- `NSWorkspace.openApplication` is the sanctioned, sandbox-compatible LaunchServices API — no `/usr/bin/open` `Process` hop, and it hands back a completion callback, which is what makes "terminate only on success" possible. `config.createsNewApplicationInstance = true` preserves the old `open -n` fresh-instance semantics.
- `NSApp.terminate(nil)` runs the real termination lifecycle (`applicationWillTerminate`) — the substantive "cleaner lifecycle" the K-12 finding asks for.
- The `Strategy` seam makes the orchestration headlessly testable (K-02 precedent: `PasteService.PasteStrategies`), which the relaunch itself can never be (it spawns processes).
- Failure behavior flips from "app disappears" to "log + stay alive, user can retry the button" — the correctness fix.

**Rejected — `SMAppService` (named in the K-12 finding):** `SMAppService` (macOS 13+) registers the app as a *login item / background agent* (`SMAppService.mainApp` / `SMAppService.agent(plistName:)`). It is not a relaunch mechanism; using it here would either do nothing relevant or register launch-at-login behavior the app doesn't want. Rejected with rationale recorded (the finding's "consider SMAppService/NSWorkspace" is resolved in favor of NSWorkspace alone).

**Rejected — keep `open -n` + `exit(0)`, just add a Logger:** preserves both defects (unconditional exit, skipped lifecycle); `Process`+`/usr/bin/open` gives no reliable completion signal, so "terminate only on success" is not achievable on that shape.

**Rejected — `NSWorkspace.shared.launchApplication(_:options:)`:** older API, no completion callback, and the modern replacement is `openApplication(at:configuration:)` — no reason to use the deprecated-shaped path.

**Rejected — async `relaunch()` (`async`/`await` + `withCheckedContinuation`):** would ripple the `() -> Void` `relaunchAppAction` type through `OnboardingFlowController` (`OnboardingFlow.swift:358,377,394,441`) and its test host (`OnboardingFlowTests.swift:255`) for no behavioral gain; the completion-callback shape stays sync at the seam.

**Rejected — `DispatchSemaphore` wait inside `relaunch()`:** the NSWorkspace completion thread is not documented as main; blocking the calling (main) thread on a callback that may itself be delivered on main risks a guaranteed-timeout stall. The callback shape with a `DispatchQueue.main.async` hop before `terminate()` is safe under both delivery models.

---

## Task 1: Write the relaunch orchestration tests (RED — documented compile failure)

**Files:**
- Create: `app/KalamTests/AppRelauncherTests.swift`

**Interfaces:**
- Consumes (does not exist yet — this is the RED): `AppRelauncher.Strategy` (struct with `launchNewInstance: @Sendable (URL, @escaping @Sendable (NSError?) -> Void) -> Void` and `terminate: @Sendable () -> Void`) and `AppRelauncher.relaunch(strategy: Strategy = .live)`. Task 2 defines them exactly.
- Produces: `AppRelauncherTests` (3 tests) pinning the orchestration contract.

- [ ] **Step 1: Create `app/KalamTests/AppRelauncherTests.swift`** (folder-synced group → auto-joins the test target)

```swift
import XCTest
@testable import Kalam_test

/// K-12 regression pins for the relaunch orchestration.
///
/// The pre-K-12 code (`open -n` + unconditional `exit(0)`) had two defects
/// this suite pins against:
/// 1. `exit(0)` ran even when launching the new instance FAILED — the app
///    disappeared with no way to retry.
/// 2. `exit(0)` skipped the orderly termination lifecycle
///    (`applicationWillTerminate`: transcription-task cancellation, observer
///    removal) that `NSApp.terminate` runs.
///
/// The tests drive `AppRelauncher.relaunch(strategy:)` with injected fake
/// launch/terminate closures (same testable-seam pattern as
/// `PasteService.PasteStrategies`, K-02) — no real processes are spawned.
@MainActor
final class AppRelauncherTests: XCTestCase {

    func testRelaunchTerminatesAfterSuccessfulLaunch() {
        let terminated = expectation(description: "terminate called")
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { _, completion in completion(nil) },
            terminate: { terminated.fulfill() }
        )

        AppRelauncher.relaunch(strategy: strategy)

        // `relaunch` hops to the main queue before terminating; XCTest's
        // `wait(for:)` pumps the main runloop, so the hop executes here.
        wait(for: [terminated], timeout: 2)
    }

    func testRelaunchDoesNotTerminateWhenLaunchFails() {
        // Inverted: this test passes only if terminate is NOT called.
        let mustNotTerminate = expectation(description: "terminate must not be called")
        mustNotTerminate.isInverted = true
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { _, completion in
                completion(NSError(domain: "KalamTests", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "simulated launch failure"]))
            },
            terminate: { mustNotTerminate.fulfill() }
        )

        AppRelauncher.relaunch(strategy: strategy)

        wait(for: [mustNotTerminate], timeout: 1)
    }

    func testRelaunchLaunchesTheMainBundleURL() {
        let launched = expectation(description: "launch called")
        let capture = URLCapture()
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { url, completion in
                capture.set(url)
                completion(nil)
                launched.fulfill()
            },
            terminate: {}
        )

        AppRelauncher.relaunch(strategy: strategy)

        wait(for: [launched], timeout: 2)
        XCTAssertEqual(capture.url, Bundle.main.bundleURL)
    }
}

/// Swift-6-safe holder for a URL captured inside a `@Sendable` closure (same
/// pattern as `StallMeter` in `AudioCaptureExchangeTests`).
private final class URLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    func set(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        _url = url
    }
    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _url
    }
}
```

- [ ] **Step 2: Run the targeted command — verify it FAILS (RED, compile level)**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AppRelauncherTests CODE_SIGNING_ALLOWED=NO
```

Expected: the test **target fails to compile** — `cannot find 'Strategy' in scope` / `'AppRelauncher' has no member 'relaunch(strategy:)'`. This is the documented RED: a signature-level failure against the current API, not a runtime failure (precedent: K-09's async-signature RED — "document that in the plan rather than forcing a runtime RED"). A runtime RED is impossible here because the current code has no injection seam (its failure mode requires a real launch failure).

- [ ] **Step 3: Do NOT commit yet** — the tree stays buildable at every commit (Global Constraints). Tests + implementation commit together at the end of Task 2.

---

## Task 2: Rewrite `AppRelauncher.swift` + green + commit

**Files:**
- Modify: `app/Kalam/AppRelauncher.swift` (full rewrite — replace the entire 19-line file)
- (Created in Task 1: `app/KalamTests/AppRelauncherTests.swift`)

**Interfaces:**
- Produces: `AppRelauncher.relaunch(strategy: Strategy = .live)`, `AppRelauncher.Strategy` (exactly as Task 1 consumes), `AppRelauncher.live`.
- Consumes: nothing new — `KalamApp.swift:454–456` and `OnboardingFlow.swift:440–442` compile unchanged (defaulted parameter).

- [ ] **Step 1: Rewrite `app/Kalam/AppRelauncher.swift` with the full file below**

```swift
import AppKit
import Foundation
import OSLog

/// Relaunches the app as a fresh process.
///
/// K-12: replaces the old `open -n` (via a `/usr/bin/open` `Process`) +
/// unconditional `exit(0)`. The old code quit even when the new instance
/// failed to launch (leaving the user with no app at all), and `exit(0)`
/// skipped the orderly termination lifecycle (`applicationWillTerminate`:
/// transcription-task cancellation, observer removal).
///
/// The live strategy launches a second instance via
/// `NSWorkspace.openApplication` (the sandbox-sanctioned API — no Process
/// hop) and terminates via `NSApp.terminate` ONLY after the launch succeeded;
/// a failed launch is logged and the app stays alive so the user can retry.
enum AppRelauncher {

    /// Injectable seam (same pattern as `PasteService.PasteStrategies`, K-02)
    /// so the orchestration is unit-testable without spawning processes.
    struct Strategy: Sendable {
        /// Launch a second instance of the app at `url`. Must call
        /// `completion` exactly once; `nil` means the launch was accepted.
        var launchNewInstance: @Sendable (URL, @escaping @Sendable (NSError?) -> Void) -> Void
        /// Orderly termination of the current instance.
        var terminate: @Sendable () -> Void
    }

    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AppRelauncher")

    /// Real implementation. `createsNewApplicationInstance = true` mirrors the
    /// old `open -n` semantics — and is REQUIRED here: without it, LaunchServices
    /// re-activates the still-running current instance and the relaunch
    /// degenerates into a plain quit. Do not remove.
    static let live = Strategy(
        launchNewInstance: { url, completion in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                completion(error as NSError?)
            }
        },
        terminate: {
            NSApp.terminate(nil)
        }
    )

    static func relaunch(strategy: Strategy = .live) {
        let bundleURL = Bundle.main.bundleURL
        strategy.launchNewInstance(bundleURL) { error in
            if let error {
                logger.error("Failed to relaunch app automatically: \(error.localizedDescription, privacy: .public)")
                return
            }
            // NSWorkspace does not document the completion thread; hop to
            // main before touching NSApp.
            DispatchQueue.main.async {
                strategy.terminate()
            }
        }
    }
}
```

Notes for the implementer:
- `import AppKit` is new (was Foundation-only); `import Foundation` stays (`Bundle`, `URL`); `import OSLog` for `Logger`.
- The `print()` at the old line 14 is gone (Logger now) — this folds K-16's `AppRelauncher.swift:14` evidence; Task 3 updates that tracker row.
- No changes to `KalamApp.swift` or `OnboardingFlow.swift` — the `relaunchAppAction: { AppRelauncher.relaunch() }` call site resolves to the defaulted `.live` strategy.

- [ ] **Step 2: Run the targeted tests — verify GREEN**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AppRelauncherTests CODE_SIGNING_ALLOWED=NO
```

Expected: 3 tests pass. If `testRelaunchTerminatesAfterSuccessfulLaunch` times out, the `DispatchQueue.main.async` hop is not being serviced — re-check that `wait(for:)` is used (sync method, runloop-pumping) and not `Task.sleep` (async suspension does not service `asyncAfter`-style main-queue blocks on the test host — documented K-08/K-09 pasteboard pitfall).

- [ ] **Step 3: Commit**

```bash
git add app/Kalam/AppRelauncher.swift app/KalamTests/AppRelauncherTests.swift
git commit -m "feat(K-12): relaunch via NSWorkspace + orderly NSApp.terminate gated on launch success"
```

(Stage only these two files. If `git status` shows sibling hunks in other files — `KalamApp.swift`, `OnboardingFlow.swift`, `OnboardingFlowTests.swift` were dirty at plan time — leave them alone. The cosmetic `fsmonitor_ipc__send_query` error on this mount does not fail the commit.)

---

## Task 3: Docs sync + full verification + tracker

- [ ] **Step 1: Update repo-root `AGENTS.md:39`** (architecture table row; exact replacement)

Old:
```markdown
| `AppRelauncher.swift` | `AppRelauncher` — `open -n` relaunch (K-12 candidate). |
```
New:
```markdown
| `AppRelauncher.swift` | `AppRelauncher` — relaunch via `NSWorkspace.openApplication` + orderly `NSApp.terminate` gated on launch success (K-12). |
```

- [ ] **Step 2: Update the K-16 row's evidence cell in `app/docs/IMPROVEMENT_PLAN.md`** — the `AppRelauncher.swift:14` print no longer exists.

Old cell fragment: `` `SettingsConfiguration.swift:211,217,226,395` (KalamApp.swift itself is print-free since K-03; ...) `` — specifically drop the `` `AppRelauncher.swift:14`; `` segment and change `and 13 other` → `and 12 other` in the Finding cell. Re-grep before editing:

```bash
rg -n "print\(" app/Kalam --include='*.swift' | rg -v "KalamTestRunner"
```

- [ ] **Step 3: Full verification**

```bash
./scripts/test-engine.sh                      # sanity — expect 41 green (engine untouched)
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: engine 41/41; build green; full Xcode suite green (3 new tests are additive; `OnboardingFlowTests.swift:255`'s `relaunchAppAction: {}` is source-compatible). Flag any sibling-uncommitted failures per the `kalam-app-development` skill (prove with `git show HEAD:<file>` before attributing).

- [ ] **Step 4: Tracker — K-12 stays `🔄`; mark `✅` only after the 🧑 gates pass**

The K-12 row status was flipped to `🔄` at plan authoring. When the 🧑 gates in the next section pass, flip the row to `✅` and append to the Resolved changelog:

```markdown
- **K-12 (2026-08-11)** — Relaunch lifecycle cleaned up: `AppRelauncher` no longer shells out to `/usr/bin/open -n` + unconditional `exit(0)`. It launches a fresh instance via `NSWorkspace.openApplication` (`createsNewApplicationInstance`, sandbox-sanctioned, no Process hop) and only then terminates orderly via `NSApp.terminate` (runs `applicationWillTerminate` → transcription-task cancel + observer cleanup). Launch failure now keeps the app alive and logs via `Logger` instead of quitting blind (was: app disappeared). Failure `print` → `Logger` (folds K-16's `AppRelauncher.swift:14` evidence). `SMAppService` evaluated and rejected (login-item/agent registration API, not a relaunch API). Verified: 3 new `AppRelauncherTests` green (terminate-on-success, no-terminate-on-failure, main-bundle URL); full Xcode suite + engine 41/41 green; 🧑 manual relaunch gate passed. Plan: `app/docs/dev-design/2026-08-11-k12-relaunch-lifecycle.md`.
```

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md app/docs/IMPROVEMENT_PLAN.md   # only the files you actually changed
git commit -m "docs(K-12): mark implementation executed; automated verification green, manual gate pending"
```

(If a sibling's uncommitted hunks merge into `IMPROVEMENT_PLAN.md`, commit only the clean new files and leave the tracker edit unstaged, flagging it in your reply — per the shared-mount workflow.)

---

## 🧑 Human verification gates (required before `✅`)

1. **Happy-path relaunch (the finding's verify step: "manual relaunch test after setup completion").** In a fresh app launch: onboarding → Microphone → Accessibility step → open System Settings → enable Kalam under Accessibility → return → press "Confirm". With AX still untrusted in-process, the step shows `.enabledPendingRelaunch` with the **"Quit & Reopen Kalam"** button (`OnboardingFlow.swift:860`). Press it. **Expected:** the app quits and a fresh instance opens within ~2 s; onboarding resumes at the Accessibility step and now shows it green (the fresh process is AX-trusted); dictation works. Console shows no `Failed to relaunch app automatically` entry:
   ```bash
   log show --last 5m --predicate 'subsystem == "singhkays.Kalam" AND category == "AppRelauncher"'
   ```
2. **Exit hygiene — no duplicates, no zombie.** Immediately after the relaunch (and again 10 s later): `pgrep -fl Kalam` shows **exactly one** Kalam process (the old instance terminated; `NSApp.terminate` ran `applicationWillTerminate` — verify no `Kalam`-named process lingers). If two instances persist >10 s, the terminate hop is broken — do not mark ✅.
3. **Failure path (automated coverage; optional manual).** `testRelaunchDoesNotTerminateWhenLaunchFails` pins the no-terminate-on-failure contract headlessly. Optional manual probe: from Terminal, run a second copy of the app whose bundle you rename first (`cp -R Kalam.app /tmp/Broken.app` then delete its `Contents/MacOS/*` binary), and trigger the relaunch button — the running app must NOT quit. (Only if easy to stage; the unit test is the required evidence.)

---

## Out of scope / future work

- **`SMAppService` login-item registration** — if the app ever wants "launch at login", that is a separate feature (`SMAppService.mainApp`); explicitly not part of K-12 (the API does not relaunch).
- **Relaunch affordance outside onboarding** — the button exists only on the Accessibility step's `.enabledPendingRelaunch` state. A Settings-side "Restart Kalam" is a product decision, not a K-12 item.
- **Crash-recovery auto-relaunch** — not requested; the privacy posture (no telemetry) argues against unattended relaunch.

## Test commands summary

| Command (from repo root) | Purpose |
|---|---|
| `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AppRelauncherTests CODE_SIGNING_ALLOWED=NO` | New K-12 tests (3) |
| `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Full suite |
| `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Build |
| `./scripts/test-engine.sh` | Engine sanity (41) |
