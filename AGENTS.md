# AGENTS.md

## Project Overview

Kalam is a privacy-first macOS menu bar dictation app (Swift 6, deployment target macOS 14.6, AppKit + SwiftUI). Flow: global hotkey (push-to-talk) → record audio → on-device ASR (FluidAudio / Parakeet TDT CoreML models, user-provisioned from local disk) → deterministic text cleanup → optional ITN normalization → custom dictionary replacements → paste into the frontmost app (CGEvent unicode → Cmd+V via clipboard → Accessibility fallback). **All processing is on-device; the app has NO network entitlement by design.** The repo also contains a Vite/React landing page (`landing-page/`, deployed to singhkays.github.io/kalam) and project docs in `app/docs/`.

## Hard invariants — do not regress

- **No network code.** The sandbox deliberately omits `com.apple.security.network.client`. Any `URLSession`, socket, or network call in the app is a regression — flag it in review.
- **Never log transcript or audio content.** Logs may contain only counts/timings with `privacy: .public`. Policy: `app/docs/SECURITY.md`.
- **Sandbox + hardened runtime + library validation stay enabled** (`app/Kalam/Kalam.entitlements`).
- **Deterministic cleanup/dictionary logic lives in `app/Packages/KalamTextEngine/`** (SwiftPM package, headless-testable via Swift Testing). Keep new pure-text logic there with tests. The app shell (`TextCleanupService`) only adds the AppKit-dependent grammar pass on top.
- **Audio buffers are `secureZero()`'d after use** (`app/Kalam/Services/AudioRecorder.swift`).
- **Clipboard-restore guard semantics stay intact**: restore the user's clipboard only if pasteboard changeCount is unchanged AND content equals what Kalam wrote.

## Repo layout

| Path | What it is |
|---|---|
| `app/` | Xcode project (`Kalam.xcodeproj`) + app source (`Kalam/`) + Xcode tests (`KalamTests/`) |
| `app/Packages/KalamTextEngine/` | SwiftPM package: deterministic cleanup engine + dictionary compiler (`Sources/`) + Swift Testing suite (`Tests/`) |
| `app/docs/` | `DEVELOPER_GUIDE.md` (architecture/runtime flow — source of truth), `SECURITY.md`, **`IMPROVEMENT_PLAN.md` (read before changing code)** |
| `landing-page/` | Vite/React marketing site |
| `scripts/` | `test-engine.sh` — headless engine tests (maintained). **`app/scripts/test-engine.sh` is stale/broken — never use it.** |
| `.github/workflows/` | `release.yml` (tag → build, test, DMG, GitHub release), `deploy-kalam-landing.yml` |
| `build.sh` | DMG packaging script (used by CI) |

## App architecture map (`app/Kalam/`)

| File | Responsibility |
|---|---|
| `KalamApp.swift` | Entry, AppDelegate, hotkey state machine (hold/toggle/doubleTap/holdOrToggle), recording orchestration, paste pipeline, chime. Pure orchestration since K-03 (2026-08-11); components live in the files below. |
| `DictationOverlayController.swift` | Dictation overlay UI: `DictationOverlayController` + `OverlayCapsuleView` + `WaveformView` (AppKit/CALayer capsule with rainbow border, waveform, target-app row). |
| `Services/AudioRecorder.swift` | `AudioRecorder` (AVAudioEngine + 16 kHz mono resample, tap callback, secureZero'd buffers) + `AudioRecorderError` + `Array<Float>.secureZero()`. |
| `Services/SilenceTrimmer.swift` | `SilenceTrimmer` — energy-based endpointer with hysteresis + `normalizePeak`. |
| `Services/SystemAudioDucker.swift` | `SystemAudioDucker` — CoreAudio virtual-main-volume ducking + `Float.clamped(to:)`. |
| `Services/HotkeyListener.swift` | `HotkeyListener` — HotKey package + modifier-only (side-key) monitoring, PTT callbacks. |
| `AccessibilityHelper.swift` | `AccessibilityHelper` — AX trust check/prompt + explainer. |
| `AppRelauncher.swift` | `AppRelauncher` — `open -n` relaunch (K-12 candidate). |
| `AppMetadata.swift` | `KalamExternalLinks` + `KalamAppVersion` (used by Settings UI and AppDelegate). |
| `SettingsUI.swift` | Settings window: Word Replacement / Keyboard / Refine / Models tabs. Giant view (K-04). |
| `OnboardingFlow.swift` | 4-step setup (Microphone, Accessibility, Hotkey, Model) + `OnboardingFlowController`. |
| `ModelsConfiguration.swift` | Model version metadata, security-scoped bookmark (UserDefaults `models.modelLibraryBookmark`), availability checks. |
| `ModelSetupSupport.swift`, `ModelAcquisitionPanel.swift` | Model folder picker + **copy-paste-only** `hf download` command (the app never executes shell commands). |
| `CustomDictionaryManager.swift` | `@MainActor`; `~/Library/Application Support/Kalam/user_dictionary.json`; debounced save; compiles rules via `ReplacementCompiler`. |
| `PTTHotkeyConfiguration.swift` | Activation modes + key combinations + persistence. |
| `SettingsConfiguration.swift` | General + microphone config; UserDefaults keys. |
| `TextCleanupService.swift` | Wraps `TextCleanupEngine` + grammar pass (`NSSpellChecker`, timeout-bounded, `>1200` chars skipped). |
| `NemoTextProcessing.swift` | ITN bridge to `NemoTextProcessing.xcframework` (optional at runtime). |
| `Services/ASRService.swift` | **Actor** — FluidAudio integration, model warmup. |
| `Services/PasteService.swift` | `@MainActor` — CGEvent/Cmd+V/AX paste + clipboard snapshot/restore. |
| `AccessibilityFocusResolver.swift` | AX focused-element resolution for paste targeting and overlay placement. |
| `RuntimeCapabilities.swift` | Sandbox/entitlement introspection. |
| `KalamControlStyles.swift`, `KalamTheme.swift`, `SetupDropdownField.swift`, `OnboardingActionStyles.swift`, `CommandCopyRow.swift` | Shared UI components/styles. |
| `KalamTestRunner.swift` | Special-mode pipeline test harness. |

## Pipeline order — do not reorder without updating `app/docs/DEVELOPER_GUIDE.md`

```
ASR → TextCleanupService.clean → ITN (if enabled) → CustomDictionaryManager.apply → PasteService.paste
```

## Concurrency posture (Swift 6 language mode)

- `ASRService` = actor (all mutable ASR state actor-isolated).
- `PasteService` = `@MainActor`.
- `AppDelegate` = `@MainActor`; transcription runs as an actor-inherited `Task` (no `Task.detached`).
- New background work: go behind an actor boundary, or capture only immutable `Sendable` values.

## Build & test (verified)

| Command | When | Notes |
|---|---|---|
| `./scripts/test-engine.sh` | Engine package tests (headless, no Xcode) | From repo root; needs brew Swift (`/opt/homebrew/opt/swift/bin/swift`); 32 tests green at review time |
| `cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Full suite (Xcode) | Covers grammar/ITN/onboarding/integration; requires Xcode |
| `./build.sh` (or CI) | DMG build | arm64, ad-hoc signing when `SIGNING_IDENTITY` unset |
| `cd landing-page && npm ci && npm run build` | Landing page | |

## Common tasks

- **Add a cleanup rule** → engine package: `app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` + an `@Test` in `Tests/KalamTextEngineTests/` + run `./scripts/test-engine.sh`.
- **Add a dictionary feature** → `DictionaryEntry.swift` / `ReplacementCompiler.swift` + tests (note: `wholeWord`/`morphological` flags are currently no-ops — K-05).
- **Change paste behavior** → `Services/PasteService.swift`; respect the clipboard guard; test the failure path (K-02).
- **Touch the grammar pass** → `TextCleanupService.swift`; tests are Xcode-only (`KalamTests/TextCleanupServiceTests.swift`); consider moving logic into the engine for headless tests (K-06).
- **Add Settings UI** → `SettingsUI.swift` (or split per K-04); use `KalamTheme`/`KalamControlStyles`; label icon-only buttons (K-19).

## Improvement-plan protocol

- `app/docs/IMPROVEMENT_PLAN.md` tracks open work (K-01…K-21) with status, evidence, fixes, and verification steps. **Read it before starting any change.**
- Claim an item by flipping its status to `🔄`; mark `✅` **only after implement + verify**. Add new findings with the next free K-ID.
- Line numbers in the plan drift as code changes — re-grep before trusting them.

## Shared-mount git workflow (IMPORTANT)

This repo lives on a shared VirtIOFS mount; **other agent sessions may commit/edit concurrently**. Follow `concurrent-session-git-workflow`:

- Before `git add`/`commit`: run `git status` + `git diff --stat`; **re-read files you're about to overwrite** (a sibling may have changed them since your last read).
- `error: fsmonitor_ipc__send_query: unspecified error on '.git/fsmonitor--daemon.ipc'` is **cosmetic** on this mount (exit code stays 0; commits land normally). Do not abort or report git broken because of it.
- `.git/index.lock` present? `rm -f .git/index.lock`, then re-check `git status` before retrying.
- Never run two subagents against the same file simultaneously.
- Prefer `git worktree add -b feat/<name> <dir>` for isolated small changes.
- Prove a commit landed with `git show <hash> -- <file>`, not an echoed hash.
- Never use `patch` to edit shell scripts (backslash corruption) — rewrite the whole file and `bash -n` it.
- Don't trust subagent self-reports: verify with `git status`/`git diff`.

## Gotchas

- `app/.grok/` and `app/.hermes/` are local session artifacts — never commit them (gitignore gap tracked as K-18).
- `app/scripts/test-engine.sh` is stale/broken (wrong package path) — use root `scripts/test-engine.sh` (K-15).
- `.build/`, `xcuserdata/`, `DerivedData/` are gitignored.
- The `hf download` command shown in the Models UI is **copy-paste only** — the app never executes it.
- Models are user-provisioned; the app validates required `.mlmodelc` directory presence, not content integrity (documented in `SECURITY.md`).
- `app/docs/DEVELOPER_GUIDE.md` is the architecture source of truth — keep it in sync when the pipeline or configuration changes.
