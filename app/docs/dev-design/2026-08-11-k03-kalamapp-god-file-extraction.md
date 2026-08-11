# K-03 — KalamApp.swift God-File Extraction: Implementation Plan

**Date:** 2026-08-11
**Status:** Executed 2026-08-11 — Tasks 0–8 complete (9 commits: `e4fbdb6`, `42d91e5`, `068df0c`, `5bda37d`, `cff43e5`, `e296739`, `ed02265`, `024bf6b`, `79c1b2c`). Task 9.1–9.4 pass (engine 32/32, build green, full Xcode suite green incl. `RealModelSmokeTests.testParakeetV2Smoke`, invariant greps clean). **Task 9.5 manual smoke (hotkey + overlay + ducking) pending human run** — flip `K-03` to `✅` only after it passes.
**Scope:** Extract the ~1,800 lines of non-orchestration code out of `app/Kalam/KalamApp.swift` (2,968 lines) into focused files. Pure structural refactor — **zero behavior change**.
**Sources:** `app/Kalam/KalamApp.swift` (read in full, 2026-08-11), `app/Kalam.xcodeproj/project.pbxproj` (folder-synced groups confirmed), `app/KalamTests/` (no references to extracted types), AGENTS.md, IMPROVEMENT_PLAN K-03.
**Executing agent note:** all line numbers below were verified against the working tree on 2026-08-11 and **will drift** — every task re-locates its range by anchor string before cutting (the `grep` commands are given).

---

**Goal:** Shrink `KalamApp.swift` from 2,968 → ~1,170 lines so `AppDelegate` becomes pure orchestration and each responsibility lives in a focused, reviewable file.

**Architecture:** Pure move-extraction. Each component is cut verbatim from `KalamApp.swift` into its own file with the imports it needs; file-private helpers that travel with a component (the `Float.clamped` extension, `secureZero`, `OverlayCapsuleView`/`WaveformView`) move together. Because every cross-component reference is already `internal`, and the only `private` file-scope helpers move with their sole consumer, **no access-control changes are expected** — the compiler is the arbiter (fix `private`→`internal` only if a build error demands it, then add a note in the commit).

**Tech Stack:** Swift 6 (strict concurrency), AppKit/AVFoundation/CoreAudio, Xcode project with `PBXFileSystemSynchronizedRootGroup` targets (dropping a `.swift` into `app/Kalam/` or `app/Kalam/Services/` auto-joins the app target — **no pbxproj edits**), SwiftPM engine package (untouched by this work).

---

## Global Constraints

1. **No network code.** Nothing in these components touches the network; do not add any. (Hard invariant — review every new import.)
2. **Never log transcript or audio content.** These components log counts/timings only, with `privacy: .public`. Move the log lines verbatim — do not "improve" them.
3. **Zero behavior change.** This is a cut-and-paste refactor. The only permitted edits are: (a) the import block at the top of each new file, (b) access-level fixes if the compiler demands them, (c) the private `privacySafeErrorSummary` copy in `AudioRecorder.swift` (see Task 3). Do not rename symbols, reorder members, reformat, or "fix" the dead `pasteKeyCode` constant.
4. **Swift 6 annotations travel verbatim:** `@MainActor` (SystemAudioDucker, DictationOverlayController), `@unchecked Sendable` (AudioRecorder), actor-inherited task patterns. Do not restructure concurrency during the move.
5. **`secureZero` invariant must survive:** the `Array<Float>.secureZero()` extension moves **with** `AudioRecorder` (its only consumer). Audio buffers are still zeroed in `deinit`, `stopAndFetchSamples`, `cancelCapture` — verify by grep in Task 9.
6. **Folder-synced groups:** new files auto-join the `Kalam` target. No `project.pbxproj` changes. Do not create a new Xcode group manually.
7. **Shared-mount git discipline (critical — sibling sessions work on this repo, and `KalamApp.swift` currently carries +31 uncommitted sibling lines: the `runtimePrepTask` single-flight onboarding fix):**
   - Never `git add -A` or `git add app/Kalam/KalamApp.swift` wholesale while it carries unrelated hunks.
   - Per task, stage deterministically: `git diff app/Kalam/KalamApp.swift > /tmp/k.diff`, extract only the hunks that delete **your** range (match hunk headers with `index()` in awk, not regex — `@@` contains regex-special `+`), `git apply --cached --recount <patch>`, then verify `git diff --cached` shows ONLY your hunks + the new file before committing.
   - Re-check `git status` and `git log --oneline -5` before starting and before each commit; re-read `KalamApp.swift`'s current tail before every cut (a sibling may have shifted lines).
   - `error: fsmonitor_ipc__send_query: unspecified error` is cosmetic on this mount — ignore it. `.git/index.lock` present? `rm -f .git/index.lock` and re-check status.
8. **VirtIOFS transient-unreadable race:** if `read_file`/`grep` report "No such file" on a file that `ls` shows with real size, read the index copy (`git show :0:./app/Kalam/KalamApp.swift`) — the race clears on its own; re-read the working tree before editing.
9. **Do not touch** `PasteService.swift`, `ASRService.swift`, `RecordingSessionTracker.swift`, `TextCleanupService.swift`, the engine package, or any test file. K-03 is extraction only.

---

## Current state (verified 2026-08-11, working tree)

`app/Kalam/KalamApp.swift` = 2,968 lines. Type map with anchors:

| Lines (WT) | Anchor string | Type | New home |
|---|---|---|---|
| 19–28 | `// MARK: - Secure Memory Zeroing` | `extension Array where Element == Float { secureZero }` | `Services/AudioRecorder.swift` (Task 3) |
| 33 | `private let pasteKeyCode: CGKeyCode = 9` | dead constant (no usages) | **stays** (K-16 hygiene, out of scope) |
| 35–56 | `enum KalamExternalLinks` / `enum KalamAppVersion` | app metadata | `AppMetadata.swift` (Task 7) |
| 57–70 | `@main struct KalamApp: App` | app entry | **stays** |
| 71–1190 | `final class AppDelegate` | orchestration (target state) | **stays** |
| 1190–1331 | `// Float clamp helper` … `final class SystemAudioDucker` `}` | ducker + `private extension Float` | `Services/SystemAudioDucker.swift` (Task 1) |
| 1330–1528 | `// MARK: - Global Hotkey` … `final class HotkeyListener` `}` | hotkey listener | `Services/HotkeyListener.swift` (Task 2) |
| 1527–2323 | `// MARK: - Dictation Overlay` … `private final class WaveformView` `}` | overlay controller + `OverlayCapsuleView` + `WaveformView` | `DictationOverlayController.swift` (Task 5) |
| 2325–2725 | `// MARK: - Audio Recorder` … `final class AudioRecorder` `}` | recorder + `AudioRecorderError` | `Services/AudioRecorder.swift` (Task 3) |
| 2722–2923 | `// MARK: - ASR …` (stale) / `// MARK: - Silence Trimmer` … `enum SilenceTrimmer` `}` | silence trimmer | `Services/SilenceTrimmer.swift` (Task 4) |
| 2922–2951 | `// MARK: - Accessibility helper` … `enum AccessibilityHelper` `}` | AX helper | `AccessibilityHelper.swift` (Task 6a) |
| 2952–2968 | `enum AppRelauncher` `}` | relauncher | `AppRelauncher.swift` (Task 6b) |

**Cross-file consumers (verified):** `SettingsUI.swift:398,420` → `KalamAppVersion`, `KalamExternalLinks`; `OnboardingFlow.swift:369,375` → `AccessibilityHelper`; `KalamApp.swift` (AppDelegate) → every component's public API (`audio.prepare/startCollecting/stopAndFetchSamples/cancelCapture/recentWaveform`, `AudioRecorder.requestMicrophoneAccessIfNeeded`, `overlay.setWaveformProvider/showRecording/showTranscribing/showSuccessAndAutoHide/showInfoAndAutoHide/showError`, `hotkeys.onPTTChanged/update`, `SystemAudioDucker.shared.initialize/startDucking/stopDucking`, `SilenceTrimmer.trim/normalizePeak`, `AccessibilityHelper.isTrusted`, `AppRelauncher.relaunch`). **All of these are already `internal` — no access changes needed.**

**Known dependencies that are NOT in KalamApp.swift (no action needed):** `RecordingSessionTracker` (`RecordingSessionTracker.swift`), `SystemSettingsNavigator` (`ModelSetupSupport.swift:24`), `AudioDeviceDebug` (`SettingsConfiguration.swift:193`), `KeyCombination` (`PTTHotkeyConfiguration.swift:27`), `IndicatorPlacementPreset` (`SettingsConfiguration.swift:15`), `AccessibilityFocusResolver`, `RuntimeCapabilities`. `privacySafeErrorSummary` exists as a `private func` copy in 3 files already (`KalamApp.swift:14`, `CustomDictionaryManager.swift:5`, `ASRService.swift:7`) — the established convention is one private copy per file.

**Mid-file import to remove:** `import CoreAudio` sits at ~line 1199 (inside the Task 1 cut range). KalamApp.swift's top already imports CoreAudio — the mid-file one is a duplicate (K-21 finding) and disappears with the cut.

---

## Task 0: Pre-flight (5 min)

- [ ] **Step 1: Confirm repo state**
  ```bash
  cd /Volumes/My\ Shared\ Files/GitHub/Kalam
  git status --short
  git log --oneline -5
  ```
  Expected: `main`, and `app/Kalam/KalamApp.swift` modified (+31 uncommitted sibling lines, the `runtimePrepTask` onboarding fix). Do **not** commit or revert those lines; they ride along unstaged until a sibling commits them.

- [ ] **Step 2: Baseline build** (proves the starting point is green before any cut)
  ```bash
  cd /Volumes/My\ Shared\ Files/GitHub/Kalam
  ./scripts/test-engine.sh && echo ENGINE_OK
  xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -3
  ```
  Expected: engine 32/32 green; `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Claim the item**
  In `app/docs/IMPROVEMENT_PLAN.md`, flip `K-03` status `⬜` → `🔄`. Commit: `docs: claim K-03 (KalamApp.swift extraction) — plan at app/docs/dev-design/2026-08-11-k03-kalamapp-god-file-extraction.md`.

---

## Task 1: Extract SystemAudioDucker → `Kalam/Services/SystemAudioDucker.swift` (~130 lines)

**Files:**
- Create: `app/Kalam/Services/SystemAudioDucker.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~1190–1331

- [ ] **Step 1: Re-locate the range**
  ```bash
  grep -n "Float clamp helper\|final class SystemAudioDucker" app/Kalam/KalamApp.swift
  ```
  Cut from the `// Float clamp helper` line through `SystemAudioDucker`'s closing `}` (the `}` directly above `// MARK: - Global Hotkey`). Confirm the closing brace line with `sed -n '<classline+130>p' app/Kalam/KalamApp.swift` → expect `}`.

- [ ] **Step 2: Create the new file** with `write_file`
  Content = the cut range verbatim, in this order: `private extension Float { clamped(to:) }` **then** `@MainActor final class SystemAudioDucker { … }` (it currently sits between the two — keep the order). Header imports:
  ```swift
  import Foundation
  import CoreAudio
  import OSLog
  ```
  (`Logger`, `AudioDeviceID`, `AudioObjectGetPropertyData`, `kAudioObjectUnknown`, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`; `RuntimeCapabilities` and `GeneralSettingsConfiguration` are same-module.) The mid-file `import CoreAudio` line is inside the cut range — it lands in the new file; delete the duplicate from KalamApp.swift if the cut leaves a stray copy (it won't — it's inside the range).

- [ ] **Step 3: Delete the range from `KalamApp.swift`** via `patch` (replace the exact anchored block from `// Float clamp helper` through the ducker's closing `}` + trailing blank line with nothing).

- [ ] **Step 4: Verify no orphaned declarations**
  ```bash
  grep -n "final class SystemAudioDucker\|Float clamp helper" app/Kalam/KalamApp.swift   # expect: no output
  grep -rn "SystemAudioDucker" app/Kalam --include="*.swift"   # expect: Services/SystemAudioDucker.swift + AppDelegate call sites only
  ```

- [ ] **Step 5: Build**
  ```bash
  xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -3
  ```
  Expected: `** BUILD SUCCEEDED **`. If "not found in scope" errors appear, the only legitimate cause is a missed file-private helper — check the error's symbol, move that helper into the new file, rebuild.

- [ ] **Step 6: Commit** (deterministic staging per Global Constraint 7 — extract only the deletion hunk; never `git add` the file wholesale while sibling hunks are present)
  ```bash
  git add app/Kalam/Services/SystemAudioDucker.swift
  # ... extract + apply --cached only the SystemAudioDucker deletion hunk from app/Kalam/KalamApp.swift ...
  git diff --cached --stat   # must show exactly: 1 new file + 1 deletion hunk
  git commit -m "refactor(K-03): extract SystemAudioDucker into Services/SystemAudioDucker.swift"
  ```

---

## Task 2: Extract HotkeyListener → `Kalam/Services/HotkeyListener.swift` (~200 lines)

**Files:**
- Create: `app/Kalam/Services/HotkeyListener.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~1330–1528

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "MARK: - Global Hotkey\|final class HotkeyListener" app/Kalam/KalamApp.swift
  ```
  Cut from the `// MARK: - Global Hotkey (press-to-talk)` comment through `HotkeyListener`'s closing `}` (directly above `// MARK: - Dictation Overlay`).

- [ ] **Step 2: Create the file** — content verbatim. Header imports:
  ```swift
  import Foundation
  import AppKit
  import HotKey
  ```
  (`NSEvent`, `HotKey` package; `PTTHotkeyConfiguration`/`KeyCombination` are same-module.) Keep the two `print("Hotkey registered: …")` lines verbatim — K-16 converts them to Logger later, not here.

- [ ] **Step 3: Delete the range** from `KalamApp.swift` (anchor: `// MARK: - Global Hotkey (press-to-talk)` … `}` above `// MARK: - Dictation Overlay`).

- [ ] **Step 4: Verify**
  ```bash
  grep -n "final class HotkeyListener" app/Kalam/KalamApp.swift   # expect: no output
  grep -rn "HotkeyListener" app/Kalam --include="*.swift"          # expect: new file + AppDelegate (let hotkeys = HotkeyListener(), .update, .onPTTChanged) + SettingsUI/OnboardingFlow if any
  ```

- [ ] **Step 5: Build** (same command as Task 1). Expected: SUCCEEDED.

- [ ] **Step 6: Commit** — `refactor(K-03): extract HotkeyListener into Services/HotkeyListener.swift`

---

## Task 3: Extract AudioRecorder → `Kalam/Services/AudioRecorder.swift` (~420 lines incl. helpers)

**Files:**
- Create: `app/Kalam/Services/AudioRecorder.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete the `secureZero` extension (lines ~19–28), the `// MARK: - Audio Recorder` … `AudioRecorderError` … `AudioRecorder` block (lines ~2325–2725)

**This task has three payloads that must move together (they are each other's only consumers in the file):**

1. `extension Array where Element == Float { mutating func secureZero() }` (+ its `// MARK: - Secure Memory Zeroing` comment) — `AudioRecorder` calls it in `stopAndFetchSamples`, `deinit`.
2. `private func privacySafeErrorSummary(_ error: Error) -> String` — `AudioRecorder` calls it in `logger.warning(… errorSummary=\(privacySafeErrorSummary(error) …)`. The KalamApp.swift copy **stays** (AppDelegate uses it); the new file gets its **own private copy**, matching the existing convention (`CustomDictionaryManager.swift:5`, `ASRService.swift:7`).
3. `enum AudioRecorderError: LocalizedError` + `final class AudioRecorder: @unchecked Sendable`.

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "Secure Memory Zeroing\|MARK: - Audio Recorder\|final class AudioRecorder\|enum AudioRecorderError" app/Kalam/KalamApp.swift
  ```
  Two cut ranges: (a) `// MARK: - Secure Memory Zeroing` … `}` of the extension; (b) `// MARK: - Audio Recorder (AVAudioEngine + resample to 16kHz mono Float32)` … `AudioRecorder`'s closing `}` (directly above the stale `// MARK: - ASR` line). Note: the `// MARK: - ASR (FluidAudio Parakeet TDT v3)` line at ~2722 is a stale decorative comment (ASR lives in `ASRService.swift`) — delete it when cutting (it separates the AudioRecorder block from SilenceTrimmer).

- [ ] **Step 2: Create the file** — content verbatim, ordered: `private func privacySafeErrorSummary`, `extension Array where Element == Float { secureZero }`, `enum AudioRecorderError`, `final class AudioRecorder`. Header imports (match KalamApp.swift's own import style for AVFoundation under Swift 6):
  ```swift
  import Foundation
  import AppKit
  @preconcurrency import AVFoundation
  import CoreAudio
  import OSLog
  ```
  (`AVAudioEngine`/`AVAudioConverter`/`AVCaptureDevice` → AVFoundation; `AudioDeviceID`/`AudioUnitSetProperty` → CoreAudio; `Logger` → OSLog; `AudioDeviceDebug` is same-module.)

- [ ] **Step 3: Delete both ranges** from `KalamApp.swift`. The file keeps its own `privacySafeErrorSummary` (AppDelegate still needs it at line ~14).

- [ ] **Step 4: Verify**
  ```bash
  grep -n "final class AudioRecorder\|Secure Memory Zeroing" app/Kalam/KalamApp.swift          # expect: no output
  grep -n "secureZero" app/Kalam/KalamApp.swift                                               # expect: no output
  grep -rn "secureZero\|AudioRecorderError" app/Kalam --include="*.swift"                       # expect: new file + AppDelegate call sites only
  grep -n "func privacySafeErrorSummary" app/Kalam/KalamApp.swift app/Kalam/Services/AudioRecorder.swift   # expect: one private copy in each
  ```

- [ ] **Step 5: Build.** Expected: SUCCEEDED.

- [ ] **Step 6: Commit** — `refactor(K-03): extract AudioRecorder (+ secureZero, privacySafeErrorSummary) into Services/AudioRecorder.swift`

---

## Task 4: Extract SilenceTrimmer → `Kalam/Services/SilenceTrimmer.swift` (~200 lines)

**Files:**
- Create: `app/Kalam/Services/SilenceTrimmer.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~2722–2923

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "MARK: - Silence Trimmer\|enum SilenceTrimmer" app/Kalam/KalamApp.swift
  ```
  Cut from the `// MARK: - Silence Trimmer (robust energy-based endpointer with hysteresis)` comment through `SilenceTrimmer`'s closing `}` (directly above `// MARK: - Accessibility helper`). The stale `// MARK: - ASR …` line above was already deleted in Task 3 — if it still exists, delete it too.

- [ ] **Step 2: Create the file** — content verbatim. Header imports:
  ```swift
  import Foundation
  import OSLog
  ```
  (Pure math + `Logger`; `trim`/`normalizePeak`/`percentile`.)

- [ ] **Step 3: Delete the range.**

- [ ] **Step 4: Verify** — `grep -n "enum SilenceTrimmer" app/Kalam/KalamApp.swift` → no output; `grep -rn "SilenceTrimmer" app/Kalam --include="*.swift"` → new file + AppDelegate (`SilenceTrimmer.trim`, `SilenceTrimmer.normalizePeak`).

- [ ] **Step 5: Build.** Expected: SUCCEEDED.

- [ ] **Step 6: Commit** — `refactor(K-03): extract SilenceTrimmer into Services/SilenceTrimmer.swift`

---

## Task 5: Extract DictationOverlayController → `Kalam/DictationOverlayController.swift` (~800 lines)

**Files:**
- Create: `app/Kalam/DictationOverlayController.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~1527–2323

**This is the largest move. Three types travel together (the two views are `private` file-scope classes referenced only by the controller):** `@MainActor final class DictationOverlayController`, `private final class OverlayCapsuleView`, `private final class WaveformView`. They keep their `private` modifiers — file-privacy still works in the new file since they move as a unit.

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "MARK: - Dictation Overlay\|final class DictationOverlayController\|private final class OverlayCapsuleView\|private final class WaveformView" app/Kalam/KalamApp.swift
  ```
  Cut from `// MARK: - Dictation Overlay` through `WaveformView`'s closing `}` (directly above `// MARK: - Audio Recorder …`).

- [ ] **Step 2: Create the file** — content verbatim (controller, then capsule, then waveform — the current order). Header imports:
  ```swift
  import Foundation
  import AppKit
  import ApplicationServices
  ```
  (`NSWindow`/`NSView`/`NSVisualEffectView`/`CALayer`/`CAGradientLayer`/`CAShapeLayer`/`NSBezierPath`/`NSWorkspace`/`NSAnimationContext` → AppKit (re-exports QuartzCore); `AXIsProcessTrusted`/`AXUIElement`/`kAXPositionAttribute` → ApplicationServices; `SystemSettingsNavigator`, `AccessibilityFocusResolver`, `GeneralSettingsConfiguration` are same-module.) No Logger used in this file.

- [ ] **Step 3: Delete the range.**

- [ ] **Step 4: Verify**
  ```bash
  grep -n "DictationOverlayController\|OverlayCapsuleView\|WaveformView" app/Kalam/KalamApp.swift   # expect: only AppDelegate call sites (overlay.showRecording etc.), no declarations
  grep -rn "OverlayAction" app/Kalam --include="*.swift"                                            # expect: new file + AppDelegate (.openMicrophoneSettings / .openAccessibilitySettings) — confirms the internal enum survived
  ```

- [ ] **Step 5: Build.** Expected: SUCCEEDED.

- [ ] **Step 6: Commit** — `refactor(K-03): extract DictationOverlayController + overlay views into DictationOverlayController.swift`

---

## Task 6: Extract AccessibilityHelper + AppRelauncher (~45 lines)

**Files:**
- Create: `app/Kalam/AccessibilityHelper.swift`, `app/Kalam/AppRelauncher.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~2922–2968

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "MARK: - Accessibility helper\|enum AccessibilityHelper\|enum AppRelauncher" app/Kalam/KalamApp.swift
  ```
  Cut two ranges: `// MARK: - Accessibility helper` … `AccessibilityHelper`'s `}`, then `enum AppRelauncher` … final `}` of the file.

- [ ] **Step 2: Create `AccessibilityHelper.swift`** — verbatim. Imports: `import ApplicationServices` (`AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`). The `print()` lines move verbatim (K-16 converts them later).

- [ ] **Step 3: Create `AppRelauncher.swift`** — verbatim. Imports: `import Foundation` (`Process`, `Bundle`, `exit`).

- [ ] **Step 4: Delete both ranges.**

- [ ] **Step 5: Verify** — `grep -n "enum AccessibilityHelper\|enum AppRelauncher" app/Kalam/KalamApp.swift` → no output; `grep -rn "AccessibilityHelper" app/Kalam --include="*.swift"` → new file + AppDelegate + OnboardingFlow.

- [ ] **Step 6: Build.** Expected: SUCCEEDED.

- [ ] **Step 7: Commit** — `refactor(K-03): extract AccessibilityHelper and AppRelauncher into their own files`

---

## Task 7: Move app metadata → `Kalam/AppMetadata.swift` (~22 lines)

**Files:**
- Create: `app/Kalam/AppMetadata.swift`
- Modify: `app/Kalam/KalamApp.swift` — delete lines ~35–56

- [ ] **Step 1: Re-locate**
  ```bash
  grep -n "enum KalamExternalLinks\|enum KalamAppVersion" app/Kalam/KalamApp.swift
  ```
  Cut `enum KalamExternalLinks { … }` and `enum KalamAppVersion { … }` (contiguous). Leave the dead `private let pasteKeyCode` at line ~33 in place (K-16 territory).

- [ ] **Step 2: Create `AppMetadata.swift`** — both enums verbatim. Imports:
  ```swift
  import Foundation
  import AppKit
  ```
  (`URL`, `Bundle`, `NSWorkspace`; `openLatestRelease()` keeps its `@MainActor @discardableResult`.)

- [ ] **Step 3: Delete the range.**

- [ ] **Step 4: Verify** — `grep -n "KalamExternalLinks\|KalamAppVersion" app/Kalam/KalamApp.swift` → no output; `grep -rn "KalamAppVersion\|KalamExternalLinks" app/Kalam --include="*.swift"` → new file + SettingsUI (`displayString`, `openLatestRelease`) + AppDelegate (`openLatestRelease`).

- [ ] **Step 5: Build.** Expected: SUCCEEDED.

- [ ] **Step 6: Commit** — `refactor(K-03): move app metadata (KalamExternalLinks/KalamAppVersion) to AppMetadata.swift`

---

## Task 8: Doc sync (required — K-03's contract with AGENTS.md/SECURITY.md)

- [ ] **Step 1: `AGENTS.md`** — update the architecture map row for `KalamApp.swift` (remove "overlay UI, AudioRecorder, SilenceTrimmer, SystemAudioDucker, HotkeyListener" from its responsibility list; it becomes: entry, AppDelegate, hotkey state machine, recording orchestration, paste pipeline, audio ducking, chime) and add rows:
  - `Services/AudioRecorder.swift`, `Services/SilenceTrimmer.swift`, `Services/SystemAudioDucker.swift`, `Services/HotkeyListener.swift`, `DictationOverlayController.swift` (+ overlay views), `AccessibilityHelper.swift`, `AppRelauncher.swift`, `AppMetadata.swift`.

- [ ] **Step 2: `SECURITY.md` + any doc referencing `KalamApp.swift:20–28`** — repoint the secureZero invariant at `Services/AudioRecorder.swift`.
  ```bash
  grep -rn "KalamApp.swift" app/docs/ --include="*.md"
  ```
  Fix every hit that references the moved code (line numbers for AppDelegate-internal logic may stay).

- [ ] **Step 3: `app/docs/DEVELOPER_GUIDE.md`** — check its file map for the same rows (this overlaps K-17; fix only the K-03-related references here).

- [ ] **Step 4: Final grep** — `grep -rn "KalamApp.swift:[0-9]" app/docs/ AGENTS.md` → every remaining reference must point at code that is still in `KalamApp.swift`.

- [ ] **Step 5: Commit** — `docs(K-03): update architecture map and security references for extracted files`

---

## Task 9: Full verification (the K-03 gate)

- [ ] **Step 1: Engine tests**
  ```bash
  cd /Volumes/My\ Shared\ Files/GitHub/Kalam && ./scripts/test-engine.sh
  ```
  Expected: 32/32 green (engine untouched — this guards against accidental package drift).

- [ ] **Step 2: Full build**
  ```bash
  xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -3
  ```
  Expected: `** BUILD SUCCEEDED **`. Also confirm the file shrank: `wc -l app/Kalam/KalamApp.swift` → ~1,170.

- [ ] **Step 3: Full Xcode suite** (needs Xcode + a running session; if unavailable on the VM, note it and rely on Steps 1–2 + smoke)
  ```bash
  xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -5
  ```

- [ ] **Step 4: Invariant greps**
  ```bash
  grep -rn "URLSession\|https://" app/Kalam --include="*.swift" | grep -v "KalamExternalLinks\|AppMetadata"   # no new network code
  grep -rn "secureZero" app/Kalam --include="*.swift"                                                        # still zeroing audio buffers
  grep -rn "print(" app/Kalam --include="*.swift" | grep -v "KalamApp.swift\|HotkeyListener\|AccessibilityHelper"  # no NEW prints (K-16 handles existing)
  ```

- [ ] **Step 5: Manual smoke (human, on a Mac with a mic — the K-03 verify column)**
  - Launch → hotkey registers (menu bar icon present; no console spam of errors).
  - **Hold mode:** press-and-hold PTT → capsule appears near the focused element: "Release to stop", target app name + icon, timer ticks, waveform bars animate left-to-right, rotating rainbow border intact (no visual regression vs. pre-extraction).
  - Release → "Transcribing…" → text lands in the frontmost app → "Inserted" flash.
  - **Toggle mode:** tap PTT → "Tap hotkey to stop"; tap again → transcribes.
  - **Ducking:** with *Mute while recording* on: chime plays at full volume, system volume drops during recording, restores on release. With the setting off: no volume change.
  - **Error path:** deny microphone → PTT shows error capsule with "Open" → clicking opens System Settings.
  - **Escape** cancels recording ("Recording canceled" info capsule).
  - **Placement:** overlay follows the focused field when AX is trusted; falls back to top-center otherwise.

- [ ] **Step 6: Close the loop in `app/docs/IMPROVEMENT_PLAN.md`** — K-03 → `✅` **only if Steps 1–5 all pass**. If Step 3 (Xcode suite) was skipped, keep `🔄` and note what remains. Add a "resolved" changelog row per the file's protocol.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Sibling session edits `KalamApp.swift` mid-extraction** (onboarding fix is live) | Task 0 pre-flight + re-read tail before every cut (Constraint 7); the extraction ranges (1190+) don't overlap the sibling's AppDelegate hunks (121–701), so deterministic hunk staging keeps commits separable |
| Access-control fallout from a `private` file-scope helper I missed | Build after every task catches it; the fix is mechanical (move the helper or widen to `internal`) and the commit notes it. Known set verified: only `Float.clamped` (Task 1), `secureZero` (Task 3), `OverlayCapsuleView`/`WaveformView` (Task 5) — all travel with their consumer |
| `import CoreAudio` mid-file removal breaks the ducker | The import is inside the cut range and lands in the new file's header (Task 1 Step 2) |
| Waveform/overlay visual regression from the move | Pure cut — no code touched; Step 5 manual smoke includes an explicit visual check |
| Engine package corrupted by parallel builds (SwiftPM `runner.swift was modified`) | If it appears with no builders running: `mv .build .build.bak && ./scripts/test-engine.sh` in `app/Packages/KalamTextEngine/`, then remove the bak |
| Xcode unavailable on the VM | `xcodebuild` steps are the gate; if the toolchain is missing, say so explicitly in the K-03 status — do not mark ✅ on engine tests alone |

## Out of scope (do NOT do here)

- Splitting `AppDelegate` itself (~1,120 lines of orchestration after extraction) — that's a future K-item if desired.
- Converting `print()` → Logger (K-16), deleting dead `pasteKeyCode` (K-16), fixing the stale `// MARK: - ASR` comment (done incidentally in Task 3), K-21 import reorganization, K-04 SettingsUI split.
- Touching `SilenceTrimmer`'s algorithm, `AudioRecorder`'s buffer queue (K-10 is a separate item), or the overlay's rendering.
