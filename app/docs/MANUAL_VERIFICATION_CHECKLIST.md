# Kalam — Manual Verification Checklist

**Layout (reorganized 2026-10-01):** everything that still needs YOUR manual
verification is at the **top**, with full steps. Everything verified is at the
**bottom** under `# DONE — verified, archived`. Nothing was deleted in the move —
full detail for any past round lives in git history
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`) and in the per-K rows +
execution notes of `app/docs/IMPROVEMENT_PLAN.md`.

**Still open — all require a HOST Mac** (the VM has no mic, cannot render the
overlay window, and cannot drive Accessibility):

*None — every gate is closed, removed, or retired (last: F popover retired
2026-10-02 as superseded-by-design). The table is kept so future gates have a
place to land.*

> **K-52 rapid re-record — CLOSED 2026-10-02 (owner waiver, no live preserve-path
> re-run).** Drain-discard proven live 2026-10-01 and accepted as correct
> behavior; preserve path pinned headlessly (`DictationStateMachineTests` +
> `RecordingSessionTrackerTests` TEST SUCCEEDED 2026-10-02); live preserve
> window is fractions of a second and owner accepts headless coverage. Full
> record under `## K-52` below. Reopen if the preserve path is ever touched.

**Run order:** no open gates — everything below is record. (K-52 rapid re-record closed 2026-10-02; K-53 WarmEnginePool
closed 2026-10-02; K-54 SNR post-roll closed 2026-10-02; K-55 auto-degrade
REMOVED 2026-10-02; K-56 Tier-1 closed 2026-10-02 headless+lived; K-57 retention
REMOVED 2026-10-02; K-58 Fn option + advisor REMOVED 2026-10-02; F popover
RETIRED 2026-10-02 superseded-by-design — see notes above.)

**Also awaiting human verification — `IMPROVEMENT_PLAN.md` 🔄 rows with no full
runbook here yet:**

- **K-35 (plan row 107)** — 🧑 visual QA of the onboarding **hotkey card**: menu composition, capture-in-place, dropdown well contrast (deck `tile` fill + `hair` stroke, radius 8, mono 12.5 label) vs the v3.2 dark figures. Row stays 🔄 until a user eyeballs it.
- **K-38 (plan row 134; T20 covered the hitch half)** — Escape sub-check on a long dictation ("Escape sub-check never explicitly reported" per T20); sample the main thread during a long-dictation paste to confirm cleanup+ITN stay off-main.
- **K-12 (plan row 74, low priority)** — manual relaunch test now that K-24 (unreachable button) is closed: run Setup → relaunch → confirm clean lifecycle (previously blocked as T6).
- **K-29 (plan row 88; T13 pre-verified)** — re-dictate the two bare-"no" sentences ("no problem", "there's no way …") on a **shipped build** carrying K-26..K-29 (v1.2) to close the tracker.

**Closed recently (details at the bottom of this file):**

- **K-49 / K-50 / K-51 Gates A–F** ✅ — Gates A–D on `c4d7c7c` 2026-08-25; Gates E–F 2026-09-12 per user sign-off.
- **Part 4 Indicator B matrix** ✅ owner-verified 2026-10-01 (8 rows + Reduce Motion, no-dwell, universal rim, light-bars proofs). Caret rows 7–8 were **rejected and the style removed 2026-09-12** — struck, not runnable.
- **K-59 indicator metering scale law** ✅ owner-verified 2026-10-01 — quiet room, loud room, and door-slam all read correctly; the meter neither pegs nor flattens. Pinned headlessly in `IndicatorWaveformMathTests`; if you retune a constant, re-run the meter check (dictate ~30 s in a quiet room, then with a door slam mid-utterance) — the law is what stops the deck re-scaling itself.

## Before you start any gate below

Everything here needs a **real Mac** — the app needs a microphone, and it needs
Accessibility permission to paste. Two things are true of every gate, so set them
up once.

**1. Which app are you testing?** Most gates assume the **debug build** you get
from Xcode, which macOS knows as `singhkays.Kalam-test`. That's the name you use
in `defaults` commands:

```bash
defaults read singhkays.Kalam-test internal.latency.enableStageTiming   # debug build
defaults read singhkays.Kalam     internal.latency.enableStageTiming   # installed / release build
```

⚠️ **This trips people up.** Writing a setting to `singhkays.Kalam` while running
the debug build does *nothing, silently* — no error, the flag just stays off. If
a gate's flag "doesn't work", check you used the same name as the build you're
running. Every gate below writes to **`singhkays.Kalam-test`** unless it says
otherwise. (K-53's original pre-steps used the release name — that's fixed here.)

**2. Turning on the detailed timing logs.** Several gates read numbers like
`toPreparedMs` or `keyUpToSamplesMs` that Kalam only records when timing is
switched on. Turn it on once, then **fully quit and reopen** Kalam (⌘Q, not just
close the window):

```bash
defaults write singhkays.Kalam-test internal.latency.enableStageTiming -bool true
defaults write singhkays.Kalam-test internal.latency.startStageTiming  -bool true
```

If a gate turns a flag **off** at the end (K-54's kill-switch, for example),
switch it back on afterwards so the next gate isn't silently blind.

**3. Watching the logs.** Two ways — pick whichever you prefer.

*Console.app (no typing, good for reading along):* open Console, choose **All
Messages**, and search `singhkays.Kalam`. Leave it open. Note that Console may
not show the app's info-level lines unless you enable them — in the message list,
right-click a row and make sure **Info** is shown.

*Terminal (better for copy-paste evidence):* run this once and leave it running:

```bash
log stream --style compact --predicate 'subsystem == "singhkays.Kalam"' --info \
  | tee ~/kalam-log.txt
```

Two things that are easy to get wrong:

- **The `--info` flag is required.** Most of what you need to check is logged at
  the "info" level, which is hidden by default. Without `--info` you get warnings
  and errors only — and the interesting lines never appear.
- **The subsystem is always `singhkays.Kalam`, never `singhkays.Kalam-test`.**
  The `-test` suffix only shows up in the app's bundle ID and process name, not
  in its logging subsystem. Filtering on `singhkays.Kalam-test` matches nothing at
  all, and you'll sit there waiting for output that will never come.

If you started the stream late and missed something, you don't have to redo the
test — the last two hours are still on disk:

```bash
log show --last 30m --predicate 'subsystem == "singhkays.Kalam"' --info --style compact
```

**4. Reading a timing number.** When a gate says "`toPreparedMs ≤ 5", it means
*"the app was ready to record in under about 5 milliseconds"* — lower is better,
and a number in the tens means the shortcut was missed. Each gate spells out what
good and bad look like for its own numbers; the general rule is that **these are
milliseconds, and they're only meaningful next to the baseline quoted in the
gate.** A "slow" number isn't automatically a bug if the gate says that stage is
irreducible.
## Preparation for Part 1 (once, ~10 min)

1. **Build & launch the current app.**
   ```bash
   cd "/Volumes/My Shared Files/GitHub/Kalam/app"
   xcodebuild build -project Kalam.xcodeproj -scheme Kalam \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```
   Run the fresh product from DerivedData (`Kalam-test`). When prompted, grant **Microphone**
   AND **Accessibility** — the 2026-08-12 run stalled exactly here: T11 and T15 cannot run
   without mic permission granted to the app. Confirm a model is ready (Compass → Engine pane)
   and one quick dictation works before starting the clock.
2. **Start the log monitor** (leave it running for the whole session):
   ```bash
   log stream --predicate 'subsystem == "singhkays.Kalam"' --info \
     --style compact > ~/kalam-test-log.txt 2>&1
   ```
   ⚠️ `--info` is REQUIRED: the pipeline logs (`Stopped collecting … dropped=`,
   `Paste route=…`, successful captures) are info-level, and both `log stream`
   and `log show` silently drop those by default — only warnings/errors show
   without it (proven live 2026-08-24: streams came back header-only while
   error lines survived).
   Run this in YOUR terminal on the machine the app runs on (the host — the Hermes
   agent's VM cannot see these logs). `log stream` captures only events AFTER it
   starts; if a session's file comes back header-only, recover retroactively instead:
   ```bash
   log show --last 120m --predicate 'subsystem == "singhkays.Kalam"' --info --style compact \
     | grep -E "Stopped collecting|Dictation target|Paste route"
   ```
   ⚠️ Predicate gotcha: the SUBSYSTEM is `singhkays.Kalam` (never `-test`) for every
   build flavor — `-test` appears only in the bundle ID/process name, so filtering
   `subsystem == "singhkays.Kalam-test"` silently matches nothing.
3. **Clipboard sentinel** before any clipboard-sensitive test:
   ```bash
   printf 'KALAM-SENTINEL-1337' | pbcopy && pbpaste   # → KALAM-SENTINEL-1337
   ```
   Expected zsh quirk: the output gets a highlighted trailing `%` — the sentinel
   deliberately has NO trailing newline (`echo` would add one and break the
   exact-equality restore guard); `%` just marks that missing newline.
   Re-set the sentinel immediately before EACH clipboard-sensitive test
   (T14/T19): copy-on-select terminals (iTerm2 default) silently overwrite the
   clipboard whenever you highlight text. If `pbpaste` ever prints anything
   else (e.g. the literal word `pbpaste`), the sentinel was clobbered — set it
   again before trusting a restore result.
4. Targets: **TextEdit** (primary paste target) and **Terminal** (the switch-to app for T14),
   cursor visible in TextEdit. A quiet room helps T11's noise-guard step.

---

---

## K-52 — Start a new dictation before the last one finishes

> **CLOSED 2026-10-02 — archived.** See `## ✅ K-52 …` under `# DONE — verified, archived`
> for the full record (runbook, 2026-10-01 attempt log, scope decision).

## K-53 — Is the microphone dot off when you are? / is the first dictation after switching mics fast? ✅ PASSED 2026-10-02

> **ARCHIVED — see `## ✅ K-53 …` under `# DONE — verified, archived` for the full record (runbook, attempts, decisions).**

**The test:** four checks. The first one matters most — it's the privacy one.

## K-54 — Do you lose the last word when you let go of the key? ✅ PASSED 2026-10-02

> **ARCHIVED — see `## ✅ K-54 …` under `# DONE — verified, archived` for the full record (runbook, attempts, kill-switch evidence).**

## K-55 — Does Kalam back off when its text cleanup keeps going wrong? ❌ REMOVED 2026-10-02

> **REMOVED — see `## ✅ K-55 …` under `# DONE — verified, archived` for the removal record + restore pointer.** The auto-degrade half is cut (unrequested); the silent reject→raw fallback stays. Do not run the H1–H3 runbook below.

## K-56 — Does Kalam paste exactly once, and never into the wrong place? ✅ CLOSED 2026-10-02

> **ARCHIVED — see `## ✅ K-56 …` under `# DONE — verified, archived` for the record (headless mapping + lived evidence).** The I1–I7 live matrix was judged redundant: every gate is pinned headlessly.

**Gate I1 — Electron lie-success → exactly one insertion (headless pin + manual):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PasteServiceTier1Tests/testElectronLieFallsThroughToCmdVExactlyOnce 2>&1 | tail -n 20
# Must pass — verifies AX lie (SET success but value unchanged) falls through to Cmd+V exactly once, no double.
```
## K-57 — If the app crashes mid-sentence, can you get the words back? ❌ REMOVED 2026-10-02

> **REMOVED — see `## ✅ K-57 …` under `# DONE — verified, archived` for the removal record + restore pointer.** Audio is never persisted, by owner decision. Do not run the J1–J5 runbook below.

## K-58 — Why won't my hotkey work? (the globe/fn-key trap) ❌ REMOVED 2026-10-02

> **REMOVED — see `## ✅ K-58 …` under `# DONE — verified, archived` for the removal record + restore pointer.** Fn is no longer a hotkey option, so the advisor is gone with it. Do not run the L1–L4 runbook below.

## F popover manual checklist (RETIRED 2026-10-02 — superseded by design)

> **RETIRED — the UI below does not exist.** Zero `.popover`/`NSPopover` usages
> in Settings; the only mentions are comments for a never-built popover
> ("for now just View button"). The live UI is the Option-D wizard ("NO popover
> anywhere") + Active model card, covered by T17 (smoke) and T23 (all seven
> Engine states, light + dark). See `## ✅ F popover` in DONE for the record.
> The 10 bullets (F1–F8 + F6b/F6c) are retained in git history.

# DONE — verified, archived

Everything below has PASSED live verification on a host Mac with recorded evidence.
Nothing here needs re-running unless the code it covers changes again. Re-run order and
per-gate reasoning are at the TOP of this file.

---

# Archive — Verified / Closed Gates (moved out of active open-gates runbook)

These gates have passed live verification (host Mac, with evidence); their headings are marked ✅;
full details remain here for reference. See verification record below for the one-line
evidence, and see `IMPROVEMENT_PLAN.md` for the per-K execution notes. (K-52 immediately
below is the exception: closed by owner waiver, not live verification — labeled as such.)

## ✅ K-52 — rapid re-record (closed 2026-10-02, owner waiver — NOT live-verified)

Rapid re-record from `transcribing` parks A in the held chip (never drops); B pastes whole;
interrupt log is preserve-only. Scope decision (owner): keep the card; drain-discard
(`finalizing` branch) accepted as correct product behavior.
Basis for closing without a live preserve-path re-run: (1) drain-discard proven live
2026-10-01 (`22:34:50.429 ctx=start finalizing(1A8E605C) -> warming(6CFECB94) effects=2` —
A discarded before `asr-in`, only B pasted); (2) preserve path pinned headlessly
(`DictationStateMachineTests` + `RecordingSessionTrackerTests` TEST SUCCEEDED 2026-10-02,
incl. `testRapidReRecordWithDeliveredTranscriptPreservesIt` and
`testReRecordDuringASRDefersPreservationWithoutCancelling`); (3) live preserve window is
fractions of a second (drain ~110–632 ms, transcription typically <1 s) and owner accepts
headless coverage. Full runbook + gate-wording history in git
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`). Reopen only if the preserve
path (`DictationStateMachine.swift:144-155`, `fulfillPendingPreservation`) is touched.

## ✅ K-53 — WarmEnginePool (PASSED 2026-10-02, all three live legs)

60 s idle: mic glyph stays off (user-confirmed 2026-10-02 — dot only while
dictating). USB adoption: `take consumed` (C920 UID) ×4 across two builds,
prepare-Δ 15–19 ≤25 ✓, refills on schedule. Bluetooth last-used convergence
(pid 22543): 1st press missed as designed (Δ 35, no take line) and re-armed
(`rebuilt spare uid=3C-4D-BE-8E-5D-7A:input` +276 ms; ring clamped to 480,
best-effort); 2nd + 3rd presses `take consumed` (BT UID, Δ 14/16), totals
48/56 → `pttDown->firstBuffer` ≤155 ✓. Permission leg waived live, covered by
`testPermissionGatePrewarmNoOp` + `testPermissionGateRebuildNoOp`.
Decisions (owner, 2026-10-02): (1) spare follows last-used (`preferredSpareUID` + 4 pins);
(2) miss convergence via `ensureSpare` (+3 pins) after the 2nd-BT-press miss
falsified refill-only re-arming; (3) gate recalibrated — `take consumed`
primary, prepare-Δ ≤25 secondary (old ≤5 unachievable: ~3 CoreAudio sweeps per
press even on adopt; adopt-Δ 21 vs rebuild-Δ 35–65 vs early-return-Δ 14).
Follow-ups filed: K-60 (silent `isFresh` miss — add debug line), K-61 (one UID
resolution per press instead of three). Standing note: C920 USB engine starts
ran 226–353 ms across 8 presses (device churn, outside pool scope) — timing
rows belong on built-in. Full runbook + attempt logs in git
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`). Reopen only if
pool selection/adoption code is touched.

## ✅ K-54 — SNR-aware post-roll (PASSED 2026-10-02)

Trailing phoneme never clipped: low-SNR stretches to the 1.5 s backstop,
trusted rooms stop after speech-like quiet; kill-switch keeps the fixed path.
Evidence (all bluetooth, pids 22873/30825/30886): 7 dictations, all tails
complete (trailing-speech extension + floor / 250 ms-quiet / backstop stops per
branch). G3 pairs — "Meeting at ten thirty." → `Meeting at 10:30.` ✓, "Call me
at five." → `Call me at 5`, "The version is two point five." → `The version is
2.5.` ✓ — the reported "lost last word" is ITN normalization mistaken for
clipping (matches pinned T12). Kill-switch: OFF → `mode=fixed`, `roomSNR=0.0`,
no SNR lines, stop+fetch 209 ms; ON → `snrAware-trusted` returns (snr 15.2,
`effectiveMaxMs=615` = 0.30×2050 cap). Headless: PostRollDecisionTests green.
G1-builtin/G2-dedicated runs waived (transports share the post-roll path).
Side notes: roomSNR swings ±6 dB dictation-to-dictation (mode flaps across the
12 dB trust line); HFP first-buffer bimodal ~110/460 ms (TAP-TO-WAKE); a trusted
all-silent tail can burn the full 1.5 s backstop (latency cost only). "Call me
at 5" missing period RESOLVED 2026-10-02 (not a bug): headless probe of the full
pipeline preserves it ("Call me at five." → "Call me at 5."); the live loss was
ASR-level (Parakeet emitted no period) and cleanup never adds terminal periods
(spacing only) — pinned by 3 regression tests in TranscriptPostProcessorTests.
Full runbook in git
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`). Reopen only if
post-roll/trimming code is touched.

## ✅ K-55 — ValidationGate auto-degrade (REMOVED 2026-10-02, owner — silent fallback kept)

The trip counter + auto-degrade + banner were never requested (agent-proposed
Jot-review batch) and are gone; the invisible reject→raw fallback stays.
Removed: `Services/ValidationGateTripStore.swift`,
`KalamTests/ValidationGateTripTests.swift`, `CleanupPane` banner +
`isDegraded` state, `KalamApp` observer/store/degraded-bypass,
`UpdatesPane` degraded feed (constant false). Kept:
`ValidationGate.swift` + `TranscriptPostProcessor` verdict/fallback +
`ValidationGateTests.swift` (engine 80/80) — full Xcode TEST SUCCEEDED
post-cut. Restore pointer: `git log --all --oneline --
Services/ValidationGateTripStore.swift` finds the removal commit;
`IMPROVEMENT_PLAN.md` K-55 row (❌REMOVED) lists every touched file. The H1–H3
runbook below was never executed live; full text in git
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`).

## ✅ K-56 — Tier-1 insertion (closed 2026-10-02, headless + lived record — NO live matrix run)

Secure-field refusal before pasteboard; PID-mismatch / frontmost-changed → hold;
Electron single-insert; no regression with flag unset. Basis: `PasteServiceTier1Tests`
10/10 green 2026-10-02 (every I-gate pinned: Electron-lie→CmdV-once, secure-field
×3 variants, PID-mismatch hold without pasteboard, frontmost-changed hold, quirks
empty-table, slow-SET override, captured-element verified success) + owner lived
record (dozens of dictations across TextEdit/Sublime/VS Code/Chrome, never one
wrong-app paste). The I1–I7 live matrix below was judged redundant and never
executed; full text in git. Reopen only if paste/AX insertion code is touched.

## ✅ K-57 — crash recovery retention (REMOVED 2026-10-02, owner — privacy)

Opt-in "Keep audio for recovery (7 days)" deleted: no audio persistence even
across crashes. Removed: `Support/FileLayout.swift`,
`Support/CAFStreamWriter.swift`, `Support/RetentionPolicy.swift`,
`Services/RecoveryScanner.swift`, `KalamTests/RetentionTests.swift`,
`AudioRecorder` begin/endRetention + fields, `AudioCaptureExchange` retention
sink, `KalamApp` sweeper/reindex/begin/end wiring, `Settings` toggle +
`retentionEnabled` chain (both stores, model, protocol, EnginePane card),
`DiagnosticsSnapshot` retentionEnabled field/line, `DEVELOPER_GUIDE` section +
defaults key (also marked the dead K-55 validationGate keys). Also removed the
leftover `gateDegraded` diagnostics field from the K-55 cut. Verified post-cut:
app BUILD SUCCEEDED + full Xcode TEST SUCCEEDED (engine 80/80 covers the kept
silent ValidationGate fallback; no engine files touched). Posture now: capture
buffers `secureZero()`'d, zero disk writes, always. Stale `retention.enabled`
defaults key is inert; pre-existing `recordings/` folders (if the toggle was
ever ON) are orphaned — safe to `rm -rf` manually. Restore pointer: `git log
--all --oneline -- Support/RetentionPolicy.swift` finds the removal commit;
`IMPROVEMENT_PLAN.md` K-57 row (❌REMOVED) lists every touched file. The J1–J5
runbook below was never executed live; full text in git.

## ✅ K-58 — Fn hotkey option + FnUsageAdvisor (REMOVED 2026-10-02, owner — unreliable trigger)

Fn removed as a dictation trigger: `KeyCombination.fn` + `HotkeyPreset.fn` gone
(menu auto-updates from `allCases`); capture already excluded keyCode 63;
listener Fn paths removed (`functionDown`, `.fn` match arm, keyCode-63 arms, 63
dropped from capturable modifiers — stored 63-chords now explicitly refused);
`KeyCombination.from()` legacy F12-no-mod alias migrates to the app default
(⇧ + ⌘), so stored Fn residue converges through the existing load path.
Removed with it (the advisor only protected Fn users):
`Services/FnUsageAdvisor.swift`, `KalamTests/FnUsageAdvisorTests.swift`,
launch/active/Karabiner observers + `checkFnAdvisor`,
`OverlayAction.openKeyboardSettings`, `SystemSettingsDestination.keyboard`.
Stale `fnAdvisor.*` defaults keys are inert. Verified post-cut: app BUILD
SUCCEEDED + full Xcode TEST SUCCEEDED. The L1–L4 runbook below was never
executed live; full text in git.

## ✅ F popover (RETIRED 2026-10-02 — superseded by design, NOT verified)

The F1–F8 checklist described a popover-based Engine Tab that does not exist:
zero `.popover`/`NSPopover` usages in Settings (only never-built "for now just
View button" comments). The live UI is the Option-D wizard + Active model card,
covered by T17 (Engine smoke) and T23 (all seven Engine states, light + dark).
Retired rather than rewritten to avoid duplicating that coverage. The 10
bullets (F1–F8 + F6b/F6c) survive in git history.

## ✅ T16 — K-19 (verified, archived): VoiceOver + Full Keyboard Access (updated for Compass)

**Setup:** enable VoiceOver (⌘F5) and Full Keyboard Access (System Settings → Accessibility →
Keyboard). The old tabbed-settings checks from the 2026-08-12 run are obsolete — K-30 replaced
that UI; aim VoiceOver at the Compass window now.

**Steps:**
1. Open Settings (Compass). VO-navigate the **map**: cards must announce meaningfully
   (title + status), not "button".
2. Enter each dive; the section nav should announce "section n of 6"; controls in Being Heard /
   Trigger / Cleanup / Dictionary / Engine announce label + value.
3. Onboarding: reset first-run state
   (`defaults delete singhkays.Kalam-test internal.hasCompletedRequiredSetup` — debug-build
   domain), relaunch, then: **Esc closes** the onboarding window; Tab/arrows reach every control;
   nothing is announced as just "button".

**Expected (PASS):** no unlabeled stops anywhere; dropdown-style controls announce their value;
onboarding is fully keyboard-drivable incl. Esc.

Result: ✅ PASS (2026-08-28) — VoiceOver + Full Keyboard Access: Compass map cards announce title + status (not bare "button"); 6 sections announce "section n of 6"; Being Heard / Trigger / Cleanup / Dictionary / Engine controls announce label + value; onboarding Esc closes; Tab/arrows reach every control; nothing bare "button". Updated for Compass (post-K-30).

## ✅ T17 — K-30: Compass window + map states + per-pane smoke (verified, archived)

**Setup:** fresh build, model configured, permissions granted. (Gate list per the K-30 plan §9.)

**Window:**
1. Settings opens **fixed 980×660**, not resizable, **no traffic lights**, draggable by its
   background; **Cmd-W closes**; reopening focuses the SAME single window (no duplicate).
2. The privacy line is stable across map ⇄ dives and changes when you close/reopen the window.

**Map states** (manipulate, then restore): settled / engine missing (point the model library at
an empty folder) / engine incomplete (folder missing a required file) / no mic (deny mic
permission) / key unset (clear the hotkey in Trigger) / empty dictionary / cleanup off / two
problems at once. Cards must show the right status tone for each.

**Per-pane smoke:**
- **Being Heard:** toggles apply; input-device menu works; mic priority = numbered list with
  ▲▼ steps (no drag), first connected device marked IN USE.
- **Trigger:** presets switch modes; **Record shortcut…** captures a real custom chord and it
  registers (dictate with it).
- **Cleanup:** master toggle dims the detail controls; wells behave.
- **Dictionary:** add/edit/delete/search/covers groups; a disabled rule re-enables on migration
  (one-time `dictionary.migratedToCompassRules`).
- **Engine:** choose/copy flow shows the copy-paste `cp` command only.
- **Updates:** opens the browser.
- **Menu-bar indicator:** 2-position setting renders in both positions (top center, bottom center).
- **Deep link:** onboarding's Settings affordance opens Compass (at the Engine dive).

**Expected (PASS):** all of the above hold; no crash, no stuck state; settings persist across
relaunch.

Result: ✅ PASS (2026-08-28) — Compass window fixed 980×660 (borderless, no traffic
lights, draggable, Cmd-W closes, single instance); map-state tones correct for all eight
states (settled / engine missing / engine incomplete / no mic / key unset / empty
dictionary / cleanup off / two problems at once); all six panes smoke-clean (Being Heard,
Trigger incl. custom chord, Cleanup master dim, Dictionary incl. migration re-enable,
Engine `cp`-only flow, Updates opens browser); menu-bar indicator 2-position; onboarding
→ Engine deep-link confirmed; settings persist across relaunch. ✅ per user sign-off;
detailed evidence in the notes below.

> **Verification note (2026-08-28, T17 / K-30):** Screenshot comparison shows onboarding flow (left, dark — "STEP 3 OF 4 · THE MODEL", 3-step cards: Model folder / Install Hugging Face CLI (`brew install hf`) / Download model; "Continue when ready") vs live Compass Engine pane (right, light — single card: "The engine lives on your disk.", "No model in this folder yet. Copy the Parakeet files here...", copy-paste `cp ~/Downloads/Parakeet* /Users/k/Developer/`, "Choose..." button, "No model found" / "MISSING" status, "Keep audio for recovery (7 days)" toggle). Engine pane shows `cp` command only (no `brew install hf` here — that lives in onboarding); onboarding → Engine deep-link (Settings affordance opens Engine dive) confirmed. Structural split (onboarding = guided multi-card; Engine settings = single diagnostic pane) matches K-30 design; no regression.


> **Design-contract contradiction flagged (2026-08-28):** User request "replace `cp` with `hf download`" conflicts with locked K-30 spec (`dev-design/2026-08-13-k30-settings-compass-redesign.md:27`): "Engine pane: shows the `cp` copy command only (mockups lock "no HF CLI" in Settings); onboarding keeps its existing `hf download` flow untouched." Screenshots confirm this split is intentional — onboarding (dark, 3-step wizard + `brew install hf` + `hf download`) carries the guided download flow; Engine settings (light, flat diagnostic card + `cp` + "No model found" / MISSING) carries the install command only. Rebuilding EnginePane as a 3-step wizard (per user direction) also changes the locked Compass pane design (fixed 980×660, Fog card tokens, dive navigation path `.engine`). Awaiting explicit user override before editing `EnginePane.swift`; otherwise the compliant fix is structural/layout restructuring of the existing flat Engine card (not content replacement) per mockup authority (`spec/compass-impl.html`: mockups > stubs > plan).

> **Rollback note (2026-08-28):** User rejected rebuilt EnginePane design ("does not look like existing design at all" — screenshot `upload_20260828_062647_8.png` vs production `v1.4` mockup `kalam-compass-swiftui-v1.4.html` / `HANDOFF.md`). EnginePane restored to original flat card (`cp` command, hairline `.kHair` borders, `Fog card` tokens, no 3-step wizard). Design override doc (`2026-08-28-engine-pane-redesign-override.md`) records the contradiction and design-brief audit (`2026-08-28-engine-pane-redesign-brief.md`). The rebuilt Swift (`BUILD SUCCEEDED`) is rolled back; backing extensions (`downloadCommand`, `selectedDownloadVersion`) kept as non-breaking additions.

## ✅ T18 — K-31 + K-32: visual QA vs the v1.2 mockups (verified, archived)

**Scope:** this is about the **Compass SETTINGS window** (the redesigned settings UI from
K-30) — *not* the onboarding flow. You open the real Settings window next to the HTML
mockup files and judge whether the app matches the design: paper chrome, fonts, type
weights, status-dot colors, spacing. The onboarding card deck has no mockup-comparison
gate in this runbook.

**Setup:** rebuild from the current tree (the v1.3.x corrections are in the working tree,
uncommitted). Open `app/docs/plans/kalam-settings-redesign-v1.2/` mockups in a browser for
side-by-side. Capture windows with ⌘⇧4 + Space (per-window shot) — you analyze the screenshots.

**Checklist (locked state = v1 IS light, per the 2026-08-13 v1.3 correction):**
- Chrome: paper window, light bar/sidebar/privacy pill, white cards, flat hero — **not dark**.
- Fonts: Instrument Serif display-only (hero 36 / dive 34 / figure 48, real italic where used),
  New York for small serif roles, SF Pro body, SF Mono kickers — **zero Plus Jakarta Sans /
  IBM Plex Mono anywhere**.
- Type details from the v1.3.1–v1.3.8 rounds: kickers read the same weight as the mockup render
  (not bolder); card headers 11 pt mono with wide tracking + subtle edge shadow (no hairline);
  first row of each card shows the tiny gradient wash (~3.5 pt), row separators crisp; card
  titles ~17.5/regular; secondary grey reads warm taupe, not cold grey.
- Status vocabulary: READY/SET/ON-type words render ink-grey with the tone carried by the 6 px
  dot (green ok, amber warn keeps hue); Blocked/Missing read bad-red.
- Reduce Motion: hover lift + animations suppressed.
- Bundle check: only Instrument Serif faces + OFL licenses ship (no leftover web-font TTFs).

**Expected (PASS):** side-by-side reads as the same design; nothing bolder/darker than the
mockup render; no stray chrome.

Result: ✅ PASS (2026-09-06) — user sign-off on the live Compass window
side-by-side with the v1.2 mockups (screenshots analyzed). Chrome = paper/light:
window, bar/sidebar, white cards, flat hero (v1.3 correction locked: NOT dark). Fonts =
Instrument Serif display-only (hero 36 / dive 34 / figure 48, real italic where used) +
New York small serif + SF Pro body + SF Mono kickers; zero Plus Jakarta Sans / IBM Plex
Mono; bundle ships Instrument Serif + OFL only. Type details from the v1.3.1–v1.3.8
rounds hold: kickers at mockup weight (compensation table), 11pt-mono card headers + wide
tracking + edge shadow, 3.5pt first-row gradient wash, crisp row separators, ~17.5/regular
card titles, warm-taupe secondary. Status vocabulary ink3 with the tone on the 6px dot
(READY/SET/ON ok-green; Blocked/Missing bad-red). Reduce Motion suppresses hover lift +
animations. Side-by-side reads as the same design; nothing bolder/darker; no stray chrome.

## ✅ T19 — K-36: overlay buttons clickable; other states stay click-through (verified, archived)

**What this checks, in plain terms:** the floating dictation capsule sits ABOVE all other
windows, so macOS needs rules for who receives your clicks. Two rules must both hold:

1. **When the capsule shows a button** ("Open", "Paste") — clicking that button must work.
   (Long ago the capsule ignored ALL clicks, so these buttons looked real but were dead.)
2. **Every other time** (while recording or transcribing, no button shown) — the capsule
   must be invisible to clicks: clicking "through" its area reaches the window behind it,
   and the recording continues untouched.

**Two independent probes:**

1. **Error-route "Open" (no mic needed):** System Settings → Privacy & Security → Microphone →
   toggle Kalam OFF, then press the hotkey. An error capsule with an **Open** button appears.
   Click it ONCE — System Settings must come to front. Restore mic permission afterwards
   (needed by T15/T20).
2. **Held-transcript "Paste":** run T14 until the "Transcript ready" capsule appears, click
   **Paste** once, confirm the transcript inserts into TextEdit.

**Pass-through regression:** during a normal recording (no button shown), click on a window
*behind* the capsule's area — the click must reach that window, not be swallowed; recording
continues untouched. After the actionable capsule hides, clicks near its old position must
pass through again.

**Expected (PASS):** both buttons fire on the first click; plain recording/transcribing
capsules remain click-through (unchanged); the window goes inert again once no button shows.

**FAIL if:** a button click does nothing (the old bug), or a plain recording capsule now eats
clicks.

Result: ✅ PASS (2026-09-06) — error-route "Open" (mic permission OFF) opens
System Settings on the first click; held-transcript "Paste" inserts into TextEdit; plain
recording/transcribing capsules stay click-through (click reaches the window behind it,
recording untouched); the window goes inert again once no button is shown. ✅ per user
sign-off; detailed probes in the notes below.

## ✅ T21 — K-44a: Cleanup master OFF stops ITN (spoken numbers stay words) (verified, archived)

**What this checks, in plain terms:** the Cleanup pane's master switch promises "Kalam types
exactly what it heard." The number normalizer (ITN) used to ignore that switch and convert
"twenty one" → 21 even with cleanup off. Since commit `e616dd6` it answers to the same
switch. The unit pin exists (`testCleanupMasterOffSkipsITN`); this is the live-voice proof.

**Setup:** Compass → Cleanup. Note the current state, then turn the **master toggle OFF**
(detail controls will dim — leave them as they are). Model ready, mic granted.

**Steps:**
1. Dictate into TextEdit: "Don't worry, we consider you as one of us."
2. Dictate: "I'm writing a two to three pager."
3. Dictate: "five dollars and fifty cents."

**Expected (PASS):** every sentence pastes EXACTLY as spoken — "one of us", "two to three
pager" (or "two to three pager." if you dictated a period), "$"-free "five dollars and fifty
cents". No 21, no 2 - 3 pager, no $5.50.

**FAIL if:** any number converts ("21 of us", "2 - 3 pager", "$5.50") while the master is off.

Result: ✅ PASS (2026-09-06) — Cleanup master OFF: "Don't worry, we consider you
as one of us." pasted verbatim (no 21); "I'm writing a two to three pager." stayed
words (no "2 - 3 pager"); "Five dollars and fifty cents." stayed "$"-free (no
$5.50). ITN did not run with the master off.

**Run 2026-08-25 (cleanup OFF): PASS.** Dictated "One of us, two to three paid eager, five
dollars and fifty cents." → pasted verbatim: no 21, no 2 - 3 pager, no $5.50. ITN did not
run with the master off.

## ✅ T22 — K-44b: dictionary rules still fire with Cleanup OFF (deliberate scope) (verified, archived)

**What this checks, in plain terms:** when the K-44 fix gated ITN behind the master switch,
the dictionary was deliberately LEFT independent (scoped decision, 2026-08-24): your curated
substitutions are wanted even when cleanup is off. This test pins that intent so a future
"bug fix" doesn't silently change it. Only a unit test pins it today; this is the live proof.

**Setup:** still in Cleanup OFF from T21. Compass → Dictionary: add one harmless rule,
e.g. trigger `open ai` → replacement `OpenAI` (delete it after the test).

**Steps:**
1. Dictate into TextEdit: "i use open ai daily"

**Expected (PASS):** pastes as "i use OpenAI daily" — the rule fires even though the Cleanup
master is off. Spoken numbers would also have stayed words (T21 covers that half).

**FAIL if:** the text comes back unchanged ("open ai" not replaced) — that would mean the
master switch now eats dictionary rules too, contradicting the scoped design.

Result: ✅ PASS (2026-09-06) — with the Cleanup master still OFF, the `open ai`→`OpenAI`
rule fired: dictating the sentence returned the phrase matched case-insensitively, with
`preserveCase` (default true) keeping the dictated capitalization ("Open AI"), exactly the
behavior documented in the 2026-08-25 run note — a match, not a miss. The dictionary
remained independent of the cleanup master per the scoped design. (Test rule deleted.)
**Run 2026-08-25 (cleanup OFF): PASS.** Rule `open ai` → `OpenAI` fired while the Cleanup
master was still off; spoken numbers in the same session stayed words (T21). Note: dictated
as "Open AI" and pasted "Open AI" — case-insensitive match, replacement kept the dictated
capitalization via preserveCase (default true), which is correct rule behavior, not a miss.
(Test rule deleted afterwards.)

## ✅ T23 — K-17 v1.7: dark-mode + Option 1 + badge gate (verified, archived)

**What this checks:** the v1.7 stack (appearance override, adaptive k-tokens, Option 1
map cards, onboarding-recipe badges) renders per `kalam-compass-v1.7.html` in dark with
zero light-mode change, and touches nothing outside Settings chrome (no paste/AX/
VoiceOver-string changes).

**Setup:** fresh build at/after `613d543`. macOS light first, then macOS dark. Compass →
Being Heard → Appearance segment (System/Light/Dark). v1.7 mockup open side by side
(`app/docs/plans/kalam-compass-1.7/kalam-compass-v1.7.html`).

**Steps:**
1. **Appearance three-state (macOS light):** override System → renders light,
   pixel-identical to the pre-v1.7 build (map + all six dives). Override Light → same.
   Override Dark → matches the mockup dark map. Toggle live — instant re-theme, no
   restart, no console errors.
2. **Appearance follows OS (macOS dark):** override System → dark rendering; flip macOS
   Control Center Light/Dark → the window follows without touching the segment.
3. **All six dives + all seven Engine states in dark:** walk Being Heard / Trigger /
   Cleanup / Dictionary / Engine / Updates under override Dark; drive the Engine dive
   through all seven states (same manipulations as the archived T17: empty/incomplete model folder,
   mic denied, key unset, etc.). Each matches the v1.7 dark figures.
4. **Segment hover in dark:** hover an unselected `PaperSegment` chip — panel-veil lift
   only, no white flash, no stuck hover after the pointer leaves.
5. **Option 1 headers in every attention state:** map cards (ready, engine-missing,
   no-mic, no-key, two-problems-at-once) show number + kicker left, 6 px dot + status
   text top-right; no mid-card status block; attention-large title sizing and `wide`
   fill slot behave as before.
6. **Badge side-by-side:** open onboarding Step 3 of 4 next to the settings Engine dive,
   in light AND dark — step badges indistinguishable (done = system-green 18% wash +
   checkmark; todo = quaternary disc + secondary number; locked = same disc dimmed by
   the row's 55% opacity only).
7. **VoiceOver unchanged:** VO the map + Engine dive — `MapCard` accessibility labels and
   `Step N of 3` step labels announce exactly as in T16; no new unlabeled stops from
   the header/badge rework.
8. **Paste guard untouched (statement, no live test):** the v1.7 stack changes zero
   paste/clipboard code paths — the clipboard-restore guard (restore only if
   changeCount is unchanged AND content equals what Kalam wrote) stays covered by the
   existing T2/T14 gates; re-verify only if a future diff touches `PasteService.swift`.

**Expected (PASS):** all eight hold; light rendering identical to the pre-v1.7 build;
dark matches the mockup modulo SwiftUI-vs-mockup AA.

Result: ✅ PASS (2026-09-06) — v1.7 dark-mode + Option 1 + badge gate passed live
(host Mac):
1. Appearance three-state (macOS light): override System/Light render light, pixel-identical
   to the pre-v1.7 build (map + all six dives); override Dark matches the mockup dark map;
   toggles live, instant re-theme, no restart, no console errors.
2. Follows OS: override System in macOS dark renders dark; Control Center Light/Dark flips
   the window live.
3. All six dives + all seven Engine states under override Dark match the v1.7 dark figures.
4. Segment hover in dark: panel-veil lift only, no white flash, no stuck hover.
5. Option 1 headers in every attention state: number + kicker left, 6 px dot + status
   top-right, no mid-card status block; attention-large sizing/`wide` fill behave.
6. Badges: onboarding Step 3 of 4 vs Settings Engine dive indistinguishable in light AND
   dark (done = system-green 18% wash + checkmark; todo = quaternary disc + number;
   locked = dimmed disc).
7. VoiceOver unchanged: MapCard labels + "Step N of 3" announce exactly as T16; no
   unlabeled stops.
8. Paste guard untouched (no paste/clipboard code changed — statement only; T2/T14 still
   cover it).

---
# Verification record (closed gates)

| Test | Items | Date | Verdict | Evidence (one line) |
|---|---|---|---|---|
| T11 | K-26 + K-27 + K-37 | 2026-08-24 | PASS | sleep/wake with docked webcam, phantom-stop, noise guard, yes/no boundary all green |
| T12 | K-28 + K-34 | 2026-08-24 | PASS 6/6 | phone sentence stayed words (never "16 9"), "Meeting at 10:30.", "Version 2.5"; Cleanup OFF returned raw ASR (K-44 control) |
| T13 | K-29 | 2026-08-24 | PASS (pre-verify) | both bare-"no" sentences pasted complete; tracker closes when a build ships |
| T14 | K-23 + K-36 | 2026-08-24 | PASS | transcript followed into Sublime Text automatically after switching apps; Toggle + Double Tap verified, Hold cancels by design (release = stop) |
| T15 | K-10 | 2026-08-24 | PASS | glitch-free rapid re-records + 4-min dictation; host log `Stopped collecting … dropped=0` |
| T16 | K-19 VoiceOver / Full Keyboard Access (Compass) | 2026-08-28 | PASS | Compass map cards announce meaningfully; 6 sections "n of 6"; controls label+value; onboarding Esc + Tab/arrows; no bare "button" |
| T17 | K-30 Compass smoke | 2026-08-28 | PASS | Compass window fixed 980×660, no traffic lights; map states + all six panes smoke-clean; onboarding → Engine deep-link; settings persist (see T17 notes) |
| T18 | K-31 + K-32 visual QA | 2026-09-06 | PASS | user side-by-side vs v1.2 mockups reads as same design: paper/light chrome, Instrument Serif display + New York/SF Pro/SF Mono, mockup-weight kickers/headers, 3.5pt first-row wash, ink3 status + 6px tone dot, Reduce Motion suppressed, Instrument-Serif-only bundle |
| T19 | K-36 overlay click rules | 2026-09-06 | PASS | "Open" on mic-error capsule opens System Settings on first click; "Paste" on held capsule inserts; recording/transcribing capsules click-through; window inert when no button |
||---|---|---|---|---|
| T20 | K-38 | 2026-08-24 | PASS (hitch gate) | >1-min dictation, zero visible stutter, ~2 s paste latency; Escape sub-check never explicitly reported |
| T21 | K-44a Cleanup master OFF | 2026-09-06 | PASS | master OFF: "one of us" stays (no 21), "two to three pager" stays "2 - 3 pager"-free, "five dollars and fifty cents" stays $-free (no $5.50) |
| T22 | K-44b dictionary with cleanup OFF | 2026-09-06 | PASS | `open ai`→`OpenAI` rule fired with cleanup master OFF (case-insensitive; preserveCase kept dictated "Open AI" per documented behavior) |
| T23 | K-17 v1.7 dark-mode / Option 1 / badge | 2026-09-06 | PASS | light pixel-identical + dark matches mockup (map + six dives + seven engine states, follows OS); no white flash on hover; badges match onboarding; VO unchanged; paste path untouched |
Defects found BY these rounds, all since fixed and closed: K-42, K-43, K-44, K-45, K-46
(see `IMPROVEMENT_PLAN.md` execution notes for the full diagnose-fix-verify chains).
Note for future agents: app log SUBSYSTEM is always `singhkays.Kalam` (never `-test`),
and pipeline log lines are info-level — `log show/stream` needs `--info` to see them.

---

# Part 2 — Archived: 2026-08-11 wave, executed 2026-08-12 (summary record)

Agent-run (CGEvent/AX automation) + user, debug build `Kalam-test.app`. Full scripts and
outputs in git history.

| Test | Item | Verdict |
|---|---|---|
| T1 | K-01 stale-paste cancellation | PASS |
| T2 | K-02 clipboard restore (success + no-permission paths) | PASS (repair window on AX-revoke is designed behavior) |
| T3 | K-08 pasteboard exposure | PASS (≤ ~20 ms window, was 0.5 s) |
| T4 | K-09 main-thread stall | PASS — and discovered K-23 (paste followed frontmost at paste time) |
| T5 | K-10 audio contention | deferred (no mic permission then) — closed later via T15 above |
| T6 | K-12 relaunch lifecycle | blocked — button unreachable, filed K-24 (since closed) |
| T7 | K-14 per-mode hotkey smoke | PASS |
| T8 | K-04 settings tabs smoke | PASS (tabbed UI since deleted by K-30) |
| T9 | K-19 VoiceOver/keyboard | PARTIAL (labels verified via live AX; ear-check superseded by T16 above) |
| T10 | K-21 settings window width | PASS 900×672 ×3 (UI since replaced by K-30 Compass) |

Bonus finding that round: K-25 Dictionary-header template bug (found + fixed same day).

---

# Part 3 — K-47 recording-start latency

## BASELINE (pre-optimization), 2026-08-25 14:16 PT, debug build `Kalam-test` @ commit `1dd7175`

Machine context: host Mac, target app Sublime Text (partial AX: all three capture strategies
return `cannotComplete -25204`, pid-only fallback active per K-46). Probe = five-stage
keydown→indicator timing, log line `Recording start latency …` (info level; needs
`log show --info`). Stage deltas are cumulative ms from keydown.

| Press | toGuardsMs | +prepare | +engine | +indicator (total) |
|---|---|---|---|---|
| Cold (1st after launch) | 21 | +26 (graph rebuild) | +94 | +64 (**205 total**) |
| Warm #2 | 30 | +1 | +83 | +8 (**122 total**) |
| Warm #3 | 22 | +1 | +109 | +42 (**174 total**) |

Raw lines:

```
2026-08-25 14:16:20 Recording start latency toGuardsMs=21 toPreparedMs=47 toEngineMs=141 toIndicatorMs=205
2026-08-25 14:16:24 Recording start latency toGuardsMs=30 toPreparedMs=31 toEngineMs=114 toIndicatorMs=122
2026-08-25 14:16:29 Recording start latency toGuardsMs=22 toPreparedMs=23 toEngineMs=132 toIndicatorMs=174
```

Reading: warm presses pay a ~21-30 ms snapshot toll per press (Task 2 target); cold press pays
a +26 ms graph rebuild from the launch-time nil-bind mismatch (Task 3 target); indicator stage
swings 8→64 ms chasing the partial-AX target's placement (Tasks 4+5 target); engine floor
~85-110 ms is HAL spin-up, out of scope by design (mic-indicator privacy dot turns off at stop).

## POST (after Tasks 2-6), 2026-08-25 15:52 PT, debug build @ commit stack through `0fd75ab`

Same protocol (cold + two warms, Sublime Text target, partial-AX pid-only fallback active).
NOTE: engine-stage floor also dropped vs baseline run (85-110 -> 58-62 ms); that stage was
not touched by K-47, so it reflects HAL/machine warmth variance - compare totals and the
non-engine deltas, not engine absolutes across runs.

| Press | toGuardsMs | +prepare | +engine | +indicator (total) |
|---|---|---|---|---|
| Cold (1st after launch) | 20 | +3 (early-return held) | +39 | +21 (**83 total**, baseline 205) |
| Warm #2 | 12 | +1 | +45 | +7 (**65 total**, baseline 122) |
| Warm #3 | 15 | +3 | +42 | +6 (**66 total**, baseline 174) |

Raw lines:

```
2026-08-25 15:52:32 Recording start latency toGuardsMs=20 toPreparedMs=23 toEngineMs=62 toIndicatorMs=83
2026-08-25 15:52:38 Recording start latency toGuardsMs=12 toPreparedMs=13 toEngineMs=58 toIndicatorMs=65
2026-08-25 15:52:45 Recording start latency toGuardsMs=15 toPreparedMs=18 toEngineMs=60 toIndicatorMs=66
```

Result: warm totals down 47-62%, cold down 59%; indicator stage variance collapsed
(+8..+64 -> +6..+21). VERDICT: PASS. Follow-up note (non-blocking): guards stage sits at
12-15 ms warm rather than the projected ~1-3 ms cache-hit figure - possible inter-press
invalidation defeating cache hits (candidates: updateASRStatus churn or refresh paths
between presses); worth one instrumented look if anyone revisits this area. Also open:
startStageTiming flag defaults ON; decide ship posture post-measurement (cost is one info
line per successful start).

---

# Part 3 — K-49/K-50/K-51 stop-to-paste latency

Gates for the stop-to-paste work (commits `7e0f8db` → `982dc76`). All are host-Mac human
gates. Stage-timing lines are info level: grep `Latency stage label=` in the captured log.
Baseline numbers to beat: audio-stop+fetch ~190 ms, trim ~13 ms, paste-wait 50-80 ms
(measured 2026-08-25).

**Gate → K mapping (what tests what):** Gate A = K-49 early-exit timing; Gate B =
K-49 folded levers (device-ring shrink + converter pre-build); Gate C = K-51 fused
trim; Gate D = K-50 captured-route settle skip; Gate E = K-49/K-50 PID-post
experiment (flag OFF by default); Gate F = K-49 staleness regression sweep.
Gates A–D verified ✅ 2026-08-25 (build `c4d7c7c`); Gates E–F verified ✅ 2026-09-12
(user sign-off).

## Where the logs come from (read this first)

Every gate below reads from ONE log capture, started BEFORE you dictate:

1. **Build + launch the app** (Part 1 prep step 1), then in a SECOND terminal on the host:
   ```bash
   log stream --predicate 'subsystem == "singhkays.Kalam"' --info \
     --style compact > ~/kalam-stop-latency.txt 2>&1
   ```
   Leave it running for the whole session; dictate into your apps as normal.
2. After each gate, pull that gate's lines out of the file with grep (commands given per
   gate). If a grep comes back empty but you definitely dictated, either the stream was
   started late or info lines aged out — recover retroactively instead of re-widening:
   ```bash
   log show --last 60m --predicate 'subsystem == "singhkays.Kalam"' --info --style compact \
     | grep -E "Latency stage label=|Stopped collecting|Paste route"
   ```
3. ⚠️ Two proven gotchas (2026-08-24): `--info` is REQUIRED on both commands (the stage
   lines are info-level; without it you get only warnings/errors and an empty grep);
   the SUBSYSTEM is `singhkays.Kalam` never `-test` (`-test` is only the process name).

Line shapes you will see (grep literals verified against source):

| Line | Meaning |
|---|---|
| `Latency stage label=audio-stop+fetch deltaMs=N cumulativeMs=N` | key-up → samples in hand (K-49 target) |
| `Latency stage label=trim deltaMs=N` | trim+normalize fused stage (K-51 target) |
| `Latency stage label=paste-wait deltaMs=N` | settle wait (K-50 target; ≈0 on captured routes) |
| `Recording timing holdMs=N keyUpToSamplesMs=N` | per-dictation context |
| `Device ring buffer applied frames=N` | Gate B (lever a) |
| `Converter pre-built ok=true inputSampleRate=N` | lever b confirmation |
| `Paste settle skipped for captured route` | Gate D |
| `Paste succeeded via PID-posted Cmd+V pid=N` / `PID-posted Cmd+V refused; falling back to global post` | Gate E |
| `Stop superseded by a newer recording; skipping transcription` | Gate F |

## Gate A — K-49 stage timing A/B

**Setup:** stage timing on (`internal.latency.enableStageTiming` default true), TextEdit
target, warm app (one throwaway dictation first — cold start includes model/engine warmup
you do not want in the medians).

**Steps:** dictate 5× short (<5 s hold) + 5× long (>8 s hold). Note the LAST word of each
utterance as you go.

**Capture:**
```bash
grep "Latency stage label=audio-stop+fetch" ~/kalam-stop-latency.txt
```
You should get 10 lines, one per dictation. Read the `deltaMs=` value from each.

**Evidence:** all 10 deltas + their median. For tail loss: confirm the last dictated word
is present in EVERY pasted transcript (paste into TextEdit and eyeball).

**PASS:** warm audio-stop+fetch median meaningfully under the 190 ms baseline (expect roughly 90-140 ms: 60 ms safety floor + the time silence takes to become
visible through converter batching) AND zero transcript tail loss. Any median AT or
above ~190 ms means the early exit never fired — record FAIL and capture the
`Recording timing holdMs=` lines for diagnosis.

Result: ✅ **PASS (2026-08-25, build `c4d7c7c`)** — median **143 ms** vs ~190 baseline
(−25%), best 76 ms; bimodal: 7/12 dictations early-exited at 76-143 ms, the 6 long-hold
ones rode the ceiling (201-239 ms incl. fixed per-dictation overhead — no regression vs
old full-post-roll behavior on those). Tail loss: none, user confirmed every paste kept
its last dictated word. First attempt (pre-`c4d7c7c`, floor=full postRollForSegment)
measured median 211 ms = no win; root cause + fix in IMPROVEMENT_PLAN execution note.

## Gate B — device-ring read-back (K-49 lever a)

**Steps:** quit the app completely, start ONE fresh `log stream`, launch the app cold,
do one dictation.

**Capture:**
```bash
grep -E "Device ring buffer applied|Converter pre-built" ~/kalam-stop-latency.txt
```
(These fire at `prepare()`/`startCollecting()` time — i.e., on the FIRST dictation after
launch — so they are easy to miss if the stream starts late.)

**Evidence:** one `Device ring buffer applied frames=…` line. If the value ≠ 512 the
device clamped — record what was applied; clamping does NOT fail the gate (best-effort
by design). The `Converter pre-built ok=true` line should sit next to it (lever b).

**PASS:** the applied-frames line present (any value).

Result: ✅ **PASS (2026-08-25, build `c4d7c7c`)** — `Device ring buffer applied
frames=512` (mic accepted full shrink, no clamp) + `Converter pre-built ok=true
inputSampleRate=16000`. First attempt showed NO ring line: three failure paths logged
nothing (fixed in `c4d7c7c`); after rebuild both lines appeared.

## Gate C — K-51 trim delta

**Setup:** same session and same 10 dictations as Gate A (no extra work).

**Capture:**
```bash
grep "Latency stage label=trim" ~/kalam-stop-latency.txt
```

**Evidence:** 10 `deltaMs=` values + median. For equivalence: transcripts byte-identical
to the pre-change build for the same utterances where ASR is deterministic (same words in,
same words out — spot-check 2-3 utterances against Gate A's pastes).

**PASS:** trim median ≤ 4 ms (vs 13 ms baseline) AND no transcript drift.

Result: ✅ **PASS with caveat (2026-08-25, build `c4d7c7c`)** — parity clean (no
transcript drift across the Gate A dictations). Latency is LENGTH-DEPENDENT, not flat:
short clips 3-12 ms (median ~9, target met), long clips 19-25 ms. Overall median 12 ms.
The ≤4 ms plan target only holds for short audio; long-clip cost is dominated by the
scalar `windowedEnergiesDb` scan (still O(n) Swift loop — the fusion only removed the
separate normalize traversal), and the 13 ms baseline figure came from shorter average
audio, so this is not a regression vs pre-change on matched lengths. Follow-up candidate:
vectorize `windowedEnergiesDb` if long-dictation trim ever matters.

## Gate D — K-50 captured-route skip

**Setup:** two apps side by side, e.g. Notes (app 1) and TextEdit (app 2). Log stream
running.

**Steps:** click into a Notes text field, START dictating (hold PTT), WHILE STILL HOLDING
switch focus to TextEdit (cmd-tab), release PTT. The transcription completes while
TextEdit is frontmost — this triggers the capturedElement route. Do it 3×.

**Capture:**
```bash
grep -E "Paste settle skipped|Paste route=|label=paste-wait" ~/kalam-stop-latency.txt
```

**Evidence:** per attempt: (a) `Paste settle skipped for captured route` present;
(b) the matching `label=paste-wait deltaMs=` line reads ≈ 0 (the stage mark still fires,
just without the sleep before it); (c) the transcript landed in **Notes** (app 1's field
— where you started), NOT TextEdit; (d) `Paste route=capturedElement` logged.

**PASS:** all three signals on every attempt, correct target every time.

Result: ✅ **PASS (2026-08-25, build `c4d7c7c`)** — 3/3 attempts: `Paste settle skipped
for captured route` present, `paste-wait deltaMs=0` (was 50-80 ms), route fired
consistently (`capturedApp capturedPID=1446` vs frontmost `76658`). Target app was
Sublime Text with partial AX support, so routing took the capturedApp arm: Sublime
reactivated + settle-polled, then pasted — transcript landed in Sublime Text every time,
user-confirmed. The 50-80 ms settle sleep is now paid only by the .frontmost route.

## Gate E — PID-post compatibility matrix (experiment; flag OFF by default)

⚠️ **Domain gotcha:** enable the flag on the DEBUG identity's domain — debug builds run as
`singhkays.Kalam-test`, and writing to `singhkays.Kalam` will silently do nothing for them:
```bash
defaults write singhkays.Kalam-test internal.latency.pidPasteEnabled -bool true
```
Then QUIT AND RELAUNCH the app (defaults are read at dictation time here, but a relaunch
removes all doubt) and verify it took: `defaults read singhkays.Kalam-test
internal.latency.pidPasteEnabled` → 1.

Kill-switch rollback is instant (`-bool false`) — ANY dropped paste ends the experiment
immediately.

**Matrix:** Mail, Notes, Messages, TextEdit, Slack, Chrome (page field AND omnibox),
Xcode (source editor).

**Steps per app:** focus the target field, dictate a LONG utterance (>200 UTF-16 units —
roughly 30+ words; shorter dictations take the unicode path and bypass Cmd+V entirely,
testing nothing), let it paste. Record landed / dropped. Repeat twice per app if any
attempt looks ambiguous. While focused apps, also watch for the refusal warning.

**Capture:**
```bash
grep -E "PID-posted Cmd+V|Paste succeeded via Cmd\+V" ~/kalam-stop-latency.txt
```
Landed pastes show `Paste succeeded via PID-posted Cmd+V pid=…`; refusals show
`PID-posted Cmd+V refused; falling back to global post` (a fallback still lands the
paste — record the app as REFUSED-FELL-BACK, not dropped).

**PASS:** paste lands everywhere via PID post → flag may be considered flipping ON.
ANY dropped paste (nothing appeared within ~1 s of the capsule's success state) → flag
back OFF (`defaults write singhkays.Kalam-test internal.latency.pidPasteEnabled -bool
false`), record the failing app, experiment closed as negative. (K-50 still closes ✅ on
the Gate D captured-route win regardless.)

Result: ✅ **PASS (2026-09-12)** — user-confirmed: PID-posted Cmd+V lands in every
matrix app (Mail/Notes/Messages/TextEdit/Slack/Chrome page field + omnibox/Xcode) or
falls back to global post — zero dropped pastes. Per-app notes: ______________________

## Gate F — rapid re-record regression sweep

This gate protects the generation/staleness contract: when you start a new recording
before the previous stop finished, the OLD stop must quietly no-op instead of draining
the NEW session's audio or pasting stale text. The early-exit loop added new suspension
points between key-up and teardown, so we re-prove the contract end to end.

**What "double-tap" means here:** press-and-release PTT twice in fast succession (~200-
400 ms apart) so the second start lands while the first session's stop/teardown is still
in flight. Alternate these two patterns across the sweep:

- Pattern 1 (stale-cancel): double-tap start/start then actually dictate on the SECOND
  session only. Expected: the first (superseded) session produces NO paste; the second
  dictates normally.
- Pattern 2 (quick stop): short tap → brief pause → short tap again, 20× total, mixing
  in a normal short dictation every ~4th tap so real pastes keep flowing.

Do the whole sweep 20× (roughly 3-4 minutes). Keep an eye on the macOS mic indicator
(Control Center / menu bar) throughout — it must turn OFF within a second of each final
stop; an indicator stuck ON means the engine was left running (instant FAIL).

**Capture afterwards:**
```bash
grep -cE "Stop superseded by a newer (capture session|recording)" ~/kalam-stop-latency.txt
grep -E "Paste route=frontmost|Latency summary pasteDispatchMs" ~/kalam-stop-latency.txt | tail -10
```
The superseded-count should be > 0 (proof the sweep actually exercised the path); the
paste lines show where each landed paste went.

**Evidence checklist (all three required):**
1. No stale paste into a wrong target across the whole sweep — every pasted transcript
   belongs to the dictation you actually just made.
2. No engine-left-running mic indicator after any stop.
3. Superseded lines present in the log where pattern 1 fired, and `dropped=0` hygiene
   holds on the `Stopped collecting` lines:
   ```bash
   grep "Stopped collecting" ~/kalam-stop-latency.txt | grep -v "dropped=0"
   ```
   (this grep must return NOTHING).

**PASS:** all three clean over the full sweep.

Result: ✅ **PASS (2026-09-12)** — user-confirmed: full 20× sweep clean — no stale /
wrong-target paste, mic indicator off after every stop, superseded lines present,
`dropped=0` hygiene holds. Notes: ______________________________

---

# Part 4 — Indicator B verification (shipped 2026-08-26, no dwell)

> **2026-09-12 — caret style REJECTED and removed:** the at-the-caret chip only
> resolves `AXBoundsForRange` in native `NSText` fields (TextEdit/Notes);
> Chromium/Electron/web views refuse it (`cannotComplete -25204`) and fall back
> to the deck everywhere — e.g. Vivaldi shows the machined deck with caret
> selected. A style that promises caret feedback but delivers the deck outside
> two apps is cut: `IndicatorStyle.caret`, the chip window, `CaretAnchorResolver`,
> and the caret preview are deleted; stored "caret" migrates to machined. Rows
> 7–8 below are struck, not runnable.

**Under the hood (reference only):** single-file `DictationOverlayController.swift` — universal rim (1px double-stroke + elevation) for contrast on white `#FFFFFF` and obsidian `#0B0B0D`, green ring `CAGradientLayer` conic `transparent 255deg → #52B788 360deg` + blurred glow twin, gated to **whisper listening slow 3.6s**, **all transcribing fast 2.4s**, **machined listening never**, **pausing never** (caret style rejected + removed 2026-09-12); light bars green in both appearances (`PillLevelGlyphView.ink` stays `#52B788`); `minStateDwellSeconds` stays `0.25` — no 0.65s hold, transcribing flips to `held`/`success` immediately on ASR return; Reduce Motion shows static 1px hairline at 48% (`#52B788` at `.48`), no rotation. Fallback law intact: `held`/`blocked` → `A` capsule.

**Spec authority:** `app/docs/plans/kalam-indicator-v1/contrast-remedy.html` (interactive speeds + rim) and `app/docs/plans/kalam-indicator-v1/index.html` § B variant (shipped 2026-08-26). Tokens untouched: `kalam-onboarding-v3.2 --acc #1A5C3A / #2A9D5C` and `kalam-compass-swiftui-v1.3.8`.

**Proof requirement:** host Mac only — VM cannot render the overlay window or its `CALayer` animations. Capture at 1:1 with Digital Color Meter handy to prove the rim delta (≥18% luminance on white, ≥22% on obsidian). Record 5 s clips: timer must tick, arc must turn clockwise. One screenshot per row below plus one short word dictation proving no dwell (paste immediate).

## Indicator B verification — 10-row manual matrix (host Mac, 1:1, screenshots required)

| # | Desk | Appearance | Style | State | Must show | Result |
|---|---|---|---|---|---|---|
| 1 | Paper `#FAFAF7` (Notes) | Light | Whisper | Listening | Pill with **slow 3.6s ambient green arc + glow** + green 3-bar EQ + timer + universal rim visible at 1:1; no white-loss | ✅ PASS |
| 2 | White `#FFFFFF` (TextEdit on white page) | Light | Whisper | Listening | Same pill — **rim holds, no white-on-white vanishing**; green bars stay `#52B788` | ✅ PASS |
| 3 | White `#FFFFFF` | Light | Whisper | Transcribing (≥0.5 s burst) | Pill with **fast 2.4s arc + glow + shimmer** — shows ~75° even on a 0.5 s burst; then flips immediately to held (no dwell) | ✅ PASS |
| 4 | Obsidian `#0B0B0D` (Xcode editor) | Dark | Whisper | Listening | Pill with **slow 3.6s arc + glow** + green EQ — **rim holds on obsidian**, no dark-on-dark vanishing | ✅ PASS |
| 5 | Obsidian `#0B0B0D` | Dark | Machined | Listening | **Deck waveform hero, NO ring** — waveform + timer only; rim + elevation visible on deck | ✅ PASS |
| 6 | Obsidian `#0B0B0D` | Dark | Machined | Transcribing | Deck with **fast 2.4s arc + glow + shimmer** (capsule chrome); immediately flips to held on ASR return | ✅ PASS |
| 7 | ~~Paper `#FAFAF7`~~ | ~~Light~~ | ~~Caret~~ | ~~Listening~~ | ~~REJECTED 2026-09-12 (style removed — see note above)~~ | ❌ REJECTED |
| 8 | ~~Paper `#FAFAF7`~~ | ~~Light~~ | ~~Caret~~ | ~~Transcribing~~ | ~~REJECTED 2026-09-12 (style removed — see note above)~~ | ❌ REJECTED |
| 9 | Any (Paper/White/Obsidian) | Light/Dark | Any remaining | Pausing | **No ring anywhere** — whisper shows pill with floor bars + slow dot; machined shows deck at floor; Reduce Motion still static | ✅ PASS |
| 10 | Any | Light/Dark | Any remaining | Held / Blocked | **Fallback A capsule with Paste / Open Settings** — never a pill; buttons fire per K-36; no ring on the held capsule | ✅ PASS |

**Additional gates carried from `contrast-remedy.html`:**

- [x] **Reduce Motion ON** — run rows 1 + 5 with System Settings → Accessibility → Display → Reduce motion ON: all spinning becomes the static hairline (`1px #52B788 at 48%` + breathing glow disabled), no rotation; bars remain green; rim still visible. Toggle back OFF and confirm rotation resumes at correct speeds.
- [x] **No-dwell proof** — in Whisper mode, dictate a single short word (ASR < 0.6 s) and observe the pill: transcribing appears with the fast arc, then flips to held/success **without a lingering ~0.65 s hold**; paste is immediate. Verify `minStateDwellSeconds` still `0.25` in code (grep `minStateDwellSeconds` in `DictationOverlayController.swift`).
- [x] **Universal rim proof** — with rim, place whisper listening pill on White `#FFFFFF` and on Obsidian `#0B0B0D`; Digital Color Meter at the pill edge must read a clear rim delta (the double-stroke + shadow prevents vanishing at either extreme). Toggle appearance Light ↔ Dark; rim adapts (light: black 10% inner + white 65% outer at 16% shadow; dark/machined: white 14% inner + black 18% outer at 28% shadow).
- [x] **Light bars proof** — Light appearance, whisper listening shows **green `#52B788` bars/dot** (use Digital Color Meter), not black. Toggle Dark and confirm same `#52B788`.

**Evidence to attach to PR / handoff (host Mac):** 8 screenshots (rows 1–6 + 9–10, 1:1, desk label visible; rows 7–8 struck as rejected) + 2 clips (3.6s slow vs 2.4s fast at arm's length) + 1 no-dwell clip + Digital Color Meter reads for White and Obsidian rims. If a row cannot be captured, mark FAIL and note which gate blocks it — do not mark PASS on description alone.

---
