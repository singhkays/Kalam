# Kalam — Domain Glossary (CONTEXT)

Shared vocabulary for agents working on Kalam. Use these terms exactly in code, docs, and discussion so that modules, seams, and design decisions have stable names. See `AGENTS.md` for repo layout and `app/docs/DEVELOPER_GUIDE.md` for the full runtime flow.

## The dictation pipeline

- **PTT (push-to-talk)** — the global hotkey that starts/stops recording.
- **Activation modes** — `hold`, `toggle`, `doubleTap`, `holdOrToggle` (`PTTHotkeyConfiguration`).
- **Post-roll** — extra capture time (~100–150 ms) after key-up that preserves trailing phonemes (`KalamApp.swift`).
- **ASR** — on-device speech recognition via FluidAudio + Parakeet TDT CoreML models (v2 / v3 / 110m).
- **Cleanup** — deterministic transcript transforms: filler removal, backtrack cues, numbered-list formatting, punctuation normalization (`KalamTextEngine.TextCleanupEngine`).
- **Grammar pass** — optional `NSSpellChecker`-based spelling/uppercase pass (`off`/`light`/`full`), timeout-bounded, skipped for transcripts >1200 chars (`TextCleanupService`, app-side).
- **ITN** — inverse text normalization ("two hundred" → 200, spoken emails/dates → written form) via `NemoTextProcessing` xcframework (optional, runtime-detected).
- **Dictionary** — user phrase/word replacement rules with case mimicry and morphological suffixes (`KalamTextEngine.ReplacementCompiler`).
- **Paste** — insertion into the frontmost app: CGEvent unicode → Cmd+V (clipboard) → AX attribute set. Clipboard snapshot/restore guards the user's clipboard (`Services/PasteService.swift`).
- **Ducking** — temporary system output-volume reduction while recording (`SystemAudioDucker`).

## Models & setup

- **Model library folder** — the user-chosen folder that contains model directories; accessed through a security-scoped bookmark stored at UserDefaults key `models.modelLibraryBookmark`.
- **Model folder** — e.g. `parakeet-tdt-0.6b-v2/`, containing `.mlmodelc` directories plus `*vocab.json`.
- **Onboarding** — the 4-step setup flow: Microphone, Accessibility, Hotkey, Model (`OnboardingFlow.swift`).
- **hf download** — the HuggingFace CLI command the UI *displays* (copy-paste only) for fetching models; the app never executes shell commands.

## Runtime terms

- **Overlay** — the translucent capsule UI (waveform, elapsed timer, status message) shown while recording/transcribing.
- **Stage timing** — internal latency instrumentation behind `internal.latency.*` UserDefaults keys.
- **Secure zeroing** — wiping owned audio buffers (`Array.secureZero()`) after transcription so audio does not linger in app memory.
- **Indicator placement** — the overlay's screen position preset (`topCenter` / `bottomCenter`).
