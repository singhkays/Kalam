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
