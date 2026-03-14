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
- System audio ducking while recording (optional)
- CGEvent unicode paste with clipboard snapshot/restore and AX fallback
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
  - App entry point and `AppDelegate`
  - Hotkey event handling/state machine
  - Audio recording pipeline
  - ASR service integration
  - Paste service
  - System audio ducking
  - Dictionary engine/persistence
- `OnboardingFlow.swift` / `OnboardingActionStyles.swift`
  - 4-step guided setup implementation
  - Permission handling (Microphone, Accessibility)
  - Model download and selection logic
- `PTTHotkeyConfiguration.swift`
  - Activation mode and key-combination modeling
  - UserDefaults load/save and normalization
- `SettingsUI.swift`
  - Settings UI (Word Replacement + Keyboard Controls + Refine + Models)
- `TextCleanupConfiguration.swift`
  - Cleanup feature flags and persistence
  - Grammar mode and timeout budget persistence
- `TextCleanupService.swift`
  - Deterministic low-latency transcript cleanup pipeline
  - Optional grammar pass (`off` / `light` / `full`) with timeout budget
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
2. `TextCleanupService.clean(...)`
3. `NemoTextProcessing.normalizeSentence(...)` (if ITN enabled + available)
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

`TextCleanupService` runs deterministic, local-only text transforms with feature flags:

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
What's the challenge we are finding with this issue and then why are we not able to fix it? Let's take a problem and solve it.


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

2. **Step 1: Choose a model folder**
   
   Select or create a folder to store your models, e.g., `~/Models/FluidAudio`.
   This folder will store all your downloaded models.

2. **Download a model** (~600 MB)
   
   Install the Hugging Face CLI (one-time):
   ```bash
   curl -LsSf https://hf.co/cli/install.sh | bash
   ```
   
   Then download a model:
   ```bash
   # English-only (v2) - highest accuracy
   hf download FluidInference/parakeet-tdt-0.6b-v2-coreml \
     --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" \
     "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
     --local-dir ~/Models/FluidAudio/parakeet-tdt-0.6b-v2-coreml
   
   # Multilingual (v3) - 25 European languages
   hf download FluidInference/parakeet-tdt-0.6b-v3-coreml \
     --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" \
     "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
     --local-dir ~/Models/FluidAudio/parakeet-tdt-0.6b-v3-coreml
   ```
   
   The `--local-dir` path must match your chosen folder from Step 1.

3. **Select the model** (Settings → Models → Step 3)

### Required Files

Each model folder must contain:
- `Preprocessor.mlmodelc/`
- `Encoder.mlmodelc/`
- `Decoder.mlmodelc/`
- `JointDecision.mlmodelc/`
- `parakeet_vocab.json`

### Why Not the Full Repo?

The full Hugging Face repository is 2.6 GB, but Kalam only needs ~600 MB. The `--include` flag downloads only the required files, saving bandwidth and disk space.

## Dependencies

SwiftPM packages:

- `FluidAudio` (ASR integration)
- `HotKey` (global hotkeys)
- transitive packages pinned in `Package.resolved`

System frameworks:

- `SwiftUI`, `AppKit`
- `AVFoundation`
- `ApplicationServices`
- `CoreAudio`, `AudioToolbox`
- `NaturalLanguage` (used for tokenization in cleanup)
- `AppKit` (`NSSpellChecker` for optional grammar pass)

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

## Permissions

Required:

1. Microphone (audio capture)
2. Accessibility (caret positioning and synthesized paste events)

## Build / Run

Requirements (project settings):

- macOS deployment target: `14.6`
- Xcode 16.x recommended

Open `Kalam.xcodeproj`, run the `Kalam` target.

## Current Notes

- App currently relies on CGEvent unicode, then Cmd+V paste, then Accessibility insertion, so target-app behavior can vary.
- Audio ducking requires output devices with settable scalar volume.
- Unit tests are available in `app/KalamTests/TextCleanupServiceTests.swift` and run via the `KalamTests` target.
- Startup logs print ITN status/version and a smoke normalization example.
