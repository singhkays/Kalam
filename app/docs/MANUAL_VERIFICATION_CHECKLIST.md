# Kalam — Manual Verification Checklist

**Slimmed down 2026-08-25:** closed-gate test scripts and historical testing notes were
removed; what remains is (a) the runbook for the four still-open gates and (b) a one-line-per-test
verification record. Full detail for any past round lives in git history
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`) and in the per-K rows +
execution notes of `app/docs/IMPROVEMENT_PLAN.md`.

---

---

# Runbook for the open gates

Still open: **T16** (K-19 VoiceOver/keyboard), **T17** (K-30 Compass smoke),
**T18** (K-31+K-32 visual QA vs mockups — Compass Settings window, NOT onboarding),
**T19** (K-36 overlay click rules), **T21/T22** (K-44 cleanup-master gate + its
dictionary scope). Everything else in Part 1 has passed; see the verification record below.

Run order tip: do T21 and T22 back-to-back (one settings flip serves both); T21 needs the
Cleanup master left OFF, so run them BEFORE any test that wants cleanup on.

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

# Instructions for the open gates

## T16 — K-19: VoiceOver + Full Keyboard Access (updated for Compass)

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T17 — K-30: Compass window + map states + per-pane smoke

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T18 — K-31 + K-32: visual QA vs the v1.2 mockups

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T19 — K-36: overlay buttons clickable; other states stay click-through

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T21 — K-44a: Cleanup master OFF stops ITN (spoken numbers stay words)

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

**Run 2026-08-25 (cleanup OFF): PASS.** Dictated "One of us, two to three paid eager, five
dollars and fifty cents." → pasted verbatim: no 21, no 2 - 3 pager, no $5.50. ITN did not
run with the master off.

---

## T22 — K-44b: dictionary rules still fire with Cleanup OFF (deliberate scope)

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (remember to delete the test rule):
**Run 2026-08-25 (cleanup OFF): PASS.** Rule `open ai` → `OpenAI` fired while the Cleanup
master was still off; spoken numbers in the same session stayed words (T21). Note: dictated
as "Open AI" and pasted "Open AI" — case-insensitive match, replacement kept the dictated
capitalization via preserveCase (default true), which is correct rule behavior, not a miss.
(Test rule deleted afterwards.)

---

# Verification record (closed gates)

| Test | Items | Date | Verdict | Evidence (one line) |
|---|---|---|---|---|
| T11 | K-26 + K-27 + K-37 | 2026-08-24 | PASS | sleep/wake with docked webcam, phantom-stop, noise guard, yes/no boundary all green |
| T12 | K-28 + K-34 | 2026-08-24 | PASS 6/6 | phone sentence stayed words (never "16 9"), "Meeting at 10:30.", "Version 2.5"; Cleanup OFF returned raw ASR (K-44 control) |
| T13 | K-29 | 2026-08-24 | PASS (pre-verify) | both bare-"no" sentences pasted complete; tracker closes when a build ships |
| T14 | K-23 + K-36 | 2026-08-24 | PASS | transcript followed into Sublime Text automatically after switching apps; Toggle + Double Tap verified, Hold cancels by design (release = stop) |
| T15 | K-10 | 2026-08-24 | PASS | glitch-free rapid re-records + 4-min dictation; host log `Stopped collecting … dropped=0` |
| T20 | K-38 | 2026-08-24 | PASS (hitch gate) | >1-min dictation, zero visible stutter, ~2 s paste latency; Escape sub-check never explicitly reported |

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (per-app): ______________________

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

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

# Part 4 — Indicator B verification (shipped 2026-08-26, no dwell)

**What shipped:** single-file `DictationOverlayController.swift` — universal rim (1px double-stroke + elevation) for contrast on white `#FFFFFF` and obsidian `#0B0B0D`, green ring `CAGradientLayer` conic `transparent 255deg → #52B788 360deg` + blurred glow twin, gated to **whisper listening slow 3.6s**, **all transcribing fast 2.4s**, **caret listening never**, **machined listening never**, **pausing never**; light bars green in both appearances (`PillLevelGlyphView.ink` and caret chip dot/bars stay `#52B788`); `minStateDwellSeconds` stays `0.25` — no 0.65s hold, transcribing flips to `held`/`success` immediately on ASR return; Reduce Motion shows static 1px hairline at 48% (`#52B788` at `.48`), no rotation. Fallback law intact: `held`/`blocked` → `A` capsule; `H` no-caret → `A`.

**Spec authority:** `app/docs/plans/kalam-indicator-v1/contrast-remedy.html` (interactive speeds + rim) and `app/docs/plans/kalam-indicator-v1/index.html` § B variant (shipped 2026-08-26). Tokens untouched: `kalam-onboarding-v3.2 --acc #1A5C3A / #2A9D5C` and `kalam-compass-swiftui-v1.3.8`.

**Proof requirement:** host Mac only — VM cannot render the overlay window or its `CALayer` animations. Capture at 1:1 with Digital Color Meter handy to prove the rim delta (≥18% luminance on white, ≥22% on obsidian). Record 5 s clips: timer must tick, arc must turn clockwise. One screenshot per row below plus one short word dictation proving no dwell (paste immediate).

## Indicator B verification — 10-row manual matrix (host Mac, 1:1, screenshots required)

| # | Desk | Appearance | Style | State | Must show | Result |
|---|---|---|---|---|---|---|
| 1 | Paper `#FAFAF7` (Notes) | Light | Whisper | Listening | Pill with **slow 3.6s ambient green arc + glow** + green 3-bar EQ + timer + universal rim visible at 1:1; no white-loss | ☐ PASS ☐ FAIL |
| 2 | White `#FFFFFF` (TextEdit on white page) | Light | Whisper | Listening | Same pill — **rim holds, no white-on-white vanishing**; green bars stay `#52B788` | ☐ PASS ☐ FAIL |
| 3 | White `#FFFFFF` | Light | Whisper | Transcribing (≥0.5 s burst) | Pill with **fast 2.4s arc + glow + shimmer** — shows ~75° even on a 0.5 s burst; then flips immediately to held (no dwell) | ☐ PASS ☐ FAIL |
| 4 | Obsidian `#0B0B0D` (Xcode editor) | Dark | Whisper | Listening | Pill with **slow 3.6s arc + glow** + green EQ — **rim holds on obsidian**, no dark-on-dark vanishing | ☐ PASS ☐ FAIL |
| 5 | Obsidian `#0B0B0D` | Dark | Machined | Listening | **Deck waveform hero, NO ring** — waveform + timer only; rim + elevation visible on deck | ☐ PASS ☐ FAIL |
| 6 | Obsidian `#0B0B0D` | Dark | Machined | Transcribing | Deck with **fast 2.4s arc + glow + shimmer** (capsule chrome); immediately flips to held on ASR return | ☐ PASS ☐ FAIL |
| 7 | Paper `#FAFAF7` | Light | Caret | Listening | **Chip trails caret: text → caret bar → chip** — green dot + 3 green bars + timer, **NO ring**; chip lifts via shadow on paper | ☐ PASS ☐ FAIL |
| 8 | Paper `#FAFAF7` | Light | Caret | Transcribing | **Fallback deck with fast 2.4s arc** (chip window hidden per fallback law — chip never shows a ring; deck takes over) | ☐ PASS ☐ FAIL |
| 9 | Any (Paper/White/Obsidian) | Light/Dark | Any | Pausing | **No ring anywhere** — whisper shows pill with floor bars + slow dot; machined shows deck at floor; caret shows dim chip; Reduce Motion still static | ☐ PASS ☐ FAIL |
| 10 | Any | Light/Dark | Any | Held / Blocked | **Fallback A capsule with Paste / Open Settings** — never a pill or chip; buttons fire per K-36; no ring on the held capsule | ☐ PASS ☐ FAIL |

**Additional gates carried from `contrast-remedy.html`:**

- [ ] **Reduce Motion ON** — run rows 1 + 7 with System Settings → Accessibility → Display → Reduce motion ON: all spinning becomes the static hairline (`1px #52B788 at 48%` + breathing glow disabled), no rotation; bars remain green; rim still visible. Toggle back OFF and confirm rotation resumes at correct speeds.
- [ ] **No-dwell proof** — in Whisper mode, dictate a single short word (ASR < 0.6 s) and observe the pill: transcribing appears with the fast arc, then flips to held/success **without a lingering ~0.65 s hold**; paste is immediate. Verify `minStateDwellSeconds` still `0.25` in code (grep `minStateDwellSeconds` in `DictationOverlayController.swift`).
- [ ] **Universal rim proof** — with rim, place whisper listening pill on White `#FFFFFF` and on Obsidian `#0B0B0D`; Digital Color Meter at the pill edge must read a clear rim delta (the double-stroke + shadow prevents vanishing at either extreme). Toggle appearance Light ↔ Dark; rim adapts (light: black 10% inner + white 65% outer at 16% shadow; dark/machined: white 14% inner + black 18% outer at 28% shadow).
- [ ] **Light bars proof** — Light appearance, whisper listening and caret listening both show **green `#52B788` bars/dot** (use Digital Color Meter), not black. Toggle Dark and confirm same `#52B788`.

**Evidence to attach to PR / handoff (host Mac):** 10 screenshots (one per row, 1:1, desk label visible) + 2 clips (3.6s slow vs 2.4s fast at arm's length) + 1 no-dwell clip + Digital Color Meter reads for White and Obsidian rims. If a row cannot be captured, mark FAIL and note which gate blocks it — do not mark PASS on description alone.
