# Kalam

> Navigation aid: `app/docs/CODEBASE_MAP.md` is a file-by-file map of this
> codebase for agents (lifecycle diagram, per-file responsibility tables,
> test/doc layout). This guide remains the architecture/runtime source of truth.

Kalam is a macOS menu bar dictation app that records audio with push-to-talk, runs on-device ASR via `FluidAudio`, post-processes transcript text for dictation quality, applies custom dictionary replacements, and pastes text into the active app.

## Highlights

- On-device transcription (no cloud speech service required)
- Menu bar UX with global hotkey activation
- Premium 4-step guided onboarding (Microphone, Accessibility, Hotkey, Model)
- Activation modes:
  - Hold
  - Toggle
  - Double Tap
  - Hold or Toggle (short press toggles, long press holds)
- Microphone Priority System: Automatically selects preferred available microphones
- Custom dictionary with phrase-first then word replacement
- Deterministic text cleanup stage before dictionary replacement:
  - Filler word removal (`um`, `uh`, `you know`, `i mean`, etc.)
  - Backtrack cues (`scratch that`, `ignore that`, `delete that`, `actually`, `no`)
  - Spoken numbered list formatting (`one ... two ... three ...` -> numbered lines)
  - Punctuation/spacing cleanup
- Cleanup configuration persisted in UserDefaults
- System audio ducking while recording (optional; runtime-verified because sandboxed/CoreAudio behavior can vary)
- CGEvent unicode paste with guarded clipboard snapshot/restore and AX fallback
- Recording indicator with premium translucent design and noise texture (placed Mid-Top or Mid-Bottom)

## Usage Benefits

- On-device ASR (`FluidAudio`)
  - Keeps dictation private and available even with unstable network conditions.
- Flexible hotkey activation (Hold, Toggle, Double Tap, Hold-or-Toggle)
  - Supports both quick burst dictation and longer continuous speaking without mode switching.
- Text cleanup pipeline (`Refine` tab)
  - Reduces common ASR noise (fillers, spoken corrections, punctuation drift) before text reaches your app.
- Optional grammar pass (`Off` / `Light` / `Full`)
  - Lets you trade speed vs polish while enforcing a strict timeout so paste latency stays predictable.
- Custom dictionary (phrase-first, then word rules)
  - Corrects recurring domain terms, names, and product language consistently.
- ITN normalization (`NemoTextProcessing`)
  - Converts spoken forms into written forms (numbers, currency, emails), reducing manual edits.
- CGEvent unicode → Cmd+V (clipboard) → AX fallback
  - Pastes into the focused app while preserving prior clipboard contents on successful paste.
- System audio ducking while recording
  - Makes start/stop cues and speech monitoring easier to hear in noisy output environments.

## Architecture

Core files:

- `KalamApp.swift`
  - App entry point and `AppDelegate` (pure orchestration since god-file extraction)
  - Hotkey event handling/state machine (delegates to `Services/HotkeyListener.swift`)
  - Recording orchestration (delegates to `Services/AudioRecorder.swift` + `Services/SilenceTrimmer.swift`)
  - ASR service integration
  - Paste service
  - System audio ducking (delegates to `Services/SystemAudioDucker.swift`)
  - Dictionary engine/persistence
- `DictationOverlayController.swift`
  - Overlay **orchestration** (AppKit window ownership, placement, fades, auto-hide, AX focus hints, telemetry). Content is SwiftUI — see the `Indicator*` files below.
- `IndicatorSurfaces.swift` / `IndicatorTokens.swift` / `IndicatorWaveformView.swift`
  - SwiftUI indicator surfaces, design tokens, waveform view (the AppKit content layer was deleted at the SwiftUI cutover `556d70a`)
- `IndicatorStateModel.swift` / `IndicatorStyle.swift`
  - Pure 5-state model + fallback law; persisted style enum (`machined`/`whisper`; the at-the-caret chip was rejected and removed 2026-09-12)
- `IndicatorWaveformMath.swift`
  - Framework-free metering math (dBFS window, absolute floor + slow-adaptive ceiling, 3-bar glyph levels) — headless-testable
- `IndicatorPresentationState.swift`
  - The single state published once per transition; the indicator's only state source
- `Services/AudioRecorder.swift`
  - AVAudioEngine capture, 16 kHz mono resample, secureZero'd audio buffers, `AudioRecorderError`
- `Services/SilenceTrimmer.swift`
  - Energy-based endpointer (hysteresis, hangover, duration-aware fallback) + `normalizePeak`
- `Services/AudioCaptureExchange.swift`
  - render-thread audio lock fix render-thread/consumer exchange: `publish()` try-locks, drops + counts on contention so the render thread never blocks; session-generation guards against stale teardown
- `Services/SpeechQualityGuard.swift`
  - Rejects noise/near-silence clips before ASR (Parakeet hallucinates fillers on boosted room tone)
- `Services/TranscriptPostProcessor.swift`
  - off-main post-processing: pure post-ASR stages (cleanup → ITN → dictionary), Sendable snapshots, off-main; ITN answers to the cleanup master switch (cleanup master toggle gating ITN)
- `Services/AudioDeviceMonitor.swift`
  - microphone recovery after sleep or device change: debounced CoreAudio device-change + wake listeners; re-prepares the engine graph after sleep/dock events
- `RecordingSessionTracker.swift`
  - stale-recording paste guard: monotonic recording generations; a stale transcription task never pastes
- `Services/SystemAudioDucker.swift`
  - CoreAudio virtual-main-volume ducking while recording
- `Services/HotkeyListener.swift`
  - Global hotkey registration (HotKey package + modifier-only side-key monitoring), PTT callbacks
- `OnboardingFlow.swift` / `OnboardingActionStyles.swift`
  - Live onboarding state source: `OnboardingConfiguration`, `OnboardingStatusSnapshot`, and `OnboardingFlowController`
  - Permission handling (Microphone, Accessibility), hotkey progress, microphone selection, and model setup actions
  - Completion remains gated by live runtime readiness and is persisted by `KalamApp.AppDelegate`
- `OnboardingDeckModel.swift`, `OnboardingDeckView.swift`, `OnboardingDeckCards.swift`, and `OnboardingDeckComponents.swift`
  - Presentation-only card deck over the live onboarding controller
  - Conditional first-run/resume/repair routing for the four requirements
  - Paper-card visual language, textual progress rail, keyboard/Escape close, VoiceOver labels, and reduced-motion handling
  - No duplicate `UserDefaults` schema, service singleton, coordinator, or completion notification
- `PTTHotkeyConfiguration.swift`
  - Activation mode and key-combination modeling (incl. settings redesign custom captured chords under `pttHotkey.custom*`)
  - UserDefaults load/save and normalization
- `Settings/` (settings redesign, 2026-08-13 — replaces the old tabbed settings UI)
  - `SettingsWindow.swift` — `SettingsRoot` (map/dive `NavigationStack`, path 0 or 1) + `SettingsWindow` (borderless 980×660 NSWindow subclass, injected `onClose`, Cmd-W local monitor)
  - `LiveSettingsBacking.swift` — the ONLY live-store access: settings store protocol over `GeneralSettingsConfiguration` / `MicrophonePriorityConfiguration` / `PTTHotkeyConfiguration` / `ModelsConfiguration.textCleanup` / `CustomDictionaryManager`; `onChange` stream drives `SettingsModel`'s revision counter
  - `SettingsModel.swift` — `@Observable` façade; attention priority (engine > mic > key > empty dictionary), spanning, hero, map strings
  - `MapView` / `DiveView` / `ContentsNav` + `Controls/` + `Panes/` — settings UI views (typography and visual spec: Instrument Serif display-only, dark shell chrome; see `SettingsTokens.swift` for the authoritative values)
  - Typography (settings v1.2 visual alignment, 2026-08-13; supersedes the earlier web-font stack): the v1.2 locked design — **Instrument Serif display-only** (map hero 36 / dive display 34 / updates figure 48, bundled under `Resources/Fonts/`, lazy-registered once per process by `SettingsFont.ensureBrandFontRegistered()`), **New York** (`SettingsFont.book`) for small serif roles (map card titles, map foot, model name), body = SF Pro, kickers/states = SF Mono. CSS→AppKit weight mapping is anchor-piecewise (`nsWeight` in `SettingsTokens.swift`; probe-verified — the linear formula renders 500→476, 640→682). SF Symbols stay on the system font (icons are not typography)
  - Window presentation: AppDelegate `openSettingsWindow` hosts `SettingsRoot` (menu-bar "Settings…"); `.selectModelsSettingsTab` deep-links to the Engine dive
- `Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` / `TextCleanupConfiguration.swift`
  - Deterministic low-latency transcript cleanup pipeline
  - Optional grammar pass (`off` / `light` / `full`) with timeout budget (AppKit-gated)
- `app/Kalam/SettingsConfiguration.swift` — `GeneralSettingsConfiguration`, `MicrophonePriorityConfiguration`, and `MicrophoneDeviceService` all live here (no separate mic files; the old `SettingsUI.swift` tabbed shell was deleted in the settings redesign)

## Runtime Flow

1. User activates hotkey.
2. App resolves mode behavior (hold/toggle/double-tap/auto).
3. Recording starts:
   - Optional beep
   - Optional system ducking
   - Audio engine capture + conversion to 16 kHz mono Float32
   - Mid-hold stall watchdog (`MicStallMonitor`, 2.5 s grace + warn after 2 s with no tap callbacks): replaces the pill with a mic error live so a dead Bluetooth stream wastes seconds, not the whole hold; warn-only, capture/paste unchanged
4. Recording stops:
   - Adaptive post-roll
   - Capture-health gate (`CaptureHealthGuard`: refuses to paste when the mic delivered far less audio than the hold implies, or near-total digital silence — Bluetooth-dropout hardening; mic-settings error instead of a wrong transcript)
   - Silence trimming + peak normalization
   - ASR transcription
   - Text cleanup
   - Dictionary replacements
   - Paste to frontmost app
   - Clipboard restore (if unchanged externally)

Current ordering in code:

1. `ASR -> String`
2. `TextCleanupEngine.clean(...)`
3. `NemoTextProcessing.normalizeSentence(...)` (if ITN enabled + available), wrapped by `ITNSpanProtector` so ranges ("two to three"), idioms ("one of us"), and digit-by-digit sequences survive normalization (ITN span protection)
4. `CustomDictionaryManager.apply(...)`
5. paste

## Recording Start Latency

The keydown-to-indicator path is latency-sensitive; keep it ordered mic-first:

1. Hotkey event -> stale-transcription cancel -> readiness guards. Readiness comes
   from a **cached onboarding snapshot** (`OnboardingSnapshotCacheDecision`, 2 s TTL
   backstop). Anything that can change readiness MUST call
   `invalidateOnboardingSnapshot()` — the wired paths are the models/general/hotkey/
   mic-priority config notifications, app activation, wake, device change,
   `updateASRStatus`, and `refreshOnboardingState`. New readiness inputs need a new hook.
2. `prepareAudioForRecording()` normally early-returns (`AudioPrepareDecision`) because
   launch-time preparation walks the SAME priority-ordered microphone candidates.
3. `startCollecting()` (engine start) -> PTT state sync -> overlay shown with a fast
   recording-state fade from a prewarmed window (`overlay.prewarm()` at launch;
   placement screen persists across sessions so warm sessions place with no AX work).
4. ONLY THEN: chime + duck scheduling, then the record-time paste-target AX capture
   (every AX reference is messaging-timeout-bounded in `AccessibilityFocusResolver`,
   including returned elements) and a silent `refinePlacementIfMoved` correction.

Stage timing logs one line per successful start (`Recording start latency …`, info level,
timings only), gated by `LatencyTuningOptions.startStageTimingKey` and now appends a
`transport=` classification (see `AudioTransportTag`) plus cross-leg
`pttDownToFirstBufferMs` / `engineStartToFirstBufferMs` fields on the paired
`Recording timing` line (`SessionTimingMarks`). The engine-start floor
(~85-110 ms measured) is HAL spin-up and stays by design: the engine stops after each
session so the macOS mic indicator turns off.

## Stop-to-Paste Latency

Three levers cut the key-up-to-paste path; the pipeline order above is untouched.

**Energy-polled stop.** After PTT key-up, `stopTask` no longer sleeps the full post-roll:
`PostRollDecision` polls the trailing buffer's energy while `postRollForSegment` stays as
the floor and a hard ceiling of +150 ms (`AppDelegate.postRollEarlyExitExtraMaxMs`) bounds
the worst case to the old behavior plus that allowance. Between them, the stop finishes
after 3 consecutive silent polls of 20 ms analysis windows, under an absolute −35 dBFS cap
so a uniformly loud tail can never self-classify as silent. The generation contract is
unchanged — pin before the first suspension and finish via `finishStop(expectedGeneration:)`
— and `cancelRecording()` still tears down immediately.

**SNR-aware carry-over (K-54).** When `internal.latency.snrAwareEnabled` (default ON)
the ceiling and quiet gate extend per estimated room SNR and segment duration
(`PostRollDecision.ExtensionPolicy.snrAware`): room SNR from the recent waveform ring's
p95–p05 windowed energies; SNR < `trustSnrDb` (12 dB default) extends toward the 1.5 s
absolute backstop and never clips; trusted rooms (≥12 dB) extend while the tail is
speech-like (`floor+3 dB` sensitive threshold) and stop after ≥250 ms quiet, capped at
0.30× segment estimate. The 60 ms floor + 3-poll rule stay in ALL modes. The active mode,
room SNR, and configured `postRollMs` are appended to the `Recording timing` info log
(`postRollMode=`, `roomSNR=`) together with `PostRoll SNR-aware start/done` lines;
kill-switch OFF sets `postRollMode=fixed` + `roomSNR=0.0`. Per-key retune via
`internal.latency.snrTrustDb` / `snrAbsoluteCapMs` / `snrQuietToStopMs` / `snrRelativeCap` /
`snrFloorMarginDb` (restart required).

**Route-conditional paste settle.** Only the `.frontmost` CGEvent route pays the settle wait
(50/80 ms defaults, `internal.latency.pasteDelayShortMs`/`LongMs`); captured-element routes
paste focus-independently via AX set-value and captured-app does its own activate+settle
poll, so their wait is skipped. Consequence of deciding the route pre-wait (~50-80 ms
earlier): a user switching apps during the former wait now resolves like any other
post-transcription switch. A PID-posted Cmd+V experiment ships dark behind
`internal.latency.pidPasteEnabled` (default OFF) with automatic fallback to the global
Cmd+V post on refusal or nil PID.

**Tier-1 insertion hardening (K-56).** `PasteService` Tier-1 verified AX (`kAXSelectedTextAttribute` SET
+ 3×40 ms read-back via `kAXValueAttribute`; unchanged → fall through to Cmd+V, never double-post;
Electron lie-success killed). Before any pasteboard exposure: `AXSecureTextField` role or
`IsSecureEventInputEnabled()` / `IORegistry IOConsoleUsers` secure-input probe → hold; `AXUIElementGetPid`
mismatch vs `dictationTargetPID` → hold (`.focusElsewhere` chip, K-23); `AppQuirks.forcePaste` bundle-ID
table (empty, governance) skips Tier-1; `AccessibilityWaker.wakeIfNeeded` prefetches AX while user
still speaking (`KalamApp.startRecording`); after ~350 ms AX window, frontmost re-check before
global `postUnicodeText`/`postCmdV` legs (mismatch → hold). Optional per-reference timeout override
`internal.paste.setVerifyTimeoutOverrideMs` (0 unset, default OFF) raises only the SET+verify element
toward 1.2–1.5 s (global stays 0.75 s; legal per `AXUIElement.h:387–397`).

**Crash recovery (K-57) — REMOVED 2026-10-02 (owner: no audio persistence, even
across crashes).** Audio lives in memory only: capture buffers are `secureZero()`'d
after use and nothing is ever written to disk. The former opt-in retention stack
(`Support/FileLayout`, `Support/CAFStreamWriter`, `Support/RetentionPolicy`,
`Services/RecoveryScanner`, `AudioRecorder` begin/endRetention,
`AudioCaptureExchange` retention sink, `Settings` toggle, `RetentionTests`) is
deleted; restore via git history if ever reconsidered. If a `recordings/`
directory predates the removal, it is orphaned data — safe to delete manually.

**Fn hotkey option + Fn-key advisor (K-58) — REMOVED 2026-10-02 (owner: Fn is an
unreliable trigger).** The `fn` preset is gone from `KeyCombination` and
`HotkeyPreset` (menu, capture already excluded keyCode 63, listener Fn paths
removed); stored Fn residue (preset raw value or legacy F12-no-mod alias)
migrates to the app default (⇧ + ⌘) at load. `Services/FnUsageAdvisor` +
tests + launch/active/Karabiner observers + `OverlayAction.openKeyboardSettings`
+ `SystemSettingsDestination.keyboard` removed with it (the advisor only
protected Fn users). Stale `fnAdvisor.*` defaults keys are inert. Restore via
git history if ever reconsidered.

**Fused trim stage.** `SilenceTrimmer.trimAndNormalize` performs endpointing + peak
normalization in one output pass via vDSP (`vDSP_maxmgv` peak scan, scale + clamp),
semantically identical to the legacy two-pass `normalizePeak(trim(...))` and parity-pinned.
`SpeechQualityGuard` runs on the normalized clip; its window-vs-percentile comparisons are
offset-invariant, so normalization cannot change its verdict.

## Dictionary Behavior

- **Storage**: `~/Library/Application Support/Kalam/user_dictionary.json`
- **Smart Match (Default)**: Automatically handles capitalization mimicry, plurals, and possessives.
- **Rules Pipeline**:
  - Phrase rules first (longest trigger first)
  - Word rules second (longest trigger first)
- **Features**:
  - **Live Examples**: Real-time "Covers:" preview showing full mappings (e.g. `apple → orange`).
  - **Intelligent Mimicry**: Distinguishes between generic Title Case (auto-lowercased when source is lowercase) and Mixed Case brands (e.g. `iPad`, `Main St`) which are always preserved.
  - **Literal Matching**: Optional mode for exact text and casing requirements.
  - **Enforced Defaults**: Whole Word and Suffix Matching are active by default for standard word rules.

## Text Cleanup Behavior

`TextCleanupEngine` runs deterministic, local-only text transforms with feature flags;
`ValidationGate` (K-55) validates raw-vs-cleaned divergence inside `KalamTextEngine` (length
0.18…1.65, containment ≥0.30, trigram ≥0.05; all 13 goldens accept). On `.reject` the
pipeline falls back to raw ASR text (skips ITN/dictionary), counts a trip in
`ValidationGateTripStore` (rolling 24 h window, ≥3 trips → auto-degrades cleanup to
bypass until relaunch or `CleanupPane` Re-enable; `Notification.Name.validationGateAutoDegraded`;
success streak 5 resets). `TranscriptPostProcessor` exposes `gateVerdict`/`gateMetrics`/`gateRawFallback`
and logs `ValidationGate verdict=` with the transcription summary.

`TextCleanupEngine` flags:

- `removeFillers`
  - Removes common fillers and elongated variants (`ummm`, `uhhh`)
- `backtrack`
  - Removes prior clause when a correction cue appears (`scratch that`)
- `listFormatting`
  - Detects short spoken sequences with numeric markers and rewrites to numbered lines
- `punctuation`
  - Fixes spacing around punctuation and collapses repeated punctuation
- `grammarMode` / `grammarTimeoutMs`
  - Optional grammar pass using `NSSpellChecker`
  - `off`: deterministic-only path
  - `light`: low edit cap, spelling-focused
  - `full`: higher edit cap + sentence-start capitalization
  - Hard budget cap and skip for long transcripts (`>1200` chars)

### Cleanup examples

`removeFillers`

Input:

```text
um I think we should ship on friday you know
```

Output:

```text
I think we should ship on friday
```

`backtrack` (`scratch that`)

Input:

```text
send this now scratch that send it tomorrow
```

Output:

```text
send it tomorrow
```

`backtrack` (`no`)

Input:

```text
book me tomorrow no book me Friday
```

Output:

```text
book me Friday
```

`backtrack` (`actually`)

Input:

```text
I want to leave at five actually make it six
```

Output:

```text
make it six
```

`listFormatting`

Input:

```text
plan is one gather logs two isolate bug three ship fix
```

Output:

```text
plan is
1. gather logs
2. isolate bug
3. ship fix
```

`punctuation`

Input:

```text
hello ,world!!this is fine
```

Output:

```text
hello, world! this is fine
```

`grammarMode = light` (spelling-focused)

Input:

```text
teh release is tomorow
```

Output:

```text
the release is tomorrow
```

`grammarMode = full` (deeper pass + sentence starts)

Input:

```text
this is done. please send teh summary
```

Output:

```text
This is done. Please send the summary
```

`grammar protected terms`

Input:

```text
keep APIKey and GPT4o unchanged
```

Output:

```text
keep APIKey and GPT4o unchanged
```

`grammar skip for long transcripts` (`>1200` chars)

Behavior:

```text
Grammar stage is skipped; deterministic cleanup output is used directly.
```

## Configuration

UserDefaults keys include:

- `duckEnabled` (`Bool`, default `true`)
- `duckFactor` (`Float`, default `0.1`)
- `fadeMs` (`Int`, default `150`)
- `pttHotkey.activationMode`
- `pttHotkey.keyCombination`
- `pttHotkey.key`
- `pttHotkey.modifiers`
- `models.asrVersion`
- `models.modelLibraryBookmark` (security-scoped bookmark for local model library folder)
- `internal.latency.enableStageTiming` (`Bool`, default `true`)
- `internal.latency.startStageTiming` (`Bool`, default `true`)
- `internal.latency.postRollMinMs` (`Int`, default `100`)
- `internal.latency.postRollMaxMs` (`Int`, default `150`)
- `internal.latency.pasteDelayShortMs` (`Int`, default `50`)
- `internal.latency.pasteDelayLongMs` (`Int`, default `80`)
- `internal.latency.pasteFallbackTotalMs` (`Int`, default `120`)
- `internal.latency.snrAwareEnabled` (`Bool`, default `true`) — kill-switch for K-54
- `internal.latency.snrTrustDb` (`Float`, default `12`)
- `internal.latency.snrAbsoluteCapMs` (`Int`, default `1500`)
- `internal.latency.snrQuietToStopMs` (`Int`, default `250`)
- `internal.latency.snrRelativeCap` (`Float`, default `0.30`)
- `internal.latency.snrFloorMarginDb` (`Float`, default `3`)
- `internal.paste.setVerifyTimeoutOverrideMs` (`Int`, default `0` unset) — K-56 per-reference SET+verify override (1.2–1.5 s when set)
- `retention.enabled` — REMOVED with K-57 (2026-10-02); no writer remains, a stale key is inert
- `validationGate.isDegraded` / `validationGate.trips` / `validationGate.successStreak` — REMOVED with the K-55 auto-degrade cut (2026-10-02); the silent reject→raw fallback keeps no persisted state
- `textCleanup.enabled`
- `textCleanup.removeFillers`
- `textCleanup.backtrack`
- `textCleanup.listFormatting`
- `textCleanup.punctuation`
- `textCleanup.grammarMode`
- `textCleanup.grammarTimeoutMs`

## Model Setup

Kalam requires Parakeet TDT models for on-device transcription. Models are loaded from a local folder you choose.

### Quick Setup

1. **Open Onboarding or Settings**
   
   Launch the app (or select "Complete Setup" from the menu bar).
   The **guided onboarding** will walk you through folder selection and model downloading.

2. **Choose a model folder**

   Select or create a folder to store your models, e.g., `~/Models/FluidAudio`.
   This folder will store all your downloaded models.

3. **Download a model**
   
   Install the Hugging Face CLI (one-time):
   ```bash
   brew install hf
   ```
   
   Then download a model:
   ```bash
   # English-only (v2) - highest accuracy
   hf download FluidInference/parakeet-tdt-0.6b-v2-coreml \
     --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" \
     "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
     --local-dir ~/Models/FluidAudio/parakeet-tdt-0.6b-v2
   
   # Multilingual (v3) - 25 European languages
   hf download FluidInference/parakeet-tdt-0.6b-v3-coreml \
     --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" \
     "Decoder.mlmodelc/*" "JointDecisionv3.mlmodelc/*" "parakeet_vocab.json" \
     --local-dir ~/Models/FluidAudio/parakeet-tdt-0.6b-v3
   ```
   
   The `--local-dir` path must match your chosen folder from Step 1.

4. **Select the model** (Settings → Models → Step 3)

Onboarding copies the command for the user to run in Terminal; Kalam does not execute shell commands or download model files itself. The generated `--local-dir` destination is POSIX shell-quoted, so spaces, apostrophes, Unicode, and shell metacharacters in a selected folder remain data rather than command syntax.

Kalam itself has no outgoing-network entitlement and processes dictation locally. That does not make a user-run `hf` or Homebrew command offline: those commands may contact their external services.

### Required Files

Each model folder must contain:
- `Preprocessor.mlmodelc/`
- `Encoder.mlmodelc/`
- `Decoder.mlmodelc/`
- `JointDecision.mlmodelc/` for v2, or `JointDecisionv3.mlmodelc/` for v3
- `parakeet_vocab.json`

### Why Not the Full Repo?

The full Hugging Face repository is 2.6 GB, but Kalam only needs ~450 MB. The `--include` flag downloads only the required files, saving bandwidth and disk space.

## Dependencies

SwiftPM packages:

- `FluidAudio` (ASR integration), pinned to `0.15.5` in `Kalam.xcodeproj/project.pbxproj`
- `HotKey` (global hotkeys), pinned to `0.2.1` in `Kalam.xcodeproj/project.pbxproj`
- transitive packages pinned in `Kalam.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

Dependency updates should be deliberate: update the exact version in the Xcode project, resolve packages in Xcode, commit the regenerated `Package.resolved`, and require a full documented test pass before merging.

System frameworks:

- `SwiftUI`, `AppKit` (AppKit's `NSSpellChecker` powers the optional grammar pass)
- `AVFoundation`
- `ApplicationServices`
- `CoreAudio`, `AudioToolbox`
- `NaturalLanguage` (used for tokenization in cleanup)

## Optional: Enable ITN (`NemoTextProcessing.xcframework`)

ITN is wired into the app pipeline and enabled by default.
When the framework is linked, it adds spoken-form to written-form normalization:

- `two hundred` -> `200`
- `five dollars and fifty cents` -> `$5.50`
- `test at gmail dot com` -> `test@gmail.com`

In this app, ITN is called through the generated `NemoTextProcessing.swift` wrapper from `text-processing-rs`.
If unavailable, ITN is skipped and the app continues with cleanup + dictionary stages.

Setup:

1. Build `NemoTextProcessing.xcframework` using `text-processing-rs`.
2. Add `NemoTextProcessing.xcframework` and `NemoTextProcessing.swift` to the app target.
3. Build and run. ITN applies automatically when available.

Internal (non-UI) override keys:

- `internal.itn.enabled` (`Bool`, default `true`)
- `internal.itn.maxSpanTokens` (`Int`, clamped `4...64`, default `16`)

Example:

```bash
defaults write singhkays.Kalam internal.itn.enabled -bool false
defaults write singhkays.Kalam internal.itn.maxSpanTokens -int 20
```

When enabled, pipeline will be:

1. ASR
2. Deterministic cleanup (existing)
3. ITN (`NemoTextProcessing.normalizeSentence`)
4. Dictionary replacements
5. Paste

## Onboarding State And Reset

The onboarding deck is a presentation layer over `OnboardingFlowController`; it does not own a second workflow or persistence schema. The four live requirements are Microphone, Accessibility, Hotkey, and AI model. Informational and model-acquisition cards are skipped when the current snapshot is already ready, while repair mode opens at the first broken requirement.

`OnboardingStatusSnapshot.evaluate(...)` is the status seam. A card action never marks a requirement complete by itself; the controller invokes the real permission/configuration action and the app refreshes the snapshot through `refresh → prepareRuntimeIfPossible → refresh`. The final Start Dictating action remains disabled until all requirements and runtime preparation are ready.

The DEBUG Option/Alt reset clears only onboarding progress flags: `hasCompletedRequiredSetup`, `hasAttemptedAccessibilitySetup`, `hasPickedHotkey`, and `hasConfirmedHFCLIInstall`. It never clears the selected microphone, hotkey chord, model version, or security-scoped model-library bookmark.

## Sandbox, Network, And Permissions

The app target is sandboxed. It has audio-input and accessibility entitlements and no outgoing-network entitlement, so models must be acquired outside the app and selected from local disk. Paste, AX, and manual CoreAudio ducking are still runtime-verified because target applications, permissions, and output devices differ.

Required:

1. Microphone (audio capture)
2. Accessibility (caret positioning and synthesized paste events)

## Headless testing (no Xcode)

Deterministic cleanup and dictionary logic is extracted into a local SwiftPM package at `Packages/KalamTextEngine/`. These tests use **Swift Testing** (`@Test` / `#expect`) and can run on a VM without Xcode.

### Prerequisites

```bash
brew install swift
```

Use the brew Swift toolchain (`/opt/homebrew/opt/swift/bin/swift`), not Apple CLT (`/usr/bin/swift`) which lacks XCTest.

### Run

```bash
./scripts/test-engine.sh
```

Override the toolchain:

```bash
SWIFT_TOOLCHAIN=/path/to/swift ./scripts/test-engine.sh
```

### What runs locally vs Xcode-only

| Scope | Runner | Location |
|---|---|---|
| Filler removal, backtrack, lists, punctuation | `./scripts/test-engine.sh` | `Packages/KalamTextEngine/Tests/` |
| Dictionary compilation and case mimicry | `./scripts/test-engine.sh` | `Packages/KalamTextEngine/Tests/` |
| Grammar pass (`NSSpellChecker`) | `./scripts/test-engine.sh` | `Packages/KalamTextEngine/Tests/TextCleanupGrammarTests.swift` |
| ITN, ASR, onboarding, full integration | `xcodebuild test` (Xcode only) | `KalamTests/` |

## Build / Run (Xcode)

Requirements (project settings):

- macOS deployment target: `14.6`
- Swift language version: `6.0`
- Xcode 16.0 or newer (CI runs Xcode 26.6)

Swift 6 concurrency posture: ASR mutable state is actor-isolated in `Kalam/Services/ASRService.swift`, paste execution is main-actor isolated in `Kalam/Services/PasteService.swift`, and the dictation flow no longer uses `Task.detached` to capture app/runtime objects. New background work should either live behind an actor boundary or capture only immutable `Sendable` values.

Open `Kalam.xcodeproj`, run the `Kalam` target.

Local CI/test command (does not require a personal signing identity):

```bash
xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

On a signed developer machine, repeat without `CODE_SIGNING_ALLOWED=NO` before release signing.

## Real-model ASR smoke tests

`RealModelSmokeTests` loads the actual Parakeet CoreML model folders and transcribes a fixed TTS-generated fixture through the same `AsrModels`/`AsrManager` path `ASRService` uses — verifying the FluidAudio load path, transcription output, and the `ModelHub.offlineMode` invariant (no network entitlement) end-to-end.

Requirements:

- Model folders in `<repo>/Models/` (`parakeet-tdt-0.6b-v2`, `parakeet-tdt-0.6b-v3`, `parakeet-tdt-ctc-110m`), or any directory via the `KALAM_MODEL_LIBRARY` env var. Only the versions present are tested; missing versions are skipped, never failed.
- `fixtures/dictation_fixture.wav` (committed; regenerate with `say -v Albert "…" && afconvert … -f WAVE -d LEI16@16000 -c 1`).
- A Mac capable of running CoreML (load times vary; VMs run on CPU).

Run:

```bash
./scripts/parakeet-smoke.sh
```

Exit codes: `0` = all present models transcribed correctly, `1` = failure, `2` = nothing ran (models/fixture missing). Transcripts and load/transcribe timings print to the log for inspection.

## Current Notes

- App currently relies on CGEvent unicode, then Cmd+V paste, then Accessibility insertion, so target-app behavior can vary.
- Clipboard restore is guarded by pasteboard text and change count so user or target-app clipboard changes are left untouched.
- Audio ducking requires output devices with settable scalar volume and is runtime-verified under sandbox.
- Grammar/cleanup unit tests run headlessly via `./scripts/test-engine.sh` (`Packages/KalamTextEngine/Tests/`); the remaining app integration tests run via the `KalamTests` target.
- Startup logs print ITN status/version and a smoke normalization example.
