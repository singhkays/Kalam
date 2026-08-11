# Kalam — Swift Codebase Improvement Plan

**Status legend:** `⬜ todo` · `🔄 in progress` · `✅ done` (only after verified)
**Last updated:** 2026-08-10
**Source:** Full read-only review of `app/Kalam/`, `app/Packages/KalamTextEngine/`, entitlements, workflows, and scripts. Engine tests were green (32/32) at review time.
**Working tree at review time:** uncommitted engine-extraction refactor in flight (`KalamApp.swift` −562 lines, `DictionaryEntry`/cleanup config moved into the `KalamTextEngine` package, `app/Kalam/TextCleanupConfiguration.swift` deleted).

> **For agents:** line numbers below reflect the tree at review time — **re-verify against current code before acting**. Implement each item independently. Mark an item `✅` only when the change is implemented **AND** its verification step passes. Add new findings with the next free K-ID.

---

## Priority 1 — Correctness bugs (do these first)

| ID | Status | Severity | Finding | Evidence (at review time) | Fix | Verify |
|---|---|---|---|---|---|---|
| K-01 | 🔄 | **High** | Starting a new recording doesn't cancel the in-flight transcription/paste task → stale transcript can be pasted after a new recording begins (wrong-context paste / double paste). | `KalamApp.swift`: `transcriptionTask?.cancel()` exists only in `stopRecordingAndTranscribe()` (~934) and `cancelRecording()` (~1095); `startRecording()` (~856–913) never cancels. | Add `transcriptionTask?.cancel()` at the top of `startRecording()`. | Toggle mode: record → stop → tap-start again before the paste fires; confirm the old text is NOT pasted and there is no double paste. |
| K-02 | 🔄 | **High** | Clipboard snapshot is never restored when every paste path fails → user's clipboard contents are replaced by the transcript and left there (data loss + lingering sensitive text). | `PasteService.swift:70–82`: `restoreClipboardIfNeeded` runs only on Cmd+V success (~72) and AX success (~82); the throw path (~78) skips it. | Restore the snapshot on **all** paths (defer-style) once the snapshot is taken. | Revoke Accessibility permission, force the failure path, confirm the original clipboard content returns and the transcript is cleared. |

## Priority 2 — Architecture (deepening)

| ID | Status | Severity | Finding | Evidence (at review time) | Fix | Verify |
|---|---|---|---|---|---|---|
| K-03 | ⬜ | Medium | `KalamApp.swift` is a 2,924-line god file (~10 responsibilities): `AppDelegate` (~580), `DictationOverlayController` + `OverlayCapsuleView` + `WaveformView` (~700 lines of AppKit/CALayer UI), `AudioRecorder` (~400), `SilenceTrimmer` (~195), `SystemAudioDucker` (~130), `HotkeyListener` (~195), helpers. | `KalamApp.swift` structure; overlay UI spans ~1483–2279. | Extract overlay UI → own file; `AudioRecorder`/`SilenceTrimmer`/`SystemAudioDucker` → `Services/`; `HotkeyListener` → own file. `AppDelegate` becomes pure orchestration. | `./scripts/test-engine.sh` still green; `xcodebuild build` succeeds; manual smoke: hotkey + overlay + ducking. |
| K-04 | ⬜ | Medium | `SettingsView` is a single 1,518-line struct (`SettingsUI.swift:8–1526`); only 5 top-level types in a 2,154-line file. | `SettingsUI.swift` type scan. | Split per-tab (Word Replacement / Keyboard / Refine / Models) into separate files. | Build + manual smoke of each tab. |
| K-05 | ⬜ | Medium | `wholeWord` and `morphological` flags on `DictionaryEntry` are dead configuration — the compiler always emits `\b(trigger)(suffix)?\b`, and no UI toggle exists. Test `wholeWordEnforcement` pins `wholeWord: false` while asserting whole-word behavior (passes by proving the flag is a no-op). | `DictionaryEntry.swift:10–13`; `ReplacementCompiler.swift:159–171`; `ReplacementCompilerTests.swift:70–81`; `SettingsUI.swift:1907` (copy text only). | Either honor the flags in `compileWordRule` or delete them; fix the test to assert intended semantics. | `./scripts/test-engine.sh` green. |
| K-06 | ⬜ | Medium | `normalizePunctuation` (5 transforms + `try!` regexes) is duplicated verbatim across the package boundary; the entire grammar pass (`runGrammar`, `normalizeSentenceStarts`, `isProtectedTerm`) lives only in the app shell → zero headless test coverage for the app's most fragile code. | `TextCleanupEngine.swift:281–300` vs `TextCleanupService.swift:173–195, 216–222`; grammar-only code in `TextCleanupService.swift`. | Move the grammar pass into `KalamTextEngine` behind `canImport(AppKit)`; delete the app-side duplicate. | `./scripts/test-engine.sh` covers grammar; `xcodebuild test` integration passes. |
| K-07 | ✅ | Low | `KalamTextEngine/Package.swift` declares `.macOS(.v15)` while the app targets 14.6 and links the package; engine uses only macOS 12+ APIs. | `Package.swift:6`; app `MACOSX_DEPLOYMENT_TARGET = 14.6`. | Lower package platform to 14.6 (or justify raising the app target). | Build for a 14.6 destination. |

## Priority 3 — Security & hardening

| ID | Status | Severity | Finding | Evidence (at review time) | Fix | Verify |
|---|---|---|---|---|---|---|
| K-08 | ⬜ | Medium | Transcript text sits on `NSPasteboard.general` for up to ~0.5 s after Cmd+V paste. | `PasteService.swift:91` (`asyncAfter .now() + 0.5`). | Shorten the window / restore sooner once change-count confirms; tie to K-02's defer-restore. | Paste into an app that polls the pasteboard; confirm restore timing. |
| K-09 | ⬜ | Medium | `waitForPasteboardCommit` spins `usleep` up to 150 ms on the MainActor. | `PasteService.swift:113–129` (loop at 122–127). | Replace with `Task.sleep` / continuation polling. | No main-thread stall during paste (sample main thread). |
| K-10 | ⬜ | Medium | Real-time audio thread (installTap callback) takes a blocking `bufferQueue.sync` while the transcription task holds the same queue — priority-inversion risk on the render thread. | `KalamApp.swift:2500–2556` (`process(buffer:)`). | `os_unfair_lock` / `tryLock`, or lock-free enqueue; never block the audio thread. | Record while transcribing; no audio glitches under contention. |
| K-11 | ⬜ | Low | GitHub Actions use mutable tags (supply-chain hardening gap); `deploy-kalam-landing.yml` has no `permissions:` block. | `.github/workflows/release.yml` (`checkout@v4`, `cache@v4`, `setup-xcode@v1`, `action-gh-release@v2`); `deploy-kalam-landing.yml` (`checkout@v4`, `setup-node@v4`). | Pin actions to commit SHAs; add explicit `permissions:` (contents: write only where needed). | Workflows still run after pinning. |
| K-12 | ⬜ | Info | `AppRelauncher` uses `open -n` + `exit(0)`; consider `SMAppService`/`NSWorkspace` relaunch for cleaner lifecycle. | `KalamApp.swift:2908–2923`. | Evaluate; low priority. | Manual relaunch test after setup completion. |

## Priority 4 — Tests & CI

| ID | Status | Severity | Finding | Evidence (at review time) | Fix | Verify |
|---|---|---|---|---|---|---|
| K-13 | ⬜ | **High** (CI) | `release.yml` swallows Xcode test failures: `xcodebuild test … \| xcbeautify \|\| true` — CI can go green with a broken test suite. Engine tests gate properly; the Xcode suite does not. | `.github/workflows/release.yml` ("Run Xcode tests" step). | `set -o pipefail`, drop `\|\| true` (or gate on `xcresult`). | Push a deliberately failing test on a branch → workflow must fail. |
| K-14 | ⬜ | Low | Coverage gaps: grammar pass, clipboard restore, hotkey state machine have no automated tests (Xcode-only, unenforced). | Test inventory (`KalamTests/`, `KalamTextEngineTests/`). | Add tests after K-06; at minimum cover K-01/K-02 regressions. | New tests fail before fix, pass after. |
| K-15 | ⬜ | Low | `app/scripts/test-engine.sh` is a stale duplicate that resolves `$ROOT/Packages/KalamTextEngine` (missing `app/` prefix) — broken since the package moved; `scripts/test-engine.sh` is the maintained one. | `app/scripts/test-engine.sh` (201 B) vs `scripts/test-engine.sh` (1,675 B). | Delete `app/scripts/test-engine.sh` (or fix path + fold into the root script). | `./scripts/test-engine.sh` remains the single entry point. |

## Priority 5 — Hygiene, accessibility & docs

| ID | Status | Severity | Finding | Evidence (at review time) | Fix | Verify |
|---|---|---|---|---|---|---|
| K-16 | ⬜ | Low | Debug leftover + raw `print()` instead of `Logger`: `print("\n[DEBUG] RESETTING ONBOARDING STATE")` and 13 other `print()` calls. | `OnboardingFlow.swift:507`; `KalamApp.swift:1318, 1333, 2892, 2899, 2919`; `SettingsConfiguration.swift:211`. | Remove debug prints; convert remaining `print()` → `Logger`. | `grep -rn 'print(' app/Kalam --include='*.swift'` → only intentional output remains. |
| K-17 | ⬜ | Low | Docs drift: stray pasted paragraph in the guide; references to deleted `app/Kalam/TextCleanupConfiguration.swift`. | `app/docs/DEVELOPER_GUIDE.md:249` (stray text), `:67–69` (deleted file). | Remove stray text; update architecture list to point at the engine package. | Read-through of the guide. |
| K-18 | ⬜ | Low | `app/.grok/` and `app/.hermes/` (incl. `desktop-attachments/`) are untracked local dirs not covered by `.gitignore` — a careless `git add -A` commits session artifacts. | `.gitignore` (no grok/hermes entries); `git status` untracked list. | Add `.grok/` and `.hermes/` to `.gitignore` (and `app/.grok/`, `app/.hermes/`). | `git status` clean of those dirs. |
| K-19 | ⬜ | Medium | Accessibility gaps for a dictation app: only 2 `.accessibilityLabel`s in the entire app; the hotkey dropdown is hidden from VoiceOver; onboarding windows hide traffic lights and are mouse-first. | `SetupDropdownField.swift:25` (`.accessibilityHidden(true)`); app-wide label count = 2 (`ModelAcquisitionPanel.swift:190`, `CommandCopyRow.swift:103`). | Label icon-only buttons; expose the dropdown; add keyboard paths to onboarding. | VoiceOver + full-keyboard pass over Settings and Onboarding. |
| K-20 | ⬜ | Low | Dictionary data loss edges: imported entries with `userAdded == false` are silently dropped on next launch; corrupt `user_dictionary.json` silently resets to empty (no backup, no notice). | `CustomDictionaryManager.swift:103` (load filter), `:105–108` (silent reset). | Preserve a `.bak` of corrupt files + surface a notice; reconsider the `userAdded` filter on import. | Import JSON with `userAdded:false`, relaunch, entries persist (or documented behavior). |
| K-21 | ⬜ | Info | Inconsistencies: settings window created at 750 pt then min/max set to 900 pt; `import CoreAudio` mid-file. | `KalamApp.swift:361` vs `:370–384`; `:1155`. | Unify window widths; move imports to file top. | Visual + build check. |

---

## What looks solid — do NOT regress these

- **No network entitlement** (deliberate). Any new `URLSession`/network code in the app is a regression — review it hard.
- Sandbox + hardened runtime + library validation + dyld-env-vars disabled (`Kalam.entitlements`).
- Audio buffers are `secureZero()`'d (`KalamApp.swift:20–28`).
- **Transcript text is never logged** — only counts/timings with `privacy: .public`. Keep it that way.
- Security-scoped bookmark handling with stale-refresh and model-folder validation (`ModelsConfiguration.swift:245–272`).
- Clipboard restore guard is correct on success paths (changeCount + string equality).
- Dependency pins: FluidAudio `0.15.5`, HotKey `0.2.1` (pbxproj) + exact revisions in `Package.resolved`.
- `ModelHub.offlineMode` is enforced at app launch and in `ASRService.initialize` (`ASRService.enforceOfflineMode()`) — FluidAudio must never touch the network (see the 0.15.5 adoption dev-design doc); pinned by `FluidAudioOfflineModeTests`.
- Update mechanism is browser-only (`NSWorkspace.open`, no in-app network).
- `ASRService` is a clean actor; `PasteService` main-actor isolated; transcription task avoids `Task.detached`.
- Engine package tests: 32/32 green via `./scripts/test-engine.sh`.

## How to use this file

1. **Claim an item** → flip status to `🔄`, do the work, run the verification.
2. **Mark `✅` only when implemented AND verified** — a change without its verification step passing stays `🔄`.
3. **Line numbers drift** — re-locate evidence in current code before trusting it.
4. **New findings** → append with the next free K-ID and today's date.
5. **Test commands:**
   - Headless engine: `./scripts/test-engine.sh` (from repo root)
   - Full suite (needs Xcode): `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
6. When a priority group is fully `✅`, optionally convert its rows into a short "resolved" changelog section at the bottom rather than deleting them (keeps history for other agents).
