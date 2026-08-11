# FluidAudio 0.14.5 → 0.15.5 Adoption Research & Plan

**Date:** 2026-08-11
**Status:** Executed 2026-08-11 (commits `a74b239`, `106c07d`, `2756226`) — Phases 0–3 code, tests, and docs done; build green, Xcode suite 62/62, engine 32/32. **Phase 1.6 smoke automated** via `RealModelSmokeTests` + `./scripts/parakeet-smoke.sh` (commit pending): v2 verified against the real model (transcript 18/19 words correct on the TTS fixture, offlineMode held); v3/110m auto-cover once their folders land in `<repo>/Models/`. **Remaining manual gate:** Phase 2.2 latency/WER measurement on real hardware (the `.cpuAndGPU` v3 path is enabled per upstream's +~8% RTFx / WER-neutral claim — revert by changing `ASRService.encoderComputeUnits(for:)` to return `nil`).
**Scope:** Evaluate upstream FluidAudio changes (v0.14.5 → v0.15.5) against Kalam's actual usage, recommend adopt/defer/skip, and plan the adoption work.
**Sources:** FluidAudio releases page (v0.15.0–v0.15.5), upstream source diffed at tags `v0.14.5` and `v0.15.5` (`AsrModels.swift`, `AsrManager.swift`, `AsrTypes.swift`, `DownloadUtils.swift`, `ModelHub.swift`, `ModelHubOfflineTests.swift`), Kalam `app/` source.

---

## 1. How Kalam uses FluidAudio today

Only **one subsystem**: Parakeet TDT **offline** ASR. Kalam pins FluidAudio `exactVersion 0.14.5` (`app/Kalam.xcodeproj/project.pbxproj:524-527`).

Public API surface Kalam touches (complete inventory):

| Kalam call site | FluidAudio API |
|---|---|
| `ASRService.swift:134` | `AsrModels.load(from:version:)` |
| `ModelsConfiguration.swift:210` | `AsrModels.modelsExist(at:version:)` |
| `ASRService.swift:137-145` | `ASRConfig(sampleRate:tdtConfig:encoderHiddenSize:parallelChunkConcurrency:streamingEnabled:streamingThreshold:)` |
| `ASRService.swift:147, 207-209, 230` | `AsrManager(config:models:)`, `decoderLayerCount`, `transcribe(_:decoderState:)` |
| `ASRService.swift:229` | `TdtDecoderState.make(decoderLayers:)` |

Kalam has **no in-app model download** — models are placed manually (browser + copied install command) into a user-selected folder, resolved via security-scoped bookmarks. Kalam has **no network entitlement** (hard convention, `IMPROVEMENT_PLAN.md` "What looks solid").

## 2. API compatibility audit (0.14.5 → 0.15.5)

Diffed upstream at both tags. **Kalam's entire surface is source-compatible** — the "breaking" `DownloadUtils → ModelHub` (#779) rename is internal:

| API | Compat? | Notes |
|---|---|---|
| `AsrModels.load(from:version:)` | ✅ | Gains trailing optional `encoderComputeUnits: MLComputeUnits? = nil` (v0.15.1 #659). Existing call unchanged. |
| `AsrModels.modelsExist(at:version:)` | ✅ | Identical (comment-only change). |
| `ASRConfig` memberwise init | ✅ | Gains `melChunkContext: Bool = true`, `dualDecodeArbitration: Bool = false` (both defaulted, appended). |
| `AsrManager(config:models:)`, `decoderLayerCount`, `transcribe` | ✅ | `transcribe` gains optional trailing `emitTokensAfterGlobalFrame` / `initialTimeIndexOverride`. |
| `TdtDecoderState`, `TdtConfig` | ✅ | Byte-identical. |
| `AsrModelVersion` cases `.v2/.v3/.tdtCtc110m` | ✅ | Only `.ctcZhCn` removed (Kalam doesn't use it). |
| `AsrModels.download` / vocab handling | ✅ | `parakeet_vocab.json` guarantee (#763) is download-path only; Kalam's offline `load()` requires vocab on disk — **unchanged behavior from 0.14.5** (both versions throw if missing). |

**Behavioral change on the load path (the important one):** `DownloadUtils.loadModels` → `ModelHub.loadModels` keeps the "delete cache and re-download" fallback on first-load failure — **but** adds `ModelHub.offlineMode` (from v0.15.0's `enforceOffline`, #632). With `offlineMode = true`:
- missing files throw a typed `DownloadError.modelMissing` instead of attempting a HuggingFace fetch;
- the destructive purge-and-redownload fallback is blocked (`ModelHubOfflineTests.swift:88-106`);
- cancelled first loads no longer wipe the cache (#749).

Without `offlineMode = true`, a load failure **deletes the user's model folder** and tries to re-download it over the network — which cannot work in Kalam's sandbox (no network entitlement) and would leave the user with a deleted model library. 0.14.5 already had the delete+redownload fallback (`DownloadUtils.swift:131`), so this risk exists today; 0.15.5 is the first version that lets Kalam *close* it.

## 3. Feature-by-feature assessment

### v0.15.5

| Upstream change | Verdict | Rationale |
|---|---|---|
| Download stack rebuilt → `ModelHub` (resumable, byte-level progress, validation, Retry-After policy) | **Adopt (as the upgrade)** | Internal infra. Source-compatible for Kalam. Brings `offlineMode` (must-adopt, see §4) and artifact validation (#741) with better failure locality. Resumable downloads/byte progress are irrelevant (Kalam doesn't download). |
| Parakeet unified ASR: native-Swift mel front-end, word timestamps, streaming tiers | Defer / Skip | New Unified manager family; Kalam uses sliding-window TDT. Mel front-end rewrite is internal and rides along free. Word-level timestamps only matter if a live-captioning feature is ever planned (open question Q2). |
| Custom vocabulary controls (per-term CTC thresholds, over-fire knobs, spotter-rescue opt-out) | Skip | Applies to the CTC/streaming + CustomVocabulary subsystem (BK-tree rescorer, CTC keyword spotter). Kalam's TDT path doesn't use it, and Kalam's **text-level** dictionary (KalamTextEngine) is the better fit for dictation: deterministic, user-editable, offline. Revisit only if WER on custom terms becomes a reported pain point. |
| Native-Swift mel front-end fix (iPadOS cold-start) | Ride-along | macOS app; the fix is internal and quality-neutral on Mac. |
| Nemotron tokenizer repair (#690) | N/A | Nemotron models only. |
| Seam-merge artifact fixes (#708) + 3 residual drop-path fixes (#759) | **Adopt (free)** | Directly improves long-utterance offline transcription (Kalam's chunked batch path) — dictation quality. Sits inside `AsrManager`/`ChunkProcessor`; comes with the upgrade. New upstream tests (`ChunkProcessorSeamResidualTests`) pin it. |
| `parakeet_vocab.json` fetch in `AsrModels.download` (#763) | N/A | Download path only; Kalam's offline `load()` already required vocab locally (unchanged). |
| Feature Provider classes (#713) | N/A | Unified ASR only. |

### v0.15.4 — KokoroAne TTS fixes, SenseVoice precision, streaming per-token timings
All TTS / other-backend. **N/A.**

### v0.15.3

| Change | Verdict | Rationale |
|---|---|---|
| SentencePiece word-boundary long-form chunk merges (#688) | **Adopt (free)** | Same family as #708/#759; part of the upgrade. |
| SlidingWindowAsrConfig 240k-input fix (#689) | N/A | Sliding-window streaming config; Kalam already hardcodes the 240k warmup shape for the TDT batch path. |
| EOU fused decoder (#680), Nemotron timings (#673) | N/A | Streaming/Nemotron paths. |
| Parakeet CTC zh-CN removal (#675), Magpie/Qwen3 removals (#674/#676), PocketTTS ANE (#679), Supertonic/M5/TTS items | N/A | Unused backends / TTS. |

### v0.15.2 — Supertonic3 quantized ANE, PocketTTS v2.1
TTS only. **N/A.**

### v0.15.1

| Change | Verdict | Rationale |
|---|---|---|
| Opt-in GPU encoder placement for Parakeet v3 (+~8% RTFx, WER-neutral) (#659) | **Adopt — Tier 2 (measured)** | Kalam loads the exact v3 model this targets. New `encoderComputeUnits: .cpuAndGPU` param on `AsrModels.load`. macOS dictation = throughput-oriented/plugged-in workload where the docstring's caveat doesn't apply; ANE stays default for iOS power. One-line change; gate on a before/after latency measurement (§6 Phase 2). |
| English Nemotron 2240ms tier + B1 fusion (#660) | N/A | Nemotron streaming. |

### v0.15.0

| Change | Verdict | Rationale |
|---|---|---|
| `DownloadUtils.enforceOffline` (→ `ModelHub.offlineMode`) (#632) | **Adopt — mandatory** | The single most valuable item for Kalam: turns the delete-cache-and-redownload footgun into typed errors that map to Kalam's existing `ASRError.invalidModelFiles` UX, and hardens the no-network-entitlement invariant. |
| SenseVoiceSmall / Paraformer-large zh / Nemotron 3.5 multilingual backends | Skip | New model families; Kalam's v3 already covers 25 languages. No user-visible gap. |
| Cohere root vocab fetch (#649/#650) | N/A | Cohere download fix. |

### Not in the release window but adjacent
- **VAD**: Silero CoreML v6.2.1 bump (#734) — Kalam uses its own energy-based `SilenceTrimmer`, not FluidAudio VAD. Out of scope; separate decision (open question Q4).
- **Diarization / TTS**: Kalam is single-speaker dictation input. N/A.

## 4. Recommendations

**Tier 1 — Upgrade 0.14.5 → 0.15.5 + `offlineMode` (do this):**
1. Bump the exact pin to `0.15.5`.
2. Set `ModelHub.offlineMode = true` once at startup, before any FluidAudio loader runs (see §6 Phase 1 for exact placement). This is **required**, not optional: without it, any load failure deletes the user's model folder and attempts a network re-download that cannot succeed in Kalam's sandbox.
3. Ride-along fixes free with the upgrade: seam-merge artifacts (#708/#759/#688), cancelled-load cache preservation (#749), artifact validation (#741).

**Tier 2 — GPU encoder placement, measured (small, after upgrade):**
4. `AsrModels.load(..., encoderComputeUnits: .cpuAndGPU)` for the v3 model on Apple Silicon; measure latency/WER before committing. Fall back to ANE default on any regression.

**Tier 3 — Defer, documented:**
5. `melChunkContext` / `dualDecodeArbitration` knobs — defaults are safe (`true`/`false` preserve today's behavior). Only revisit if v3 multilingual long-form dictation shows boundary artifacts.
6. Word-level timestamps / streaming tiers — architecture change; only when/if live captioning is on the roadmap.
7. Acoustic custom vocabulary — text-level dictionary is the better fit.

**Skip:** TTS (all), diarization, other ASR backends (SenseVoice/Paraformer/Nemotron/Cohere), iOS storage fixes, CLI surface, VAD swap.

## 5. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Stricter artifact validation (#741) rejects an existing model folder that loaded fine on 0.14.5 | Phase 1 smoke test loads **all three** model versions (v2/v3/110m) from real folders before declaring success. Models are standard HF `.mlmodelc` bundles; expected low risk. |
| R2 | `ModelHub` renamed again in 0.16 (upstream header: "Replaces the pre-0.16 ModelHub class — see the 0.16.0 migration table") | Pin exact `0.15.5`. Defer 0.16 to a future maintenance window; Kalam's tiny API surface makes the next migration cheap. |
| R3 | `offlineMode` is a global static — must be set before **any** FluidAudio touch, including tests; forgetting it reintroduces the delete+redownload footgun | Set in two places (AppDelegate launch + top of `ASRService.initialize`); add a test asserting `ModelHub.offlineMode == true` after init. |
| R4 | Dirty repo with in-flight K-01/K-02 work; concurrent sessions commit to the same VirtIOFS checkout | Stage only intended hunks (`git add -p`); never `git add -A`; re-check `git status` before committing (per kalam-app-development skill). |
| R5 | ASR quality regression on the exact same models (no ASR golden tests exist in KalamTests) | Manual smoke: transcribe a fixed set of short + long utterances before/after, compare transcripts + timings. |

## 6. Implementation plan

> For the implementer: run everything from repo root `/Volumes/My Shared Files/GitHub/Kalam`.

### Phase 0 — Baseline (30 min)
- [ ] **0.1** Record current state: `git status --short`, current commit.
- [ ] **0.2** Green baseline: `./scripts/test-engine.sh` (expect 32/32) and `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] **0.3** Note the ASRService warmup timing from Console (`log stream --predicate 'category == "ASRService"'`) for a fixed test utterance — this is the Phase 2 comparison baseline.

### Phase 1 — Pin bump + offlineMode (core, 2-4 h)
- [ ] **1.1** Bump pin: `app/Kalam.xcodeproj/project.pbxproj:526` `version = 0.14.5` → `0.15.5`. Resolve packages (`xcodebuild -resolvePackageDependencies`); commit `Package.resolved` update.
- [ ] **1.2** Add offline enforcement — `app/Kalam/KalamApp.swift` `applicationDidFinishLaunching` (near line 145), before anything else:
  ```swift
  // No network entitlement is a hard convention; never let FluidAudio
  // attempt a HuggingFace fetch or its delete-cache-and-redownload
  // fallback. See app/docs/dev-design/2026-08-11-fluidaudio-0.15.x-adoption.md.
  ModelHub.offlineMode = true
  ```
  Plus a defensive duplicate at the top of `ASRService.initialize()` (idempotent, covers any future loader entry point).
- [ ] **1.3** Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. Expected: compiles with **zero source changes** (compat audit §2); if anything fails, fix per the audit table.
- [ ] **1.4** Tests: `./scripts/test-engine.sh` (32/32) + `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] **1.5** Add a regression test: `KalamTests/` — assert `ModelHub.offlineMode == true` after `ASRService` init, and that `ASRService` surfaces `invalidModelFiles` (not a network error) when a model folder is incomplete (create a temp library with one missing `.mlmodelc`; reuse the `ModelsConfiguration` security-scoped seams).
- [ ] **1.6** Smoke test (manual, needs real models): with a model library containing `parakeet-tdt-0.6b-v2`, `-v3`, `-ctc-110m` folders, switch models in Settings, record + dictate a short (<10 s) and a long (>60 s) utterance for each. Confirm: transcripts have no seam artifacts mid-utterance; Console shows no `networkDisabled`/`modelMissing`/`DownloadUtils` errors; model switching still works.
- [ ] **1.7** Commit (stage only intended hunks): `git add -p app/Kalam.xcodeproj/project.pbxproj app/Kalam.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved app/Kalam/KalamApp.swift app/Kalam/Services/ASRService.swift app/KalamTests/…` → `chore(deps): bump FluidAudio 0.14.5 → 0.15.5, enforce ModelHub offline mode`.

### Phase 2 — GPU encoder placement (opt-in, measured; 1-2 h)
- [ ] **2.1** In `ASRService.initialize` (line 134), pass `encoderComputeUnits: .cpuAndGPU` — behind a file-private constant (`private static let encoderComputeUnits: MLComputeUnits? = .cpuAndGPU`) so it's a one-line revert. Restrict to Apple Silicon (`#if arch(arm64)`); keep `nil` on Intel (no ANE/GPU benefit).
- [ ] **2.2** Measure: same fixed utterances as Phase 0.3, compare end-to-end transcription time (ASRService logs) and transcript equality. Accept if ≥5% faster and WER-neutral on the test set; otherwise revert to `nil`.
- [ ] **2.3** Commit: `perf(asr): opt-in GPU encoder placement for Parakeet (+~8% RTFx, WER-neutral)`.

### Phase 3 — Docs & backlog (30 min)
- [ ] **3.1** Update `app/docs/IMPROVEMENT_PLAN.md` line 68 dependency pin: `FluidAudio 0.14.5` → `0.15.5`; add the `ModelHub.offlineMode` invariant to "What looks solid".
- [ ] **3.2** Update `app/docs/DEVELOPER_GUIDE.md` if it references FluidAudio API names (re-verify — it may already be stale per K-17).
- [ ] **3.3** If Phase 2 is reverted or deferred, leave the `encoderComputeUnits` constant with a `// TODO(K-xx): measure before enabling` note instead of dead code; otherwise remove the constant comment.

## 7. Open questions

- **Q1 (blocks 2.2):** Should GPU placement apply to all three model versions or only v3? Upstream measured v3 only. Default: v3 only, then measure v2/110m opportunistically.
- **Q2:** Is live captioning / word-level timestamps on the product roadmap? Drives Tier 3 items (streaming tiers, `WordTiming`).
- **Q3:** Any current user complaints about mid-utterance duplicate/dropped words on long dictations? Validates whether #708/#759 is user-visible today (it lands regardless — only affects how loudly to announce it).
- **Q4:** Should Kalam eventually replace `SilenceTrimmer` with Silero VAD? Separate decision; explicitly out of scope here.
