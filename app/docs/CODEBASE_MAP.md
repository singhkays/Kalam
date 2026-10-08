# Kalam Codebase Map

Agent-facing map of what lives where and why. `DEVELOPER_GUIDE.md` is the
runtime/architecture source of truth; this file is the navigation layer over it.

Line counts are approximate as of 2026-08-25. Re-grep before trusting any line
number; symbols are verified against the working tree.

## The one-sentence version

Global hotkey → record 16 kHz mono audio → on-device Parakeet ASR (FluidAudio)
→ deterministic cleanup → optional ITN → custom dictionary → paste into the
frontmost app. Everything local; the sandbox has no network-client entitlement.

## Repo top level

| Path | What it is |
|---|---|
| `app/` | Xcode project + app source + tests |
| `app/Kalam/` | App target source (see file map below) |
| `app/Kalam/Services/` | Long-lived components extracted from the old god-file (god-file extraction onward) |
| `app/Kalam/Settings/` | The entire settings UI |
| `app/Packages/KalamTextEngine/` | SwiftPM package: deterministic text logic + headless tests |
| `app/KalamTests/` | Xcode test target (folder-synced; needs Xcode) |
| `app/docs/` | `DEVELOPER_GUIDE.md` (architecture/runtime source of truth), `SECURITY.md`, this map |
| `landing-page/` | Vite/MUI React marketing site (deploys to singhkays.github.io/kalam) |
| `scripts/` | `test-engine.sh` (headless engine tests), `parakeet-smoke.sh` (real-model ASR), `weight-probe-v131.swift` (font probe) |
| `build.sh` | DMG packaging (used by CI release.yml) |
| `.github/workflows/` | `release.yml` (tag → build/test/DMG/release), `deploy-kalam-landing.yml` |

## Request lifecycle (dictation)

```
HotkeyListener ──► PTTStateMachine ──► AppDelegate.apply(event)
                                            │
                              startRecording / stopRecordingAndTranscribe
                                            │
        AudioRecorder (AVAudioEngine tap)   │
          └► AudioCaptureExchange  ◄────────┘   render thread never blocks (render-thread audio lock fix)
            publish() try-lock, drop+count on contention
                                            │
                     stop: SilenceTrimmer → SpeechQualityGuard (reject noise)
                                            │
                     ASRService.transcribe(samples)      [actor]
                                            │
                     RecordingSessionTracker.isCurrent(generation)?  (stale-recording paste guard staleness)
                                            │
                     TranscriptPostProcessor.process     [Sendable, off-main] (off-main post-processing)
                       ├─ TextCleanupEngine.clean        [KalamTextEngine]
                       ├─ ITN via NemoTextProcessing + ITNSpanProtector (ITN span protection)
                       │    ITN answers to cleanup master switch (cleanup master toggle gating ITN);
                       │    dictionary stays independent of it
                       └─ ReplacementCompiler.compile(entries).apply
                                            │
                     PasteService.paste / paste(into:)   [@MainActor]
                       CGEvent unicode → Cmd+V (guarded clipboard restore) → AX insert
                       PasteRouting.target decides frontmost vs captured element (record-time paste target capture)
                                            │
                     DictationOverlayController (status, held-transcript actions)
```

Supporting cast:

- `AudioDeviceMonitor` — CoreAudio topology + wake listeners; re-prepares the
  engine graph after sleep/dock events (microphone recovery after sleep or device change).
- `SystemAudioDucker` — manual CoreAudio volume ducking while recording,
  runtime-verified under sandbox.
- `RecordingSessionTracker` — generation counter so a stale transcription task
  never pastes (stale-recording paste guard).

## app/Kalam — file-by-file

### Orchestration core

| File | ~LOC | Responsibility |
|---|---|---|
| `KalamApp.swift` | 2294 | `@main` + `AppDelegate`. Pure orchestration since god-file extraction: applies PTTStateMachine events, owns recording lifecycle (`startRecording` :1243, `stopRecordingAndTranscribe` :1497), hosts the settings window (`openSettingsWindow` :624), onboarding windows, chime, latency-tuning defaults. The `Settings {}` scene is deliberately inert (settings redesign comment at :29). |
| `DictationOverlayController.swift` | 592 | Overlay **orchestration** (AppKit window ownership, placement, fades, auto-hide, AX focus hints, telemetry) + `OverlayAction` (incl. `pasteHeldTranscript` support for record-time paste target capture). Rendering lives in the `Indicator*` files below — the AppKit content layer was deleted at the SwiftUI cutover (`556d70a`). |
| `IndicatorSurfaces.swift` | 353 | SwiftUI indicator surfaces: `IndicatorStadium` chrome, `IndicatorRing` (green conic ring + glow), `ShimmerDots`/`BreathingDot`, `IndicatorLevelGlyph`, `IndicatorAppIcon`, `IndicatorDeckSurface`/`IndicatorPillSurface`, and the `IndicatorCapsuleRootView` window root. |
| `IndicatorTokens.swift` | 82 | Every indicator dimension/alpha/font constant. Single source for surfaces so the deck and pill cannot drift. |
| `IndicatorWaveformView.swift` | 36 | SwiftUI view wrapping the published waveform history into deck bars. |
| `IndicatorStateModel.swift` | 101 | Pure model: the 5 canonical states (listening/pausing/transcribing/held/blocked) + the fallback law (held/blocked always render machined) + the compact-surface rule. |
| `IndicatorStyle.swift` | 34 | Persisted style enum (`machined`/`whisper`) + `migrating(fromStored:)` (unknown/absent → machined). The at-the-caret chip was rejected and removed 2026-09-12. |
| `IndicatorWaveformMath.swift` | 200 | Framework-free metering: window RMS → dBFS, absolute floor + slow-adaptive ceiling (`adaptedCeiling`), deck envelope, 3-bar glyph levels. Headless-testable; do not retune constants without updating `IndicatorWaveformMathTests`. |
| `IndicatorPresentationState.swift` | 73 | The single published state pushed once per transition (revision-bumped, timer ticks excluded) — the indicator's only state source. |
| `RecordingSessionTracker.swift` | 41 | Monotonic session generations; stale-task paste guard (stale-recording paste guard). |

### Services (`app/Kalam/Services/`)

| File | ~LOC | Responsibility |
|---|---|---|
| `PTTStateMachine.swift` | 246 | Pure hold/toggle/doubleTap/holdOrToggle decision logic. Emits `.start(TriggerMode)` / `.stop` / `.suppressNextKeyUp`; `State` mutators are compile-checked outcome syncs. A start is latched **pending** at the `.start` event (`beginPending`/`commitPending`/`rollbackPending`) so the bounded ~170-450 ms engine start can't be mistaken for an idle machine (`f97e025`). 23 unit pins in KalamTests. |
| `HotkeyListener.swift` | 294 | HotKey package global hotkey + modifier-only side-key monitoring → PTT callbacks. |
| `AudioRecorder.swift` | 317 | AVAudioEngine capture, tap callback, 16 kHz mono resample, `secureZero()` buffers, `AudioRecorderError`. |
| `AudioCaptureExchange.swift` | 300 | render-thread audio lock fix seam between render thread and consumers. `publish()` uses a try-lock; contention drops counted (`dropped=`), render thread never blocks. Session-generation guards stop stale teardown. |
| `SilenceTrimmer.swift` | 210 | Energy-based endpointer (hysteresis, hangover, duration fallback) + peak normalization. Also exports `windowedEnergiesDb` / `percentile` used by SpeechQualityGuard. |
| `SpeechQualityGuard.swift` | 40 | Rejects noise/near-silence clips pre-ASR (Parakeet hallucinates "yeah" on boosted room tone). Requires sustained windows ≥ noise floor + 6 dB. |
| `ASRService.swift` | 271 | **Actor** wrapping FluidAudio. `initialize(version:)`, warmup, `transcribe(samples:)`. `enforceOfflineMode()` pins `ModelHub.offlineMode` (no-network invariant). Status/errors model missing vs invalid model folders. |
| `TranscriptPostProcessor.swift` | 111 | off-main post-processing: pure post-ASR stages (cleanup → ITN → dictionary) off-main. Holds only Sendable snapshots. Never logs transcript text. cleanup master toggle gating ITN: ITN keyed to cleanup master switch. |
| `PasteService.swift` | 348 | `@MainActor`. Three strategies: CGEvent unicode → Cmd+V clipboard → AX insert. `PasteboardSnapshot`/restore guarded by changeCount + content equality. `PasteRouting.target` (:158) picks frontmost vs captured-element paste (record-time paste target capture). |
| `AudioDeviceMonitor.swift` | 177 | `@MainActor`. Debounced CoreAudio device-change + NSWorkspace wake notifications (microphone recovery after sleep or device change). |
| `SystemAudioDucker.swift` | 142 | CoreAudio virtual-main ducking with fade; `Float.clamped(to:)`. Runtime-verified because sandboxed CoreAudio varies. |

### Settings UI — `app/Kalam/Settings/`

Map/dive information architecture in a borderless 980×660 `NSWindow`. There is
no tabbed settings UI anymore; `SettingsUI.swift` was deleted in the settings redesign.

| File | ~LOC | Role |
|---|---|---|
| `SettingsWindow.swift` | 112 | `SettingsRoot` (NavigationStack, path depth 0=map / 1=dive) + borderless window hosting from AppDelegate. |
| `LiveSettingsBacking.swift` | 397 | **The only live-store access.** Adapts `GeneralSettingsConfiguration` / `MicrophonePriorityConfiguration` / `PTTHotkeyConfiguration` / textCleanup / dictionary manager behind `SettingsBacking`; `onChange` stream drives revision counting. |
| `InMemorySettingsStore.swift` | 154 | Test/fake store implementing the same protocol. |
| `SettingsBacking.swift` | 307 | Protocol + `IndicatorPlacement` (:59). the settings UI owns no UserDefaults keys — rule stated at top of file. |
| `SettingsModel.swift` | 351 | `@Observable` façade: attention priority (engine > mic > key > empty dictionary), hero strings, status tones. |
| `Destination.swift` | 103 | Six destinations (beingHeard/trigger/cleanup/dictionary/engine/updates); journey vs maintenance split. |
| `MapView.swift` `DiveView.swift` `ContentsNav.swift` `SettingsScrollView.swift` | | Navigation chrome. |
| `Panes/` (BeingHeard, Trigger, Cleanup, Dictionary, Engine, Updates) | | One dive pane per destination. DictionaryPane (447 LOC) is the largest. |
| `Controls/` (HotkeyControl, KeyCapture, MapCard, PaperSegment, PaperToggle, PrivacyPill) | | Shared controls incl. chord capture. |
| `SettingsTokens.swift` | 545 | Typography (`SettingsFont`: Instrument Serif display-only, New York book with opsz pinned to point size, SF Pro/SF Mono body) + color/radius tokens + `nsWeight` anchor-piecewise CSS→AppKit mapping. Fonts lazy-registered once per process. |

The authoritative visual values live in `SettingsTokens.swift` (typography,
weights, chrome colors); treat it, not any external mockup, as the source of
truth for settings styling.

### Onboarding

| File | ~LOC | Role |
|---|---|---|
| `OnboardingFlow.swift` | 713 | Live state: `OnboardingFlowController`, `OnboardingStatusSnapshot.evaluate(...)` (the status seam), `OnboardingMode` (:105). Cards never mark requirements complete themselves; refresh → prepareRuntimeIfPossible → refresh. |
| `OnboardingDeckView/Cards/Components/Model/Tokens.swift` | ~2600 | Presentation-only card deck (paper-card visual language, progress rail, Escape close, reduced motion). No second persistence schema. Tokens resolve light/dark; light values follow the landing-page language, dark from v3.0 handoff. |
| `ModelSetupSupport.swift` `ModelAcquisitionPanel.swift` `ModelSetupPresentationState.swift` | ~650 | Model folder picker + copy-paste-only `hf download` command (POSIX shell-quoted; the app never executes shell commands). `ModelSetupPresentationState` models partial-download recovery. |
| `OnboardingActionStyles.swift` | 76 | Deck action-button styles. |

### Config, persistence, misc

| File | ~LOC | Role |
|---|---|---|
| `SettingsConfiguration.swift` | 401 | `GeneralSettingsConfiguration`, `MicrophonePriorityConfiguration` (+ change notification), `MicrophoneDeviceDescriptor`, `MicrophoneDeviceService` (:98), AudioDeviceDebug. Note: mic config/service live HERE, not in separate files (older docs point elsewhere). |
| `PTTHotkeyConfiguration.swift` | 571 | Activation modes, key combinations, settings redesign custom captured chords (`pttHotkey.custom*`), persistence/normalization. |
| `ModelsConfiguration.swift` | 317 | `ASRModelVersion` (v2/v3/tdtCtc110m), security-scoped bookmark (`models.modelLibraryBookmark`), availability checks over required `.mlmodelc` dirs. |
| `CustomDictionaryManager.swift` | 180 | `@MainActor` singleton. `~/Library/Application Support/Kalam/user_dictionary.json`, debounced save, corrupt-file `.bak` preservation, compiles via ReplacementCompiler. |
| `AccessibilityFocusResolver.swift` | 235 | AX focused-element resolution for paste targeting + overlay placement (descendant search depth 12, 0.75 s messaging timeout). |
| `AccessibilityHelper.swift` | 29 | AX trust check/prompt + explainer. |
| `AppRelauncher.swift` | 63 | Relaunch via `NSWorkspace.openApplication` + orderly terminate gated on launch success (relaunch lifecycle rework). |
| `AppMetadata.swift` | 48 | Release URL + version display. |
| `RuntimeCapabilities.swift` | 42 | Entitlement introspection (`isNetworkConstrained`). |
| `NemoTextProcessing.swift` | 182 | Swift wrapper over `CNemoTextProcessing` (xcframework). Compile-time gated; unavailable ⇒ ITN skipped. |
| `KalamTheme.swift` `CommandCopyRow.swift` `SetupDropdownField.swift` `OnboardingActionStyles.swift` | | Shared UI components/styles. |
| `KalamTestRunner.swift` | 90 | DEBUG special-mode pipeline harness (text through all engine stages). |
| `PrivacyInfo.xcprivacy`, `Assets.xcassets`, `Resources/Fonts/` | | Bundle resources. Only Instrument Serif ships (the settings v1.2 visual alignment trimmed the Plex/Jakarta families). |

## KalamTextEngine package (`app/Packages/KalamTextEngine/`)

All deterministic pure-text logic; headless-testable (Swift Testing, no Xcode):

| Source | Public surface |
|---|---|
| `TextCleanupEngine.swift` | `TextCleanupEngine.clean(_:configuration:) -> TextCleanupResult` (+stats). Fillers, backtrack cues, spoken list formatting, punctuation. Grammar pass (NSSpellChecker) lives here behind `canImport(AppKit)`, timeout-bounded, skipped >1200 chars. |
| `TextCleanupConfiguration.swift` | Flag struct + `TextCleanupGrammarMode` (off/light/full); UserDefaults save/load. |
| `DictionaryEntry.swift` | Codable entry model (whole-word + suffix matching enforced; legacy flags deleted in dead dictionary flags removal). |
| `ReplacementCompiler.swift` | `ReplacementCompiler.compile(entries:)` → `CompiledReplacementEngine.apply(to:) -> (String, Int)`. Phrase rules first (longest first), then word rules. |
| `ITNSpanProtector.swift` | `protect(_:)` / `restore(_:spans:)` around Nemo ITN so ranges, idioms, digit sequences survive (ITN span protection). |
| `CaseHelper.swift` | Case mimicry helpers (Title Case vs Mixed Case brands like iPad). |

Tests mirror these files under `Tests/KalamTextEngineTests/` (4 suites, run by
`./scripts/test-engine.sh`).

## Tests

| Suite | Runner | Notes |
|---|---|---|
| Engine package | `./scripts/test-engine.sh` | Headless; brew Swift toolchain required (`/opt/homebrew/opt/swift/bin/swift`). |
| `app/KalamTests/` | `xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Folder-synced membership — adding a file to `KalamTests/` just works; no pbxproj edit needed for new app-source files either. |
| Real-model smoke | `./scripts/parakeet-smoke.sh` | Needs `<repo>/Models/parakeet-*` folders or `KALAM_MODEL_LIBRARY`; exit 2 = nothing ran (skip, not fail). |

Test-file highlights: `PasteServiceTests` (clipboard guard), `PTTStateMachineTests`,
`AudioCaptureExchangeTests` (render-thread stall regression), `SpeechQualityGuardTests`,
`TranscriptPostProcessorTests`, `ITNShapeProbeTests` (Nemo shape canaries),
`LiveSettingsBackingTests`/`SettingsModelTests`/`SettingsFontTests` (settings),
`RealModelSmokeTests` (offline-mode invariant end-to-end),
`engine_golden_tests.json` (golden pipeline cases consumed by integration tests).

## Docs layout

| Path | Content |
|---|---|
| `app/docs/DEVELOPER_GUIDE.md` | Architecture/runtime source of truth. Keep in sync when the pipeline or configuration changes. |
| `app/docs/SECURITY.md` | Threat posture: sandbox, no network entitlement, logging policy (counts/timings only, never transcript/audio). |

## Landing page

Vite + MUI/React in `landing-page/src` (entry `main.tsx`, SSR via
`entry-server.tsx`, prerender step in `npm run build`). Deploys to
`singhkays.github.io/kalam` via `deploy-kalam-landing.yml`. Its font trio and
panel styling are the reference for the app's light-mode design language
(onboarding deck tokens cite it directly).

## Hard invariants (quick list — full text in AGENTS.md / SECURITY.md)

1. No network code; no `com.apple.security.network.client`.
2. Never log transcript or audio content.
3. Sandbox + hardened runtime + library validation stay on.
4. Deterministic text logic goes in KalamTextEngine with tests.
5. Audio buffers `secureZero()`'d after use.
6. Clipboard-restore guard semantics intact (changeCount + content equality).
7. Pipeline order ASR → clean → ITN → dictionary → paste; update DEVELOPER_GUIDE if it ever changes.

## Known doc drift (as of 2026-10-01)

- Older references to `SettingsUI.swift`, `MicrophonePriorityConfiguration.swift`
  and `MicrophoneDeviceService.swift` as separate files are stale: mic config
  and device service live inside `SettingsConfiguration.swift`; `SettingsUI.swift`
  was deleted in the settings redesign.
- Spec paths mentioning `kalam-settings-redesign*` folders are historical; those
  directories no longer exist. Current design packages are `kalam-compass-*`
  and `kalam-onboarding-v*`.
- References to the AppKit indicator content layer (`OverlayCapsuleView`,
  `WaveformView`, `PillLevelGlyphView`, `CaretChipView`) and to the "rainbow
  border" indicator are stale: the content layer moved to SwiftUI (`556d70a`)
  and the rainbow border was retired in the K-48 redesign.
- The at-the-caret indicator chip (`CaretAnchorResolver`, `IndicatorStyle.caret`)
  was rejected and removed 2026-09-12; stored `caret` values migrate to
  `machined`. Dev plans `2026-08-25-indicator-styles.md` and
  `2026-08-26-indicator-B-green-ring.md` still describe it as planned.
