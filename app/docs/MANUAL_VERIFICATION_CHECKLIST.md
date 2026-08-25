# Kalam — Manual Verification Checklist

**Runbook updated:** 2026-08-23 (adds T19/T20; folds K-34 into T12 and K-37 into T11) · **Archived run:** 2026-08-12 (Part 2 below)

This file is the single place listing every 🧑 *human manual gate* still open in
`app/docs/IMPROVEMENT_PLAN.md`, with concrete pass/fail steps for each. After you run it, send
back the Report table — the matching K-IDs get flipped to `✅` with your evidence, and any work
being held for visual sign-off (K-32's uncommitted Compass changes) can land.

---

# Part 1 — Open gates (runbook added 2026-08-21)

| Test | Item(s) | Gate in one line |
|---|---|---|
| T11 | K-26 + K-27 + K-37 | Sleep/wake recovery (docked webcam), phantom-stop after wake (step 2 pins the K-37 abandon fix), noise guard ("yes"/"no" boundary) |
| T12 | K-28 + K-34 | ITN protection — the user sentences; decimals/times must render intact ($5.50 / 10:30 / 2.5, never "$5. 50") |
| T13 | K-29 | Bare-"no" backtrack sentence (pre-verifies on a current build; tracker closes when a build ships) |
| T14 | K-23 + K-36 | Switch apps mid-transcription — record-time target; the held-transcript Paste button must be clickable |
| T15 | K-10 | Audio render-thread hygiene (`dropped=0`) |
| T16 | K-19 | VoiceOver ear-check + onboarding keyboard paths (updated for Compass) |
| T17 | K-30 | Compass window/map-states/per-pane smoke/hotkey capture/indicator/deep-link |
| T18 | K-31 + K-32 | Compass visual QA side-by-side vs the v1.2 mockups (light-chrome v1.3.x state) |
| T19 | K-36 | Actionable-overlay buttons (Open / Paste) accept clicks; non-action overlays stay click-through |
| T20 | K-38 | Long-dictation paste lands with no UI hitch; Escape responsive mid-transcription |

Everything else is closed: K-01, K-02, K-04, K-08, K-09, K-12 (via K-24), K-14, K-20, K-21 passed
in the archived 2026-08-12 run (Part 2); K-03, K-05…K-07, K-13, K-15–K-18, K-22, K-24, K-25,
K-33 are ✅ on automated evidence alone. K-11 is still ⬜ todo — not implemented, nothing to test
by hand. K-34 and K-40 closed 2026-08-22 on automated evidence alone; K-36/K-37/K-38 code
landed 2026-08-22 and their human checks are folded into this runbook (K-37 → T11 step 2,
K-34 → T12, K-36 → T14 + T19, K-38 → T20).

Estimated time: **~70–100 min**, in order — T11–T14 share the mic/log/sentinel state; T17/T18
want the app rebuilt from the current tree (the K-32 corrections live in the working tree,
uncommitted). T19–T20 add ~10 min and reuse the same session.

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
   log stream --predicate 'subsystem == "singhkays.Kalam" || subsystem == "singhkays.Kalam-test"' \
     --style compact > ~/kalam-test-log.txt 2>&1
   ```
   Run this in YOUR terminal on the machine the app runs on (the host — the Hermes
   agent's VM cannot see these logs). `log stream` captures only events AFTER it
   starts; if a session's file comes back header-only, recover retroactively instead:
   ```bash
   log show --last 120m --predicate 'subsystem == "singhkays.Kalam"' --style compact \
     | grep -E "Stopped collecting|Dictation target|Paste route"
   ```
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

## ✅ T11 — K-26 + K-27: sleep/wake recovery, docked webcam, noise guard

**Setup:** Toggle activation mode (Compass → Trigger). Webcam/docked mic attached. Log monitor
running. Baseline: one normal dictation works.

**Steps:**
1. **Post-wake dictation:** sleep the Mac ≥ 10 min (overnight is fine), wake, immediately press
   the hotkey and dictate a full sentence.
2. **Phantom-stop check (Toggle):** press the hotkey to START recording, let the Mac sleep
   *before* pressing it again; wake. The first press after waking must behave as a fresh start —
   it must NOT "stop" a phantom session left over from before sleep. (Pins K-37: since
   2026-08-22 the wake handler *abandons* any live PTT session — the machine is idle at wake,
   so the first post-wake press can only ever start.)
3. **Docked-webcam recovery:** with the webcam mic as the active input, sleep + wake, then
   dictate WITHOUT opening Settings. Then unplug/replug the webcam and dictate again.
4. **Noise guard:** in a quiet moment, press the hotkey and stay silent (or shuffle paper) for
   ~2 s, then stop.
5. **Guard boundary:** dictate a short "yes", then a short "no".
6. Optional log check over `~/kalam-test-log.txt`: expect a
   `System wake: resetting PTT state and refreshing audio input` line on each wake (counts only,
   never transcript/audio content).

**Expected (PASS):**
- Every post-wake dictation records normally — no instant-end, no wrong paste.
- Nothing is ever pasted after the silent/noise-only attempt (a "No speech detected"-style
  notice or plain nothing is fine) — **never** a filler word like "yeah".
- "yes"/"no" still dictate normally (guard does not eat real speech).
- The webcam/dock mic works straight after wake and after replug — no manual reordering in
  Settings at any point.

**FAIL if:** the first post-wake dictation ends instantly or pastes junk; any mic needs manual
reordering after wake/replug; the silent attempt pastes a word.

Result: ✅ PASS (2026-08-24) — user: all steps passed (post-wake dictation, K-37
phantom-stop check, docked-webcam wake/replug recovery, noise guard, yes/no boundary).

---

## ✅ T12 — K-28: ITN protection — the user sentences

**Setup:** ITN enabled (Compass → Cleanup pane). Target app focused. Judge ONLY the number-word
behavior — sentence-start capitalization and other cleanup are separate features.

Dictate each line and inspect the pasted result:

| # | Say | Expected (PASS) |
|---|---|---|
| 1 | "Don't worry, we consider you as one of us" | "one of us" stays words |
| 2 | "twenty one of us" | normalizes to "21 of us" (compound numbers still convert) |
| 3 | "five dollars and fifty cents" | "$5.50" (normal ITN still works) — K-34 pin: never "$5. 50". K-45 fixed 2026-08-24: trailing punctuation must NOT strand "cents" — "$5.50 cents." is now a FAIL |
| 4 | "I'm writing a two to three pager" | stays words ("2 - 3 pager" also acceptable) |
| 5 | "twelve to fourteen people are coming" | stays words |
| 6 | "first of all, thanks" | "first of all" stays words |

Optional: "call me at five five five one two three four" — must stay words, never "16 9".
Optional (K-34): "meeting at ten thirty" → "10:30", "version two point five" → "2.5" — never
with a space after the dot ("10: 30", "2. 5").

Control (K-44): flip the Cleanup master OFF (Compass → Cleanup), dictate "five five five one
two three four" again — raw ASR must come through untouched (words stay words, nothing
normalized), proving ITN is genuinely off now. Flip the master back ON afterwards.

**FAIL if:** any line 1/4/5/6 turns into a time/date ("02:58 pager", "13:48 people"), or line 2/3
fails to normalize, or any decimal/time shows the K-34 space ("$5. 50", "10: 30").

Result: 🟢 CLOSED 2026-08-24 (re-dictation passed; full history below — first run 2026-08-23
was a partial fail, fixed and machine-verified 2026-08-24). Historical PASS evidence (2026-08-23): "twenty one of us" → "21 of us";
"$5.50"; bonus "version two point five" → "2.5" (the K-34 punctuation fix holds live).
BENIGN: "two to three pager" → "2 to 3" — no corruption ("02:58" is the failure mode), and a
digit rendering was pre-declared acceptable; it proves ASR emitted digit-shaped text on that
attempt. HARD FAIL: "five five five one two three four" → "16 9" (the documented raw-ITN
signature — word-shaped input reached Nemo unmasked); NEW: "meeting at ten thirty" → "40".
Same utterance produced "5551234" on another attempt — ASR output shape varies between tries,
so protection must cover both forms. Filed as K-42 / K-43.
Fix status (2026-08-24, machine-verified): real-library probe reproduced all three failures at
the Nemo level; `ITNSpanProtector` now covers comma/period-separated runs, mixed word+digit
runs, and renders two-token spoken times itself ("meeting at ten thirty" → "meeting at 10:30";
the three-token form Nemo handles correctly stays unmasked). Engine 73/73; app-side targeted
suite 16/16 (processor 6, integration 9, shape canary 1). Re-dictate these lines on a fresh
build to flip K-28/K-42/K-43 — and note the cleanup-off control is now meaningful because ITN
respects the Cleanup master (K-44 fix).

Result (2026-08-24 re-run, post-fix build): 🟢 PASS 6/6 — "twenty one of us" → "21 of us";
"$5.50" (no K-34 space); "two to three pager" and "twelve to fourteen people" stayed words;
"first of all" intact. One new finding: line 3 pasted "$5.50 cents." — reproduced at the
library level and filed as **K-45** (Nemo strands "cents" when the utterance carries a
sentence-final period; same words without the period → clean "$5.50"). Not a regression of
K-42/K-43: all protected shapes held. K-28/K-42/K-43 remain 🧑-gated on one more dictation of
the phone/time lines (the ones that failed in 2026-08-23) plus the cleanup-off control above;
line 3's residual is tracked as K-45, not a T12 blocker.

Closed same day (2026-08-24): user dictated the previously-failing lines on the post-fix
build — "call me at five five five one two three four" pasted verbatim as words (never
"16 9"), "meeting at ten thirty" → "Meeting at 10:30.", "version two point five" → "Version
2.5", and with Cleanup OFF raw ASR came through untouched ("Five five five one two three
four"). K-28, K-42, K-43, K-44 flipped ✅ in IMPROVEMENT_PLAN.md with this evidence.
T12's remaining open item is none — only K-45 carried forward, and its fix landed 2026-08-24
(per-line terminal-punctuation strip around the ITN call; pins green). On the next build,
line 3 must render "$5.50" whether or not the dictation appends a period — "$5.50 cents."
is a FAIL. 🧑 optional confirm: dictate line 3 naturally on that build.

---

## ✅ T13 — K-29: bare-"no" backtrack regression

**Setup:** none beyond the baseline dictation.

**Steps:** dictate "Yep, there is a roadmap meeting, so no problem" and a variant like
"There's no way to do this quickly".

**Expected (PASS):** the FULL sentence is pasted — the trailing "no problem" survives and the
clause after "there's no way" is not deleted. (This pre-verifies the fix on a current build; the
tracker's K-29 gate formally closes when a build ships to daily use.)

**FAIL if:** text before/at "no problem" gets swallowed.

Result: ✅ PASS (2026-08-24) — both sentences pasted in full:
"Yep, there is a roadmap meeting, so no problem"
"There is no way to do this quickly."
Trailing "no problem" survived; nothing after "no way" was deleted. (Tracker note: K-29's
formal gate still closes only when a build ships to daily use — this pre-verification holds.)

---

## T14 — K-23: switch apps mid-transcription

**Setup:** sentinel clipboard. Repeat in EACH activation mode (Hold, Toggle, Double Tap,
Hold-or-Toggle).

**Steps:**
1. Focus TextEdit, start a dictation long enough that you can click away while ASR settles.
2. While the transcript is being produced, click into Terminal (a different app).
3. Watch where the transcript lands; then `pbpaste`.

**Expected (PASS):**
- The transcript lands in **TextEdit** (the app focused at record start) — via direct insert, not
  the clipboard; `pbpaste` still returns the sentinel.
- If direct insert fails, the overlay holds the transcript with a
  "Transcript ready — paste into TextEdit?" notice + **Paste** action, and clicking Paste puts it
  into the held target. Either outcome passes. (The Paste button being clickable is itself the
K-36 gate — the capsule accepts clicks only while an action button is on screen; see T19.)

**FAIL if:** the transcript appears in Terminal, or lands twice.

Result: 🔴 FAIL (2026-08-24, one attempt, Sublime Text → Terminal) — transcript pasted INTO
Terminal after the user clicked away post-stop; sentinel survived (`pbpaste` returned
KALAM-SENTINEL-1337, consistent with the CGEvent-unicode path). Under investigation: the
K-23 capture/route machinery exists (`KalamApp.swift:908` capture at record start;
`PasteService.PasteRouting.target` prefers the captured element when pids differ), so the
open question is whether record-time capture silently failed for Sublime Text (failure
branch at `KalamApp.swift:915` sets both target fields nil with NO log, degrading to the
old frontmost-at-paste-time behavior) or the routing read raced the user's click. Next step:
re-run with the Part 1 log monitor active and inspect the paste-route log lines.

Instrumented for diagnosis (2026-08-24, uncommitted, build-verified): record-start now logs
"Dictation target captured appName=… strategy=… pid=…" or
"Dictation target capture FAILED reason=…" / "capture SKIPPED"; paste-time logs
"Paste route=frontmost|capturedElement capturedPID=… frontmostPIDAtDecision=…" from a single
shared frontmost read. Rebuild, reproduce once, then:

    grep -E "Dictation target|Paste route" ~/kalam-test-log.txt | tail -4

Reading the outcome:
- "capture FAILED/SKIPPED" present → **Gap 1** (record-time capture never happened; likely
  Sublime's partial AX tree) — fix = broaden capture fallback.
- "captured appName=Sublime Text" AND "route=frontmost capturedPID=X frontmostPIDAtDecision=X"
  yet text visibly landed in Terminal → **Gap 2** (decision-to-synthesis race; both PIDs equal
  proves the decision was correct at its instant) — fix = re-check frontmost immediately before
  event synthesis inside PasteService.

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (per mode): ____________________

---

## T15 — K-10: audio render-thread hygiene

Same three probes as archived T5 below (they were deferred only because the agent lacked mic
permission — you can run them directly):

1. **Rapid re-record ×5:** ~1 s recording, stop, immediately start again — listen for
   clicks/dropouts.
2. **Long dictation:** 3+ continuous minutes — no gaps, waveform smooth, normal stop.
3. **Hygiene grep:**
   ```bash
   grep "Stopped collecting" ~/kalam-test-log.txt | tail -10
   ```
   Every line must end `dropped=0`.

**FAIL if:** audible glitches, or any `dropped=` count > 0 (note the scenario).

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

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
- **Menu-bar indicator:** 3-position setting renders in all three positions.
- **Deep link:** onboarding's Settings affordance opens Compass (at the Engine dive).

**Expected (PASS):** all of the above hold; no crash, no stuck state; settings persist across
relaunch.

Result: ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T18 — K-31 + K-32: visual QA vs the v1.2 mockups

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

**Why:** the capsule used to set `ignoresMouseEvents` unconditionally, so recovery buttons
rendered but could never be clicked. Since 2026-08-22 the window accepts clicks ONLY while an
action button is on screen (`DictationOverlayController.setState`).

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

## T20 — K-38: paste lands without a UI hitch

**Why:** cleanup + ITN + dictionary replacement used to run on the main thread at paste time.
Since 2026-08-22 they run off-main (Sendable snapshot hop in `TranscriptPostProcessor`), and
the global-Escape monitor no longer loads settings on every keystroke.

**Setup:** at least one dictionary rule exists (Compass → Dictionary). Log monitor running.

**Steps:**
1. Dictate 45–60 s of prose with deliberate grammar errors and several rule triggers.
2. Stop, and while ASR settles keep interacting (drag a window, scroll, type elsewhere).
3. The instant the paste lands, watch for a hitch: cursor freeze, beachball, dropped drag.
4. During the same long transcription, tap **Escape** a few times — each tap must respond
   immediately, including right as the transcript finishes.

**Expected (PASS):** paste lands with zero perceptible stall; output is still fully processed
(ITN, grammar, replacements all applied); Escape never lags.

**FAIL if:** a visible stutter exactly when the transcript lands, a delayed Escape response,
or processed-output differs from before the fix.

Result: 🟢 PASS on the hitch gate (2026-08-24) — dictated over 1 minute (spec: 45–60 s);
user: "There was no visible stutter anywhere, it took about 2 seconds to paste into the app."
(The ~2 s is post-stop ASR-settle latency, not a UI stall — the gate watches for hitches at
land-time.) Open sub-check: step 4's Escape-taps-during-transcription was not reported;
K-38 flips only after that is confirmed responsive.

---

## Report back (Part 1)

Copy this into your reply and fill it in — I'll flip the matching K-IDs to ✅ with evidence and
land anything being held on your sign-off:

| # | Item(s) | Result | Notes |
|---|---|---|---|
| T11 | K-26 + K-27 + K-37 wake/guard | ☐ | |
| T12 | K-28 + K-34 ITN + decimals | ☐ | |
| T13 | K-29 bare-"no" | ☐ | |
| T14 | K-23 + K-36 switch-app | ☐ | |
| T15 | K-10 contention | ☐ | |
| T16 | K-19 VO/keyboard | ☐ | |
| T17 | K-30 Compass | ☐ | |
| T18 | K-31+K-32 visual | ☐ | |
| T19 | K-36 overlay clicks | ☐ | |
| T20 | K-38 responsiveness | ☐ | |

---

# Part 2 — Archived: 2026-08-11 wave, executed 2026-08-12 (record only)

**Date of run:** 2026-08-12 · **Tester:** agent (CGEvent/AX automation) + user ·
**App build used:** Xcode Debug (`Kalam-test.app`)

> The T1–T10 run below predates Compass (K-30) and the K-26..K-29 wave: T8/T10 reference the
> deleted tabbed settings UI and the 900-pt window, both superseded. Results are kept for the
> record. The original intro line — "every 🧑 gate open after the 2026-08-11 wave; engine 41/41,
> full suite 79 passed / 0 failed / 3 skipped" — described the tree as of 2026-08-11.

Covered by that run: K-01 (stale-paste cancellation), K-02 (clipboard restore), K-04 (settings
tabs), K-08 (pasteboard exposure), K-09 (main-thread stall), K-10 (contention — deferred),
K-12 (relaunch → blocked → filed K-24), K-14 (per-mode hotkey), K-19 (partial), K-21 (window
width — superseded by K-30), K-30 (added later, gated in Part 1 T17).

| Covered items | What they are |
|---|---|
| K-01 | Stale-transcript cancellation (no wrong-context / double paste) |
| K-02 | Clipboard restore (success path + no-permission path) |
| K-04 | Settings per-tab smoke (post tab-split) |
| K-08 | Pasteboard exposure window shortened |
| K-09 | No main-thread stall during paste |
| K-10 | Audio render thread under contention (`dropped=0` hygiene) |
| K-12 | Relaunch lifecycle (`Quit & Reopen Kalam`) |
| K-14 🧑 gate | Per-mode hotkey smoke (Hold / Toggle / Double Tap / Hold or Toggle) |
| K-19 | VoiceOver + Full Keyboard Access pass |
| K-21 | Settings window width (900 pt, consistent) — **superseded by K-30**: the Compass window is fixed 980×660 and non-resizable |
| K-30 🧑 gate | Compass settings window: fixed 980×660, borderless, draggable by background, Cmd-W closes, single instance; map states (settled / engine missing / incomplete / no mic / key unset / empty dict / cleanup off); per-pane smoke (being heard toggles + indicator menu + mic drag, trigger presets + Record shortcut…, cleanup master dim, dictionary CRUD + search + covers, engine choose/copy, updates opens browser) |

**Not in this list:** K-11 (CI action pinning) is still `⬜ todo` — not implemented, nothing to
test. All other K-IDs (K-03, K-05…K-07, K-13, K-15–K-18, K-20, K-22) are `✅` with automated
verification complete and need no manual gate.

Estimated total time: **45–60 minutes**. Do the tests in order — later tests reuse state from
earlier ones (clipboard sentinel, onboarding reset).

---

## 0. Preparation (once, ~5 min)

1. **Build & launch the current app.**
   ```bash
   cd "/Volumes/My Shared Files/GitHub/Kalam"
   xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```
   Run the freshly built app (Xcode Run, or the built product in DerivedData). Grant
   **Microphone** and **Accessibility** permissions when prompted. Confirm the model folder is
   configured (Settings → Models shows a ready model) and a quick dictation works.
2. **Start the log monitor** in a terminal (leave it running for the whole session):
   ```bash
   log stream --predicate 'subsystem == "singhkays.Kalam"' --style compact \
     > ~/kalam-test-log.txt 2>&1
   ```
   (Use `tee` instead of `>` if you also want to see it live.)
3. **Set the clipboard sentinel** (do this before every clipboard test):
   ```bash
   printf 'KALAM-SENTINEL-1337' | pbcopy
   pbpaste   # → should print KALAM-SENTINEL-1337
   ```
   > Use `printf`, not `echo` — a trailing newline would change the clipboard content and break
   > the exact-equality restore guard.
4. Open a text editor (TextEdit or Notes) as the paste target, with a visible text cursor.

---

## T1 — K-01: No stale paste when a new recording starts (Toggle mode)

**Setup:** Settings → Shortcuts → Activation Mode → **Toggle**. Target app focused, cursor in a
blank document.


**Steps:**
1. Record a **long** first dictation (read a full paragraph, ~5+ seconds of speech).
2. Stop (toggle off). The ASR takes a moment — **immediately** (within ~1–2 s) toggle on again
   and dictate a short second phrase: *"second phrase"*.
3. Toggle off to stop. Wait ~5 s for both pipelines to settle.
4. Inspect the target document and the clipboard (`pbpaste`).
5. Repeat once more to confirm.

**Expected (PASS):**
- The **first** transcript is **never** pasted — not into the document, not into the clipboard.
- The **second** transcript is pasted **exactly once**.
- `pbpaste` returns `KALAM-SENTINEL-1337` (clipboard restored).
- No double paste, no wrong-context paste.

**FAIL if:** the first transcript appears anywhere, or the second phrase is pasted twice.

Result: ✅ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T2 — K-02: Clipboard restore

### T2a — Success path (long dictation → Cmd+V → restore)
**Setup:** sentinel clipboard; target app focused, cursor in a blank document.

1. Dictate a **long** text (>200 characters — roughly 2+ sentences; short dictations take the
   CGEvent-unicode path and never touch the pasteboard, so they test nothing here).
2. Wait ~1 s after the paste lands.
3. `pbpaste`.

**Expected (PASS):** the document contains the transcript; `pbpaste` returns
`KALAM-SENTINEL-1337` — the sentinel, not the transcript. Restore happens ~0.15 s after the
paste (see T3 for the timing measurement).

PASS ✅

### T2b — No-permission path (Accessibility revoked)
1. System Settings → Privacy & Security → **Accessibility** → switch **Kalam OFF**.
2. Sentinel clipboard again. In the target app, dictate something short.
3. `pbpaste` and look at the target app.

**Expected (PASS):** nothing is pasted anywhere (paste aborts at the AX-trust guard, *before*
any clipboard write); `pbpaste` still returns `KALAM-SENTINEL-1337`; the app does not crash and
recovers once permission is back.
4. **Re-enable Accessibility for Kalam** and confirm one normal short dictation works again.

> Note: the deep failure path (every paste strategy fails while AX is trusted) can't be forced
> from the UI — `postCmdV()` reports success even if the target ignores it. That path is covered
> by the 10 automated `PasteServiceTests` with injected fake strategies.

Result: ✅ PASS — Notes: The onboarding *repair* window on hotkey press with AX revoked is **designed** (`KalamApp.swift:782` — incomplete requirements → repair onboarding); paste aborted pre-clipboard; `pbpaste` kept the sentinel.

here's the terminal output

```
➜  macos-agent-vm pbpaste
KALAM-SENTINEL-1337
```


---

## T3 — K-08: Pasteboard exposure window

**Setup:** run this monitor in a second terminal (leave it running):
```bash
prev=""
while true; do
  cur="$(pbpaste 2>/dev/null)"
  if [ "$cur" != "$prev" ]; then
    printf '%s len=%s head="%s"\n' "$(date +%H:%M:%S.%3N)" "${#cur}" "${cur:0:40}"
    prev="$cur"
  fi
  sleep 0.02
done
```

> ⚠️ **Pitfall found in the first run:** pasting the monitor script into the terminal put the
> *script text* itself on the clipboard — so "the sentinel" was the script, and the restore
> correctly returned to it. Set the sentinel **after** the monitor is already running.

**Steps:**
1. Sentinel clipboard (set AFTER starting the monitor), target app focused. Note the current time.
2. Dictate a **long** text (>200 chars — must take the Cmd+V pasteboard path).
3. Watch the monitor output as the paste fires.

**Expected (PASS):**
- The transcript appears on the pasteboard **once**, for a **short window (≤ ~0.3 s)** — the
  new design is a 0.15 s grace delay + async commit wait; the old behavior was a flat 0.5 s.
- The log then shows the sentinel returning (`KALAM-SENTINEL-1337`).
- The monitor's last line for the cycle is the sentinel, not the transcript.

**FAIL if:** the transcript stays visible for ~0.5 s or longer, or the clipboard is left with
the transcript. (Optional evidence: paste the monitor output into the report.)

Result: ✅ PASS — Notes: Monitor shows the transcript (len=371) appearing and being replaced within the SAME 20 ms poll (both changes timestamped 23:14:43.3N) → exposure window ≤ ~20 ms, far under the old flat 0.5 s. Restore worked (clipboard returned to the pre-dictation content — which was the script text, not the sentinel; see the pitfall note above). Evidence below:

```
➜  ~ prev=""
while true; do
  cur="$(pbpaste 2>/dev/null)"
  if [ "$cur" != "$prev" ]; then
    printf '%s len=%s head="%s"\n' "$(date +%H:%M:%S.%3N)" "${#cur}" "${cur:0:40}"
    prev="$cur"
  fi
  sleep 0.02
done
23:13:46.3N len=208 head="prev=""
while true; do
  cur="$(pbpaste "
23:14:43.3N len=371 head="What's a Sentinel? A sentinel is just a "
23:14:43.3N len=208 head="prev=""
while true; do
  cur="$(pbpaste "
^C%
```

---

## T4 — K-09: No main-thread stall during paste

**Setup:** long dictation ready (Cmd+V path), target app focused.

**Steps:**
1. Dictate a long text and stop.
2. **Immediately** after stopping (while transcription/paste is still in flight), click the Kalam
   menu bar icon and open Settings; try interacting with the menu.
3. The paste should land normally; close Settings.
4. Optional deeper check — during another paste, sample the process:
   ```bash
   pgrep -fl Kalam          # note the PID
   sample <PID> 2 -file /tmp/kalam_sample.txt   # run this right at paste time
   grep -n "usleep\|waitForPasteboardCommit" /tmp/kalam_sample.txt
   ```
   Expected: **no** busy `usleep` loop on the main thread (the wait is now cooperative
   `Task.sleep` polling); the main thread shows normal short frames.

**Expected (PASS):** the app stays fully responsive during the paste — menu bar icon responds
instantly, Settings opens without a beachball, overlay animations don't freeze.

**FAIL if:** any UI interaction hangs or stutters while the paste is in flight.

Result: K-09 ✅ PASS / ⚠️ NEW FINDING (K-23) — Notes: No main-thread stall: the sample shows the main thread idle in mach_msg (no usleep/busy loop) and all UI interactions during the paste responded. The paste landed in the terminal instead of the editor because the paste targets the **front-most app at paste time**, while the overlay showed the app captured at record start — wrong-context paste when the user switches apps mid-transcription. Filed as **K-23** in IMPROVEMENT_PLAN.md.

The transcript did not paste to the text editor I had selected. When I clicked out of the text editor on the menu bar icon on an open settings, I tried this multiple times.

sampling command happened afterwards the paste which happened into the terminal app instead of the text editor as soon as I clicked on it during transcript after toggle off 

```
Analysis of sampling Kalam-test (pid 81711) every 1 millisecond
Process:         Kalam-test [81711]
Path:            /Users/USER/Library/Developer/Xcode/DerivedData/Kalam-efcflyzjfuhhqzaefevlisnexyle/Build/Products/Debug/Kalam-test.app/Contents/MacOS/Kalam-test
Load Address:    0x100778000
Identifier:      singhkays.Kalam-test
Version:         1.1 (1)
Code Type:       ARM64
Platform:        macOS
Parent Process:  debugserver [81714]
Target Type:     live task

Date/Time:       2026-08-11 23:21:11.700 -0700
Launch Time:     2026-08-11 17:22:59.725 -0700
OS Version:      macOS 26.6.1 (25G76)
Report Version:  7
Analysis Tool:   /usr/bin/sample

Physical footprint:         143.2M
Physical footprint (peak):  200.0M
Idle exit:                  untracked
----

Call graph:
    1743 Thread_2905677   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1743 start  (in dyld) + 6992  [0x1857f04e4]
    +   1743 __debug_main_executable_dylib_entry_point  (in Kalam-test.debug.dylib) + 12  [0x102e2ddcc]  KalamApp.swift:0
    +     1743 static KalamApp.$main()  (in Kalam-test.debug.dylib) + 40  [0x102dfb660]  /<compiler-generated>:0
    +       1743 static App.main()  (in SwiftUI) + 224  [0x1bb79c778]
    +         1743 runApp<A>(_:)  (in SwiftUI) + 104  [0x1bb4d08d8]
    +           1743 specialized runApp(_:)  (in SwiftUI) + 140  [0x1bb115af8]
    +             1743 NSApplicationMain  (in AppKit) + 880  [0x18a0797b0]
    +               1743 -[NSApplication run]  (in AppKit) + 368  [0x18a0a113c]
    +                 1743 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 72  [0x18ac43678]
    +                   1743 -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]  (in AppKit) + 688  [0x18ac4396c]
    +                     1743 _DPSNextEvent  (in AppKit) + 576  [0x18a0ae084]
    +                       1743 _DPSBlockUntilNextEventMatchingListInMode  (in AppKit) + 228  [0x18a75a3d0]
    +                         1743 _BlockUntilNextEventMatchingListInMode  (in HIToolbox) + 48  [0x192bf014c]
    +                           1743 ReceiveNextEventCommon  (in HIToolbox) + 488  [0x192a668bc]
    +                             1743 RunCurrentEventLoopInMode  (in HIToolbox) + 320  [0x192a63560]
    +                               1743 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 532  [0x185d4a234]
    +                                 1741 __CFRunLoopRun  (in CoreFoundation) + 1188  [0x185c779c4]
    +                                 ! 1741 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x185c790d8]
    +                                 !   1741 mach_msg  (in libsystem_kernel.dylib) + 24  [0x185b77fc0]
    +                                 !     1741 mach_msg_overwrite  (in libsystem_kernel.dylib) + 480  [0x185b809c0]
    +                                 !       1741 mach_msg2_internal  (in libsystem_kernel.dylib) + 76  [0x185b8a5a4]
    +                                 !         1741 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x185b77c34]
    +                                 1 __CFRunLoopRun  (in CoreFoundation) + 1516  [0x185c77b0c]
    +                                 ! 1 mach_port_extract_member  (in libsystem_kernel.dylib) + 36  [0x185b7b384]
    +                                 !   1 _kernelrpc_mach_port_extract_member_trap  (in libsystem_kernel.dylib) + 8  [0x185b77b20]
    +                                 1 __CFRunLoopRun  (in CoreFoundation) + 2356  [0x185c77e54]
    +                                   1 __CFRunLoopDoBlocks  (in CoreFoundation) + 396  [0x185c78a10]
    +                                     1 __CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__  (in CoreFoundation) + 28  [0x185c78ad0]
    +                                       1 __85-[NSApplication(NSAppssassination) _setNeedsUpdateToReflectAutomaticTerminationState]_block_invoke  (in AppKit) + 1104  [0x18a1d0120]
    +                                         1 _LSSetApplicationInformationItem  (in LaunchServices) + 216  [0x186167080]
    +                                           1 _LSSetApplicationInformation  (in LaunchServices) + 316  [0x1861618f4]
    +                                             1 LSClientToServerConnection::sendWithReply(void*)  (in LaunchServices) + 68  [0x1861610b4]
    +                                               1 xpc_connection_send_message_with_reply_sync  (in libxpc.dylib) + 284  [0x185893eb0]
    +                                                 1 dispatch_mach_send_with_result_and_wait_for_reply  (in libdispatch.dylib) + 60  [0x100afef80]
    +                                                   1 _dispatch_mach_send_and_wait_for_reply  (in libdispatch.dylib) + 548  [0x100afebe0]
    +                                                     1 mach_msg  (in libsystem_kernel.dylib) + 24  [0x185b77fc0]
    +                                                       1 mach_msg_overwrite  (in libsystem_kernel.dylib) + 480  [0x185b809c0]
    +                                                         1 mach_msg2_internal  (in libsystem_kernel.dylib) + 76  [0x185b8a5a4]
```

---

## T5 — K-10: Audio render thread under contention

**Setup:** Toggle mode, models ready. Log monitor running (step 0.2).

**Steps:**
1. **Rapid re-record (×5):** record ~1 s, stop, and immediately start again — 5 times in quick
   succession. Listen for clicks/pops/dropouts; watch the overlay.
2. **Long dictation:** dictate continuously for **3+ minutes**. No audio dropouts, waveform
   stays smooth, stop works normally at the end.
3. **Hygiene check** after all of the above:
   ```bash
   grep "Stopped collecting" ~/kalam-test-log.txt | tail -10
   ```
   Every line must end in `dropped=0`.

**Expected (PASS):**
- No audible glitches in any of the recordings; each rapid re-record captures clean audio.
- The 3-minute recording transcribes correctly with no gaps.
- Every `Stopped collecting … dropped=0` — zero contention drops.

**FAIL if:** any glitch, or any `dropped=` count > 0 (report the number and the scenario).

Result: ⏸️ DEFERRED to human (2026-08-12) — the agent cannot run this: it requires granting microphone permission to the app, which the user withheld. The machine-verifiable half is green (`AudioCaptureExchangeTests`, 8 tests — contention drops counted, render-thread publish is µs). To close K-10: grant mic to the app, then run the three steps above and check `grep "Stopped collecting"` for `dropped=0`.


---

## T6 — K-12: Relaunch lifecycle (`Quit & Reopen Kalam`)

**Setup:** quit Kalam fully (menu bar icon → Quit, or `killall Kalam`).

**Steps:**
1. Reset onboarding state:
   ```bash
   defaults delete singhkays.Kalam-test internal.hasCompletedRequiredSetup
   ```
   > ⚠️ Use the domain matching YOUR running build: the Xcode/debug build is **`singhkays.Kalam-test`**;
   > only the released app uses **`singhkays.Kalam`**.
2. Launch Kalam → the **first-run onboarding** window appears.
3. Walk to the **Accessibility** step (step 2). Click **"Quit & Reopen Kalam"**.
4. Watch what happens; then check:
   ```bash
   pgrep -fl Kalam
   ```
5. Complete the remaining onboarding steps (hotkey, model) and verify the app runs normally.

**Expected (PASS):**
- The app **quits and automatically reopens itself** — it does not just quit and stay dead.
- `pgrep -fl Kalam` shows **exactly one** Kalam process (no zombie second instance, no
  duplicates).
- The reopened onboarding shows Accessibility as trusted/green (the fresh instance picked up
  the grant), and the flow completes normally.

**FAIL if:** the app quits without relaunching, two instances linger, or the relaunched instance
doesn't see the permission.

Result: ⚠️ CANNOT PASS AS WRITTEN — new finding **K-24**. The "Quit & Reopen Kalam" button is unreachable: `confirmAccessibilityEnabled()` (which sets the `.enabledPendingRelaunch` state that shows the button) has **no caller** in the app — only in tests (`OnboardingFlowTests`). Verified live: with Accessibility granted at TCC level but the running process not yet trusted, clicking "Grant Access" flips the row to "Open System Settings" and never to "Quit & Reopen Kalam". The `AppRelauncher` machinery itself is unit-tested (3 `AppRelauncherTests`). Fix tracked as K-24 in IMPROVEMENT_PLAN.md. (Also: your debug build's bundle id is `singhkays.Kalam-test`, so the original `defaults delete singhkays.Kalam …` was a no-op.)

---

## T7 — K-14 🧑 gate: Per-mode hotkey smoke

For each mode: Settings → Shortcuts → **Activation Mode** → pick the mode → test with the
hotkey into a focused text document. After each mode, confirm no "stuck recording" state
(overlay gone, next press works).

| Mode | Expected behavior |
|---|---|
| **Hold** | Press & hold → recording starts immediately; **release** → stops + pastes. Quick tap → starts and immediately stops (harmless, no crash, no stuck state). |
| **Toggle** | First press → recording starts; **next press** → stops + pastes. Nothing else starts/stops it. |
| **Double Tap** | Single tap → nothing happens (no overlay). **Two taps within ~0.35 s** → recording starts; next press → stops + pastes. |
| **Hold or Toggle** (default) | Press and hold **≥ ~0.5 s**, release → stops + pastes (hold behavior). **Quick tap** (< 0.45 s) → recording *continues* (converts to toggle); next press → stops + pastes. |

**Expected (PASS):** every mode matches the table; the overlay appears with the target-app row;
the transcript lands once in the target document; clipboard restored; no phantom starts, no
double paste, no stuck recording; switching modes in Settings applies immediately.

Result: ✅ PASS ☐ FAIL ☐ UNCLEAR — Notes (per mode): ____________________

---

## T8 — K-04: Settings per-tab smoke (post tab-split)

**Steps:**
1. Open Settings (menu bar icon → Settings…). Click through **every** sidebar tab: **General,
   Shortcuts, Refine, Models, Updates, Word Replacement** — each must render without crash or
   layout breakage.
2. Interact in each tab:
   - **General:** toggle a setting (e.g. launch-at-login / chime), change microphone if shown.
   - **Shortcuts:** change the activation mode and the key combination; save.
   - **Refine:** toggle cleanup/ITN options.
   - **Models:** the configured model shows as ready; the tab renders without re-prompting.
   - **Updates:** renders (browser-based update info).
   - **Word Replacement:** add an entry, edit it, sort, delete it, use the search/clear-search
     buttons.
3. **Quit and relaunch Kalam** → reopen Settings → confirm the changes from step 2 persisted
   (mode, key, replacement entry present).

**Expected (PASS):** all tabs render and behave; settings persist across relaunch; no console
errors in the log monitor.

Result: ✅ PASS ☐ FAIL ☐ UNCLEAR — Notes: ______________________________

---

## T9 — K-19: VoiceOver + Full Keyboard Access

**Setup:** enable VoiceOver (**⌘F5**) and Full Keyboard Access (System Settings → Accessibility →
Keyboard → Full Keyboard Access → ON). You can do this test with a sighted helper or by ear.

**Settings pass:**
1. Open Settings. VoiceOver-navigate every tab.
2. **Word Replacement:** each icon-only button (add, sort, delete, clear-search) must announce a
   meaningful label — e.g. "Add replacement", not "Button" or silence.
3. **Shortcuts:** the **Activation Mode dropdown** must be reachable and must announce its
   current value (e.g. "Hold or Toggle") — it was previously hidden from VoiceOver.
4. Decorative chevrons in Shortcuts must not be announced as extra stops.

**Onboarding pass:**
1. With onboarding open (re-trigger via the T6 reset, or quit + `defaults delete
   singhkays.Kalam internal.hasCompletedRequiredSetup` + relaunch):
   - Press **Esc** → the onboarding window **closes** (new K-19 keyboard path).
   - Reopen onboarding; **Tab / arrow keys** must move through every control; every control is
     reachable and announced.

**Expected (PASS):** all buttons announce labels; the dropdown is exposed with its value;
onboarding is fully keyboard-drivable including Esc-to-close.

Result: 🟡 PARTIAL (agent-verified, 2026-08-12) — live AX inspection: the Activation Mode dropdown is exposed as `AXMenuButton` with **description = "Toggle"** (the K-19 label fix works; VoiceOver will announce the value), and the Dictionary tab shows labeled buttons **"Add rule"** and **"Sort by spoken phrase"**. Onboarding Esc and the VoiceOver ear-check still need a human. Bonus finding while testing: the Dictionary header renders the raw template `(manager.entries.count) rules • (activeRuleCount) active` — filed as **K-25**.

---

## T10 — K-21: Settings window width

**Steps:**
1. Open Settings. Measure the window width — either eyeball it (750 vs 900 pt is clearly
   visible) or measure:
   ```bash
   osascript -e 'tell application "System Events" to tell process "Kalam-test" to get size of window 1'
   ```
   > Use **`Kalam-test`** when running the Xcode/debug build; `Kalam` only for the released app.
   (needs Accessibility permission for your terminal; the first number is the width)
2. Close Settings, reopen → same width.
3. Resize the window, close, reopen → width starts consistent again (no 750/900 jump between
   creation and configure paths).

**Expected (PASS):** the window opens at **900 pt** wide every time — a single consistent
constant, no mismatch between first-open and subsequent opens.

Result: ✅ PASS (measured by agent, 2026-08-12) — `osascript … get size of window "Settings"` on process `Kalam-test` returned **900×672** at first open, **900×672** after close+reopen, and **900×672** after resizing to 640×500, closing, and reopening. Single consistent 900 pt constant, no 750/900 mismatch.

➜  ~ osascript -e 'tell application "System Events" to tell process "Kalam" to get size of window 1'
64:68: execution error: System Events got an error: Can’t get process "Kalam". (-1728


---

## Report back

Copy this table into your reply and fill it in. For any FAIL/UNCLEAR, add one or two sentences:
what you did, what happened, what you expected.

| # | Item | Result | Notes |
|---|---|---|---|
| T1 | K-01 stale-paste cancellation | ✅ PASS | |
| T2 | K-02 clipboard restore | ✅ PASS | T2b onboarding repair window = designed behavior |
| T3 | K-08 pasteboard window | ✅ PASS | ≤ ~20 ms window (was 0.5 s) |
| T4 | K-09 main-thread stall | ✅ PASS | + new finding K-23 (paste follows frontmost at paste time) |
| T5 | K-10 audio contention | ⏸️ DEFERRED to user | needs mic permission (withheld) |
| T6 | K-12 relaunch | ⚠️ BLOCKED → K-24 | button unreachable; machinery unit-tested |
| T7 | K-14 per-mode hotkey smoke | ✅ PASS | |
| T8 | K-04 settings tabs | ✅ PASS | |
| T9 | K-19 VoiceOver/keyboard | 🟡 PARTIAL | dropdown + buttons labeled (live AX); VO ear-check + Esc open |
| T10 | K-21 window width | ✅ PASS | 900×672 ×3 (open/reopen/after-resize) |

Useful attachments if something fails: the relevant slice of `~/kalam-test-log.txt`, a
screenshot, and the T3 monitor output. Once I have your results I'll flip the matching K-IDs to
`✅` in `IMPROVEMENT_PLAN.md` (with evidence) and fix anything that came back unexpected.

---

## Session notes (2026-08-12, agent-run follow-up)

Follow-up run executed by the agent via CGEvent/AX automation on the debug build
(`Kalam-test.app`, bundle id `singhkays.Kalam-test` — the checklist's original `Kalam`/
`singhkays.Kalam` names only apply to the released build).

- **T3 (K-08) interpretation:** the monitor's two changes share the same 20 ms timestamp —
  the transcript sat on the pasteboard for **≤ ~20 ms**, then the restore returned the prior
  clipboard content. The "sentinel" never appeared because pasting the monitor script into the
  terminal had put the script text on the clipboard — the restore correctly returned to *that*.
  K-08 = PASS.
- **T4 (K-09) interpretation:** PASS for the stall question (main thread idle in `mach_msg`,
  UI responded during paste) — the paste landing in Terminal instead of the editor is a
  separate issue: paste targets the **front-most app at paste time** (K-23, new finding).
- **T2b (K-02) interpretation:** PASS — the onboarding *repair* window on hotkey press with
  Accessibility revoked is designed behavior (`KalamApp.swift:782` guard), and the clipboard
  stayed untouched (paste aborts at the pre-snapshot AX-trust check).
- **T6 (K-12):** the "Quit & Reopen Kalam" button cannot appear — `confirmAccessibilityEnabled()`
  (the only setter of the `.enabledPendingRelaunch` state) has no app-side caller (K-24, new
  finding). The relaunch machinery itself remains covered by `AppRelauncherTests`.
- **T5 (K-10):** deferred to a human — running it requires microphone permission, which the
  user withheld. The audio-path contention invariants are covered by `AudioCaptureExchangeTests`.
- **T9 (K-19):** verified via live AX: Activation Mode dropdown = `AXMenuButton` with
  description "Toggle" (label fix live); Dictionary buttons "Add rule" / "Sort by spoken
  phrase" labeled. Remaining human bits: VoiceOver spoken-output pass, onboarding Esc,
  Full Keyboard Access tab-through.
- **Bonus finding (K-25):** the Dictionary header shows the raw template
  `(manager.entries.count) rules • (activeRuleCount) active` — `WordReplacementView.swift:59`
  uses `"\\(...)"` (double backslash renders a literal `\(`). One-line fix: single backslash.
- **Environment notes:** the VM's admin auth prompt (from the System Settings toggle attempt)
  could not be dismissed programmatically (secure-input mode) — cancel it manually if still
  on screen. All TCC rows and UserDefaults test keys were reverted after the run.
