# AGENTS.md

## Project Overview

Kalam is a privacy-first macOS menu bar dictation app (Swift 6, deployment target macOS 14.6, AppKit + SwiftUI). Flow: global hotkey (push-to-talk) → record audio → on-device ASR (FluidAudio / Parakeet TDT CoreML models, user-provisioned from local disk) → deterministic text cleanup → optional ITN normalization → custom dictionary replacements → paste into the frontmost app (CGEvent unicode → Cmd+V via clipboard → Accessibility fallback). **All processing is on-device; the app has NO network entitlement by design.** The repo also contains a Vite/React landing page (`landing-page/`, deployed to singhkays.github.io/kalam) and project docs in `app/docs/`.

## Hard invariants — do not regress

- **No network code.** The sandbox deliberately omits `com.apple.security.network.client`. Any `URLSession`, socket, or network call in the app is a regression — flag it in review.
- **Never log transcript or audio content.** Logs may contain only counts/timings with `privacy: .public`. Policy: `app/docs/SECURITY.md`.
- **Sandbox + hardened runtime + library validation stay enabled** (`app/Kalam/Kalam.entitlements`).
- **Deterministic cleanup/dictionary logic lives in `app/Packages/KalamTextEngine/`** (SwiftPM package, headless-testable via Swift Testing). Keep new pure-text logic there with tests. The grammar pass (AppKit `NSSpellChecker`) lives in `TextCleanupEngine` behind `canImport(AppKit)`.
- **Audio buffers are `secureZero()`'d after use** (`app/Kalam/Services/AudioRecorder.swift`).
- **Clipboard-restore guard semantics stay intact**: restore the user's clipboard only if pasteboard changeCount is unchanged AND content equals what Kalam wrote.

## Repo layout

| Path | What it is |
|---|---|
| `app/` | Xcode project (`Kalam.xcodeproj`) + app source (`Kalam/`) + Xcode tests (`KalamTests/`) |
| `app/Packages/KalamTextEngine/` | SwiftPM package: deterministic cleanup engine + dictionary compiler (`Sources/`) + Swift Testing suite (`Tests/`) |
| `app/docs/` | `DEVELOPER_GUIDE.md` (architecture/runtime flow — source of truth), `SECURITY.md`, `CODEBASE_MAP.md` (agent-facing file map) |
| `landing-page/` | Vite/React marketing site |
| `scripts/` | `test-engine.sh` — headless engine tests (single entry point since stale duplicate test script removal). |
| `.github/workflows/` | `release.yml` (tag → build, test, DMG, GitHub release), `deploy-kalam-landing.yml` |
| `build.sh` | DMG packaging script (used by CI) |

## App architecture map (`app/Kalam/`)

| File | Responsibility |
|---|---|
| `KalamApp.swift` | Entry, AppDelegate, hotkey event application (decision logic in `Services/PTTStateMachine.swift`), recording orchestration, paste pipeline, chime. Pure orchestration since god-file extraction (2026-08-11); components live in the files below. |
| `DictationOverlayController.swift` | Dictation overlay UI: `DictationOverlayController` + `OverlayCapsuleView` + `WaveformView` (AppKit/CALayer capsule with rainbow border, waveform, target-app row). |
| `Services/AudioRecorder.swift` | `AudioRecorder` (AVAudioEngine + 16 kHz mono resample, tap callback, secureZero'd buffers) + `AudioRecorderError` + `Array<Float>.secureZero()`. |
| `Services/SilenceTrimmer.swift` | `SilenceTrimmer` — energy-based endpointer with hysteresis + `normalizePeak`. |
| `Services/SystemAudioDucker.swift` | `SystemAudioDucker` — CoreAudio virtual-main-volume ducking + `Float.clamped(to:)`. |
| `Services/HotkeyListener.swift` | `HotkeyListener` — HotKey package + modifier-only (side-key) monitoring, PTT callbacks. |
| `Services/PTTStateMachine.swift` | `PTTStateMachine` — pure hold/toggle/doubleTap/holdOrToggle decision logic emitting events (PTT state machine test coverage); `AppDelegate` applies them. |
| `AccessibilityHelper.swift` | `AccessibilityHelper` — AX trust check/prompt + explainer. |
| `AppRelauncher.swift` | `AppRelauncher` — relaunch via `NSWorkspace.openApplication` + orderly `NSApp.terminate` gated on launch success (relaunch lifecycle rework). |
| `AppMetadata.swift` | `KalamExternalLinks` + `KalamAppVersion` (used by Settings UI and AppDelegate). |
| `SettingsUI.swift` | Settings window shell: `SettingsView` orchestration (tab state, config load/persist). Per-tab views live in `Kalam/Settings/`. |
| `OnboardingFlow.swift` | 4-step setup (Microphone, Accessibility, Hotkey, Model) + `OnboardingFlowController`. |
| `ModelsConfiguration.swift` | Model version metadata, security-scoped bookmark (UserDefaults `models.modelLibraryBookmark`), availability checks. |
| `ModelSetupSupport.swift`, `ModelAcquisitionPanel.swift` | Model folder picker + **copy-paste-only** `hf download` command (the app never executes shell commands). |
| `CustomDictionaryManager.swift` | `@MainActor`; `~/Library/Application Support/Kalam/user_dictionary.json`; debounced save; compiles rules via `ReplacementCompiler`. |
| `PTTHotkeyConfiguration.swift` | Activation modes + key combinations + persistence. |
| `SettingsConfiguration.swift` | General + microphone config; UserDefaults keys. |
| `Packages/KalamTextEngine` | Cleanup engine incl. AppKit-gated grammar pass (`NSSpellChecker`, timeout-bounded, `>1200` chars skipped); headless-testable. |
| `NemoTextProcessing.swift` | ITN bridge to `NemoTextProcessing.xcframework` (optional at runtime). |
| `Services/ASRService.swift` | **Actor** — FluidAudio integration, model warmup. |
| `Services/PasteService.swift` | `@MainActor` — CGEvent/Cmd+V/AX paste + clipboard snapshot/restore. |
| `AccessibilityFocusResolver.swift` | AX focused-element resolution for paste targeting and overlay placement. |
| `RuntimeCapabilities.swift` | Sandbox/entitlement introspection. |
| `KalamControlStyles.swift`, `KalamTheme.swift`, `SetupDropdownField.swift`, `OnboardingActionStyles.swift`, `CommandCopyRow.swift` | Shared UI components/styles. |
| `KalamTestRunner.swift` | Special-mode pipeline test harness. |

## Pipeline order — do not reorder without updating `app/docs/DEVELOPER_GUIDE.md`

```
ASR → TextCleanupEngine.clean → ITN (if enabled) → CustomDictionaryManager.apply → PasteService.paste
```

## Concurrency posture (Swift 6 language mode)

- `ASRService` = actor (all mutable ASR state actor-isolated).
- `PasteService` = `@MainActor`.
- `AppDelegate` = `@MainActor`; transcription runs as an actor-inherited `Task` (no `Task.detached`).
- New background work: go behind an actor boundary, or capture only immutable `Sendable` values.

## Build & test (verified)

| Command | When | Notes |
|---|---|---|
| `./scripts/test-engine.sh` | Engine package tests (headless, no Xcode) | From repo root; needs brew Swift (`/opt/homebrew/opt/swift/bin/swift`); 41 tests green |
| `cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Full suite (Xcode) | Covers grammar/ITN/onboarding/integration; requires Xcode |
| `./build.sh` (or CI) | DMG build | arm64, ad-hoc signing when `SIGNING_IDENTITY` unset |
| `cd landing-page && npm ci && npm run build` | Landing page | |

## Common tasks

- **Add a cleanup rule** → engine package: `app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` + an `@Test` in `Tests/KalamTextEngineTests/` + run `./scripts/test-engine.sh`.
- **Add a dictionary feature** → `DictionaryEntry.swift` / `ReplacementCompiler.swift` + tests.
- **Change paste behavior** → `Services/PasteService.swift`; respect the clipboard guard; test the failure path (clipboard restore on failed paste).
- **Touch the grammar pass** → `app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` (AppKit-gated section); tests are headless via `./scripts/test-engine.sh`.
- **Add Settings UI** → `Kalam/Settings/` (tab views: `GeneralSettingsTab`, `ShortcutSettingsTab`, `CleanupSettingsTab`, `ModelsSettingsTab`, `UpdatesSettingsTab`, `WordReplacementView`; shared helpers in `SettingsSharedComponents.swift`; config persistence stays in the `SettingsView` shell). Use `KalamTheme`/`KalamControlStyles`; label icon-only buttons (accessibility labels for icon-only buttons).

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

- `app/.grok/` and `app/.hermes/` are local session artifacts — never commit them (gitignore gap tracked as session-artifact gitignore gap).
- `.build/`, `xcuserdata/`, `DerivedData/` are gitignored.
- The `hf download` command shown in the Models UI is **copy-paste only** — the app never executes it.
- Models are user-provisioned; the app validates required `.mlmodelc` directory presence, not content integrity (documented in `SECURITY.md`).
- `app/docs/DEVELOPER_GUIDE.md` is the architecture source of truth — keep it in sync when the pipeline or configuration changes.
