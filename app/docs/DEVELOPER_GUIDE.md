# Kalam

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
  - App entry point and `AppDelegate` (pure orchestration since K-03)
  - Hotkey event handling/state machine (delegates to `Services/HotkeyListener.swift`)
  - Recording orchestration (delegates to `Services/AudioRecorder.swift` + `Services/SilenceTrimmer.swift`)
  - ASR service integration
  - Paste service
  - System audio ducking (delegates to `Services/SystemAudioDucker.swift`)
  - Dictionary engine/persistence
- `DictationOverlayController.swift`
  - Overlay capsule UI (`OverlayCapsuleView`/`WaveformView`), placement, waveform/timer updates
- `Services/AudioRecorder.swift`
  - AVAudioEngine capture, 16 kHz mono resample, secureZero'd audio buffers, `AudioRecorderError`
- `Services/SilenceTrimmer.swift`
  - Energy-based endpointer (hysteresis, hangover, duration-aware fallback) + `normalizePeak`
- `Services/SystemAudioDucker.swift`
  - CoreAudio virtual-main-volume ducking while recording
- `Services/HotkeyListener.swift`
  - Global hotkey registration (HotKey package + modifier-only side-key monitoring), PTT callbacks
- `OnboardingFlow.swift` / `OnboardingActionStyles.swift`
  - 4-step guided setup implementation
  - Permission handling (Microphone, Accessibility)
  - Model download and selection logic
- `PTTHotkeyConfiguration.swift`
  - Activation mode and key-combination modeling
  - UserDefaults load/save and normalization
- `SettingsUI.swift`
  - Settings window shell (`SettingsView`): tab state, sidebar, config load/save orchestration
- `Kalam/Settings/`
  - Per-tab views: `GeneralSettingsTab` / `ShortcutSettingsTab` (hotkey + recorder sheet) / `CleanupSettingsTab` (refine + grammar) / `ModelsSettingsTab` / `UpdatesSettingsTab` / `WordReplacementView` (+ `EditableRow`); shared `SettingsSharedComponents.swift` (card surface, settings notification)
- `Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` / `TextCleanupConfiguration.swift`
  - Deterministic low-latency transcript cleanup pipeline
  - Optional grammar pass (`off` / `light` / `full`) with timeout budget (AppKit-gated)
- `app/Kalam/MicrophonePriorityConfiguration.swift` / `app/Kalam/MicrophoneDeviceService.swift`
  - Microphone selection and priority ordering

## Runtime Flow

1. User activates hotkey.
2. App resolves mode behavior (hold/toggle/double-tap/auto).
3. Recording starts:
   - Optional beep
   - Optional system ducking
   - Audio engine capture + conversion to 16 kHz mono Float32
4. Recording stops:
   - Adaptive post-roll
   - Silence trimming + peak normalization
   - ASR transcription
   - Text cleanup
   - Dictionary replacements
   - Paste to frontmost app
   - Clipboard restore (if unchanged externally)

Current ordering in code:

1. `ASR -> String`
2. `TextCleanupEngine.clean(...)`
3. `NemoTextProcessing.normalizeSentence(...)` (if ITN enabled + available), wrapped by `ITNSpanProtector` so ranges ("two to three"), idioms ("one of us"), and digit-by-digit sequences survive normalization (K-28)
4. `CustomDictionaryManager.apply(...)`
5. paste

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

`TextCleanupEngine` runs deterministic, local-only text transforms with feature flags:

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
- `internal.latency.postRollMinMs` (`Int`, default `100`)
- `internal.latency.postRollMaxMs` (`Int`, default `150`)
- `internal.latency.pasteDelayShortMs` (`Int`, default `50`)
- `internal.latency.pasteDelayLongMs` (`Int`, default `80`)
- `internal.latency.pasteFallbackTotalMs` (`Int`, default `120`)
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
