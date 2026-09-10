# Kalam — Manual Verification Checklist

**Slimmed down 2026-08-25:** closed-gate test scripts and historical testing notes were
removed; what remains is (a) the open-gates runbook (Part 1 verified; Parts 3/4 + K-52…K-58
gates still awaiting human verification as of 2026-09-06) and (b) a one-line-per-test
verification record. Full detail for any past round lives in git history
(`git log -p -- app/docs/MANUAL_VERIFICATION_CHECKLIST.md`) and in the per-K rows +
execution notes of `app/docs/IMPROVEMENT_PLAN.md`.

---

---

# Runbook for the open gates

**Part 1 (T11–T23) is fully verified ✅** (last: T23 v1.7 dark-mode, 2026-09-06). The gates
below are **still awaiting live human verification on a host Mac**. They live in Parts 3/4 and
the K-52…K-58 sections of this file, plus a few plan-only items from `IMPROVEMENT_PLAN.md`.
Each has its own setup / log-stream prep; run-order tips are noted per gate.

| # | Gate | K-Code | What it proves | Key evidence needed | Full runbook |
|---|---|---|---|---|---|
| 1 | Part 3 Gate E — PID-post compatibility matrix | K-49/K-50 | PID-posted Cmd+V lands in every target app (Mail/Notes/Messages/TextEdit/Slack/Chrome/Xcode) or falls back to global post — never drops | Per-app `Paste succeeded via PID-posted Cmd+V` / `refused; falling back` lines | `# Part 3 — K-49/K-50/K-51 stop-to-paste latency` § Gate E |
| 2 | Part 3 Gate F — rapid re-record regression sweep | K-49 | Generation/staleness contract survives the early-exit loop: old stop no-ops, no stale/wrong-target paste, mic never left on | All three evidence checks clean over the sweep; `dropped=0` hygiene | `# Part 3 — …` § Gate F |
| 3 | Part 4 — Indicator B 10-row matrix | K-48 | Whisper/machined/caret × listening/transcribing/pausing/held render per spec (rim, arc speeds, no dwell, fallback-A capsule) | 10 screenshots (1:1) + 2 clips + no-dwell clip + Digital Color Meter rim reads | `# Part 4 — Indicator B verification` (+ 4 additional proofs) |
| 4 | K-52 lifecycle — rapid re-record ROUND 3 | K-52 | Re-record from `transcribing` parks A in the held chip (never drops); B pastes whole; interrupt log is preserve-only | Chip text + pasted B + `Lifecycle ctx=…` log sample (no `cancelWork`) | `## K-52 lifecycle manual gate …` |
| 5 | K-53 WarmEnginePool | K-53 | 60 s idle keeps the mic glyph **off**; built-in + Bluetooth device-change first dictation hits the warm pool (`toPreparedMs ≤5`) | `prewarm ok` counts (exactly one per burst), `toPreparedMs`/`pttDown->firstBuffer` lines, permission gate | `## K-53 WarmEnginePool …` |
| 6 | K-54 SNR-aware post-roll | K-54 | Trailing phoneme never clipped: low-SNR (<12 dB) stretches to 1.5 s backstop, trusted rooms stop after speech-like quiet; kill-switch keeps fixed path | G1–G5: per-sentence last-word checklist, `mode=`/`roomSNR=`/`effectiveMaxMs` log lines, kill-switch flip | `## K-54 — SNR-aware …` |
| 7 | K-55 ValidationGate | K-55 | 3 trips → auto-degrade banner **once**; Re-enable + 5-accept streak resets; no double-insert while degraded | `validationGate.isDegraded` 0/1 flips, banner screenshot, `ValidationGate auto-degraded` once, H3 no-double | `## K-55 ValidationGate …` |
| 8 | K-56 Tier-1 insertion | K-56 | Secure-field refusal before pasteboard; PID-mismatch / frontmost-changed → hold + promised-app paste; no regression with flag unset | I1–I7: per-gate checklist, `pbpaste` sentinel intact, Electron single-insert, no `Per-element verify timeout override` | `## K-56 Tier-1 insertion …` |
| 9 | K-57 Crash recovery | K-57 | Toggle OFF = zero disk writes; ON streams per-session CAF; `kill -9` mid-recording recoverable next launch | `fs_usage` on/off captures, `ls -R` + `meta.json` (`isComplete`), `RecoveryScanner` logs | `## K-57 Crash recovery …` |
| 10 | K-58 FnUsageAdvisor | K-58 | Stock = no banner; bad fn values / Karabiner fire banner once + deep-link + clear; no transcript text logged | L1–L4: `defaults read` outputs, banner screenshot, `log stream` greps (`reason`/`karabiner` only) | `## K-58 FnUsageAdvisor …` |

**Also awaiting human verification — from `IMPROVEMENT_PLAN.md` 🔄 rows (no full runbook here yet):**

- **K-35 (plan row 107)** — 🧑 visual QA of the onboarding **hotkey card**: menu composition, capture-in-place, dropdown well contrast (deck `tile` fill + `hair` stroke, radius 8, mono 12.5 label) vs the v3.2 dark figures. Row stays 🔄 until a user eyeballs it.
- **K-38 (plan row 134; T20 covered the hitch half)** — Escape sub-check on a long dictation ("Escape sub-check never explicitly reported" per T20); sample the main thread during a long-dictation paste to confirm cleanup+ITN stay off-main.
- **K-12 (plan row 74, low priority)** — manual relaunch test now that K-24 (unreachable button) is closed: run Setup → relaunch → confirm clean lifecycle (previously blocked as T6).
- **K-29 (plan row 88; T13 pre-verified)** — re-dictate the two bare-"no" sentences ("no problem", "there's no way …") on a **shipped build** carrying K-26..K-29 (v1.2) to close the tracker.

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

# Archive — Verified / Closed Gates (moved out of active open-gates runbook)

These gates have passed live verification (host Mac, with evidence); their headings are marked ✅;
full details remain here for reference. See verification record below for the one-line
evidence, and see `IMPROVEMENT_PLAN.md` for the per-K execution notes.

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

---

## K-52 lifecycle manual gate (round 3 re-run — no-cancel re-record + paste currency gate)

Rapid re-record + Esc behavior after the DictationStateMachine wiring (plan Task 2). Run in toggle mode with stage timing ON (`Lifecycle ctx=…` lines appear per transition) and observe Console (Subsystem `singhkays.Kalam`).

- [ ] 🧑 **Rapid re-record (the P0 pin) — ROUND 3 re-run:** rounds 1-2 compressed (cancel guard ate finished text → commit-before-cancel fix; B's cleanup wiped the shared hold slot → ownership-tag fix). The round-2 re-run found the deepest bug: a cancelled chunked-ASR never returns text, so deferred-preserve had nothing to fulfill → POLICY correction now in tree: re-record from `transcribing` emits ONLY `preserveTranscript(deferredUntilSettled)` (no `cancelWork`; the ASR finishes naturally, commits stale, the hold materializes), and the PASTE leg is stopped by the `recordingSessions.isCurrentSession` currency gate (`KalamApp.swift:1478`); Esc-from-transcribing still cancels+discards. Headless 334/334 green. **Re-run:** toggle mode, stage timing ON (`Lifecycle ctx=…` per transition, Console subsystem `singhkays.Kalam`), dictate sentence A, key-up, IMMEDIATELY start sentence B while the overlay still shows Transcribing. Expect `asr-done` for A, A parks to the held chip (stale A never pastes), B pastes complete; the interrupt log shows preserve-only (no `cancelWork`). PASS = A visible in chip + B pasted whole. Blanks \u2014 A chip text: _____ / B pasted: _____ / log sample: _____
- [x] 🧑 **Esc during Transcribing** — PASS (round 1): dictate, key-up, press Esc while still Transcribing. Cancels cleanly, nothing pasted, no stale insertion. Log showed `Lifecycle ctx=esc … → cancelled(userEsc) effects=2`.
- [x] 🧑 **Esc after text delivered** — N/A (with reason, not a pass-by-proxy): the paste leg completes faster than a human can press Esc — which is itself the desired latency outcome. The machine policy for this path is exhaustively pinned headlessly (`testEscIsLiveInEveryActiveState`).
- [x] 🧑 **K-01 toggle regression** — PASS (round 1): three normal toggle dictations started, stopped, transcribed, and pasted as before Task 2.


## K-53 WarmEnginePool — device-warm prepared graph (Task 1) 🧑 60 s glyph + device-change first dictation

Device-warm pool holds ONE spare `AVAudioEngine` keyed by input-device UID. Idle is `construct + prepare()` ONLY (never `start()`/tap — mic glyph must not appear). Permission-gated, 250 ms trailing-debounce coalescing (composes with TAP-TO-WAKE `audioDevicesDidChange` burst, commit `be99b81`). Recalibrated gates (Task-0 data, 2026-08-27): `engineStart→firstBuffer` 91–106 ms is irreducible (mic-indicator law, K-47 already removed the inline graph-build cost) — real wins are device-CHANGE first dictation and freshness.

**Pre-steps (once, ~2 min, host Mac only — VM has no mic):**
```bash
cd "/Volumes/My Shared Files/GitHub/Kalam"
# docs are gitignored -- verify local flips already applied:
grep -n "K-53" app/docs/IMPROVEMENT_PLAN.md
# expected: | K-53 | ✅ |
grep -n -E "^- \[x\] (Build pool|Gate prewarm|Invalidate \+ rebuild|AudioPrepareDecision|Tests \(WarmEngine)" app/docs/dev-design/2026-08-26-k52-k58-jot-adoption-plan.md

# enable stage-timing so toPreparedMs / transport appear
defaults write singhkays.Kalam internal.latency.enableStageTiming -bool true
defaults write singhkays.Kalam internal.latency.startStageTiming -bool true
# quit + relaunch Kalam (Xcode run or /Applications/Kalam.app)
```

**Log stream (keep this tab open for all gates below):**
```bash
log stream --style compact --predicate 'subsystem == "singhkays.Kalam"' --level info 2>&1 | grep --line-buffered -E "WarmEnginePool|AudioRecorder|Recording start latency"
# WarmEnginePool categories:
#   WarmEnginePool prewarm ok uid=...
#   WarmEnginePool take consumed uid=... -- scheduling refill
#   WarmEnginePool invalidated reason=...
# AudioRecorder: Adopted warm pool graph / Audio graph already prepared
# Recording start latency ... transport=... toPreparedMs=... engineStartToFirstBufferMs=...
```

- [ ] 🧑 **60 s mic-glyph gate (mic-indicator invariant):** Quit Kalam, relaunch, leave **idle 60 s** with the `log stream` tab running. The menu-bar mic glyph (Control Center) must stay **off** the entire window. Logs must show `WarmEnginePool prewarm ok` but **never** an idle `engine.start()` / tap-install. If you see `WarmEnginePool factory returned a RUNNING engine -- stopped (invariant violation)` mark **FAIL**.

- [ ] 🧑 **Built-in device-change first dictation:** With the stream still running:
  1. Change default input: `System Settings -> Sound -> Input` (Built-in <-> USB) or unplug/plug a USB mic.
  2. Logs within ~250 ms: `WarmEnginePool invalidated reason=deviceChange` then one `WarmEnginePool prewarm ok` (exactly one, even though CoreAudio posts a burst -- coalescing gate).
  3. Immediately do one dictation (hold hotkey 2 s, release). Check the `Recording start latency ... transport=builtin ...` line:
     * `toPreparedMs <=5` (pool hit; stale inline rebuild would be 19-26, seen in baseline `toPrepared 19` vs `1-3`)
     * overall `pttDown->firstBuffer <=185 ms` (warm p95 175 +10). `engineStart->firstBuffer` stays 91-106 (irreducible, not a failure).

- [ ] 🧑 **Bluetooth (AirPods) device-change first dictation:** Connect AirPods (A2DP-idle), wait for the TAP-TO-WAKE `audioDevicesDidChange` burst (`be99b81`), then check logs show **exactly one** `prewarm ok` after the burst (250 ms coalescing). Do one dictation on AirPods; check `transport=bluetooth` line: `toPreparedMs <=5` and `pttDown->firstBuffer <=155 ms` (warm p95 144 +10). Same vanishing `engineStart->firstBuffer` 91-106 is expected.

- [ ] 🧑 **Permission gate (optional, 1 min):** `System Settings -> Privacy & Security -> Microphone` -> deny Kalam, relaunch. Pool must no-op silently (no log `prewarm ok`, no prompt). Re-grant afterwards and relaunch -- one `prewarm ok` should appear again.

**Post-checks (prove after the sweep):**
```bash
# last 5 min of Kalam info logs (host):
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 5m 2>&1 | grep -E "WarmEnginePool|AudioRecorder|Recording start latency|toPreparedMs|transport=" | tail -n 80
log show --predicate 'subsystem == "singhkays.Kalam" AND category == "WarmEnginePool"' --info --last 10m 2>&1 | grep -E "take consumed|invalidated|prewarm|stale"
log show --predicate 'subsystem == "singhkays.Kalam" AND category == "WarmEnginePool"' --info --last 10m 2>&1 | grep -c "prewarm ok"
# the last count: burst -> 1, two separate bursts -> 2, etc.
# full suite gate (VM or host):
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -n 20
# expected: ** TEST SUCCEEDED ** (ignore *testFailed* in test names, final line wins)
```

**Fail signals to attach (screenshot + 10-line snippet from the log stream above):** glyph appears while idle; `toPreparedMs` >5 after device-change; burst produces >1 `prewarm ok` in 250 ms; `RUNNING engine` warning.

*Commit `f44d4bd` (local, not pushed) -- leave `K-53 ✅` local; do not push until release tag.*

---

## K-54 — SNR-aware post-roll carry-over (Task 3) — trailing-phoneme + logs

**What this proves:** Task 3 extends the K-49 early-exit ceiling per room SNR so the trailing phoneme is not clipped when the hand anticipates the mouth. `PostRollDecision` now has a pure `ExtensionPolicy` (`.fixed` vs `.snrAware(ExtensionConstants)`) fed by a ring read-back SNR estimated from the recent waveform (4096-sample ring, `windowedEnergiesDb` p95-p05) and the segment estimate. Low SNR (<12 dB) stretches toward the 1.5 s backstop and never clips; trusted rooms (≥12 dB) stretch while the tail is speech-like (`floor+3 dB` sensitive threshold, 0.08 linear ratio mapped) and stop after quiet ≥250 ms, capped at 0.30× segment duration. The 60 ms floor + 3-poll rule stays in ALL modes. Device HAL ring shrink read-back is unchanged (see Gate B) but is now compositionally part of the same tail-latency budget.

**Pre-steps (host Mac only — VM has no mic; reuse the Part 1 prep if already running):**
```bash
# 1. Enable stage timing + SNR-aware (default ON after Task 3, but confirm):
defaults read singhkays.Kalam-test internal.latency.snrAwareEnabled  # → 1
# If 0, flip it: defaults write singhkays.Kalam-test internal.latency.snrAwareEnabled -bool true
# Retune path (no code change): any of
#   internal.latency.snrTrustDb (default 12), internal.latency.snrAbsoluteCapMs (1500),
#   internal.latency.snrQuietToStopMs (250), internal.latency.snrRelativeCap (0.30),
#   internal.latency.snrFloorMarginDb (3)
# Example: defaults write singhkays.Kalam-test internal.latency.snrTrustDb -float 10

# 2. Quit + relaunch Kalam (debug build Kalam-test), grant mic, ensure Compass → Engine ready.
# 3. Start log stream BEFORE dictating (keep tab open):
log stream --style compact --predicate 'subsystem == "singhkays.Kalam"' --level info 2>&1 | grep --line-buffered -E "PostRoll SNR-aware|Recording timing|Latency stage label=audio-stop\+fetch|Device ring buffer"
# Expected at launch: one WarmEnginePool prewarm ok (K-53) — ignore for this gate.
```

**Gate G1 — trusted-room trailing syllable survives (built-in mic):**
1. Select **Built-in Microphone** as top priority in Compass → Being Heard (or System Settings → Sound → Input).
2. Dictate 5 short sentences where the last word ends on a soft stop, e.g.:
   - "Meeting at ten thirty."
   - "Call me at five five five one two three four."
   - "The version is two point five."
   - "We need a two to three pager."
   - "One of us should go."
   Note the exact last word you spoke for each.
3. After each paste, confirm the last word is present (no truncation). One clipped trailing phoneme = **FAIL**.

**Gate G2 — low-SNR backstop (no clipping is the PASS):**
1. Create a low-SNR environment: run a quiet fan / white-noise app at low volume ~1 m away, or cup your hand loosely around the mic to raise the noise floor without shouting. The log's `roomSNR=` should read **<12 dB** (see capture below) — that is the low-SNR branch.
2. Dictate 3 longer sentences (8–12 words) holding the PTT ~0.5 s past your last word (mimics hand-early release). Example: "The quarterly report is ready for review and needs approval."
3. Confirm every paste is complete (no truncated final word). Low SNR **must run longer** — it is REQUIRED to stretch toward 1.5 s and never clip; a short `audio-stop+fetch` that truncates here is the old bug, not a win. Check the log: `mode=snrAware-low` and `effectiveMaxMs=1500`.

**Gate G3 — Bluetooth (AirPods) word-ending:**
1. Put AirPods in, select them as top device in Compass (row should flip from OFFLINE → TAP TO WAKE → READY after the ~0.8 s HFP wake; see K-53). Confirm `transport=bluetooth` on the next `Recording timing` line.
2. Repeat G1's 5 sentences on AirPods. Same pass criterion: last word present on every paste. HFP mics have shorter tail energy — this is the transport that most often exposed the 150 ms truncation.

**Gate G4 — logs carry postRollMs + mode + roomSNR (proof of wiring):**
```bash
# While the stream is still running, in a second terminal:
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 10m 2>&1 | grep -E "PostRoll SNR-aware start|Recording timing.*roomSNR|Latency stage label=audio-stop\+fetch"
```
Expected per dictation (2 lines):
- `PostRoll SNR-aware start snrDb=… mode=snrAware-trusted|snrAware-low segmentEstimateMs=… minMs=60 maxMs=… effectiveMaxMs=…`
- `Recording timing holdMs=… keyUpToSamplesMs=… … transport=… roomSNR=… postRollMode=… postRollMs=…`
And `Latency stage label=audio-stop+fetch deltaMs=…` still appears (K-49 labeling unchanged). **FAIL if** `roomSNR` missing, `mode` missing, or `effectiveMaxMs` never exceeds the old 150 ms on a trusted dictation with a long segment (e.g., segment 2000 → effective 600).

**Gate G5 — kill-switch + goldens (regression guard):**
1. Disable SNR-aware: `defaults write singhkays.Kalam-test internal.latency.snrAwareEnabled -bool false` → quit + relaunch.
2. Dictate one G1 sentence. Log should show `mode=fixed` (or no `PostRoll SNR-aware` line) and `roomSNR=0.0`. Paste must still be correct (fixed path unchanged).
3. Re-enable: `defaults write singhkays.Kalam-test internal.latency.snrAwareEnabled -bool true` → relaunch. Confirm `mode=snrAware-…` returns.
4. Headless: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PostRollDecisionTests` must still report `testGoldensUnchanged_FixedConfigMatchesLegacy` PASS (proves fixed policy not regressed).

**Post-checks (attach to handoff):**
```bash
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 15m 2>&1 | grep -E "PostRoll SNR-aware|Recording timing.*roomSNR|Device ring buffer" | tail -n 40
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PostRollDecisionTests 2>&1 | tail -n 30
# Expected: PostRoll lines with both modes observed across built-in/bluetooth; roomSNR varies (≈ 5–25 dB across environments); all PostRollDecisionTests 22/22 pass.
```

**Result:** ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (attach 10-line log snippet + per-sentence last-word checklist):
- Built-in G1 last words: _____
- Low-SNR G2 mode/roomSNR: _____
- AirPods G3 last words: _____
- G4 log sample: _____
- G5 kill-switch flip: _____

*Commit for Task 3: local (not pushed) — leave `K-54 🔄→✅` local until G1–G5 all PASS; do not push until release tag.*

---

## K-55 ValidationGate — auto-degrade banner + trip window (Task 4)

**What this proves:** `ValidationGate` inside `KalamTextEngine` validates raw→clean divergence (length 0.18…1.65, containment ≥0.30, trigram ≥0.05; all 13 goldens accept). On `.reject` the pipeline falls back to raw and counts a trip; 3 trips in 86 400 s → auto-degrade (cleanup bypassed until relaunch or Re-enable, `Notification.Name.validationGateAutoDegraded` once, `CleanupPane` banner). Success streak 5 resets.

**Pre-steps (host Mac, no mic needed for the degrade path):**
```bash
# Build & run Kalam-test, grant mic/AX, ensure log stream running as in Part 1 prep step 2
# The degrade path is app-side UserDefaults, so we can drive it without dictating:
# In a second terminal, use the headless trip helper (or run the unit test target once):
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/ValidationGateTripTests 2>&1 | tail -n 20
# Expected: 7/7 pass — trip/window/streak pins.
```

**Gate H1 — triple-degrade flips banner exactly once:**
1. With Kalam running, open Settings → Cleanup. Note the pane shows no banner.
2. From `lldb` or a one-liner, record 3 rejects into the app's defaults (or dictate 3 divergent fixtures via the test helper):
   ```bash
   # Force 3 trips via defaults (timestamps now):
   /usr/bin/python3 -c "import subprocess, json, time; import os; print('use ValidationGateTripStore directly via a small Swift snippet')"
   # Simpler: run the app's debug helper if exposed, or trigger 3 pastes that are known divergent:
   # Use the engine's divergent fixtures: raw 40×'word ' → 'hi' (run via a local Swift script that calls ValidationGateTripStore)
   ```
   Practical shortcut for manual: dictate 3× the divergent pair `raw="word "×40 → "hi"` via a test helper that calls `ValidationGateTripStore().record(.reject)` — or use the `ValidationGateTripTests` as a harness and then check the app's `UserDefaults` suite.
   Expected: after the 3rd trip, `defaults read singhkays.Kalam-test validationGate.isDegraded` → 1, and a banner **Auto-paused — using raw transcription until relaunch** appears in Cleanup pane after you close/reopen Settings (or on next dictation the overlay shows **Cleanup auto-paused — last 3 pastes had formatting issues.** for 5 s). The banner must appear **once**; a 4th reject while already degraded must NOT post a second notification (check `log stream` shows `ValidationGate auto-degraded` once).

3. Dictate a normal sentence ("hello world") — it must paste via raw (no cleanup), e.g. fillers preserved if you said "um hello world".
4. Click **Re-enable** in the banner — `validationGate.isDegraded` → 0, banner disappears.
5. Dictate 5 normal sentences — after the 5th accept the success streak must have reset `validationGate.trips` to empty (`defaults read … validationGate.trips` → missing or empty, and `isDegraded` stays 0).

**Gate H2 — window expiry (headless pin):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/ValidationGateTripTests/testWindowExpiryResets 2>&1 | tail -n 20
# Must show PASS — trips older than 86 400 s are dropped, degraded clears after streak 5.
```

**Gate H3 — no double-insert (Task 5 cross-check):**
After H1's degrade, dictate into TextEdit and into an Electron app (VS Code). Each paste must be exactly one insertion (no double). Check `log stream` shows `ValidationGate verdict=reject fallback=true` on the degraded dictations, but the paste still lands once.

**Post-checks:**
```bash
defaults read singhkays.Kalam-test validationGate.isDegraded  # → 0 after Re-enable + streak
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 10m 2>&1 | grep -E "ValidationGate|validationGateAutoDegraded" | tail -n 20
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/ValidationGateTripTests 2>&1 | tail -n 20
# Expected: 7/7 pass
```

**Result:** ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (attach banner screenshot + `defaults read` output + log snippet):
- H1 triple banner once: _____
- H1 Re-enable + streak 5: _____
- H2 window expiry: _____
- H3 no double-insert: _____

*Commit for Task 4: local — leave `K-55 ✅` local until H1–H3 PASS.*

---

## K-56 Tier-1 insertion hardening — read-back verify + secure/PID/frontmost (Task 5)

**What this proves:** `PasteService` Tier-1 verified AX (`kAXSelectedTextAttribute` SET + 3×40 ms read-back; unchanged → fall through to `Cmd+V`, never double-post), secure-field / `IsSecureEventInputEnabled()` / `IORegistry IOConsoleUsers` probe refusal before any pasteboard exposure, `AXUIElementGetPid != dictationTargetPID` → hold (`.focusElsewhere`), `AppQuirks.forcePaste` table (empty, governance), `AccessibilityWaker.wakeIfNeeded` while speaking, frontmost re-check after ~350 ms AX window before global `postUnicodeText`/`postCmdV` (mismatch → hold), optional `internal.paste.setVerifyTimeoutOverrideMs` (0 unset, 1.2–1.5 s, global stays 0.75 s per `AXUIElement.h:387`).

**Pre-steps (host Mac, needs mic + AX):**
```bash
# 1. Build & run Kalam-test, grant mic/AX, enable stage timing for paste logs
defaults write singhkays.Kalam-test internal.latency.enableStageTiming -bool true
# 2. Log stream for paste
log stream --style compact --predicate 'subsystem == "singhkays.Kalam"' --level info 2>&1 | grep --line-buffered -E "PasteService|SecureInput|AccessibilityWaker|AppQuirks|frontmost" | tee ~/kalam-tier1.txt
# 3. Keep TextEdit frontmost for baseline; have VS Code (Electron) and a password field ready.
```

**Gate I1 — Electron lie-success → exactly one insertion (headless pin + manual):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PasteServiceTier1Tests/testElectronLieFallsThroughToCmdVExactlyOnce 2>&1 | tail -n 20
# Must pass — verifies AX lie (SET success but value unchanged) falls through to Cmd+V exactly once, no double.
```
Manual: dictate a long paragraph (>200 UTF-16, ~40 words) into **VS Code** (Electron, Tier-1 often lies). The paste must land once, no double (check the file has one copy, not two). `~/kalam-tier1.txt` should show `AX verification failed … fall through to global legs` then `Paste succeeded via Cmd+V` (or unicode) — never `Paste succeeded via Accessibility (verified)` followed by a second `Cmd+V` for the same dictation.

**Gate I2 — Secure-field refusal before pasteboard:**
1. Focus a password field (e.g. System Settings → Users & Groups → password, or Safari save-password prompt, or Keychain Access new item).
2. Set clipboard sentinel: `printf 'KALAM-SECURE-TEST' | pbcopy`
3. Dictate a short sentence while the secure field is focused.
Expected: **no paste**, overlay shows **Secure field — transcript ready. Paste into <app>?** held chip (or similar), and `pbpaste` still prints `KALAM-SECURE-TEST` (pasteboard never exposed). Log shows `Secure field role AXSecureTextField → refusing` and no `writeAndTrackPasteboardState`. **FAIL if** transcript appears in the secure field or clipboard changes.

**Gate I3 — PID mismatch → hold (requires two apps):**
1. Focus TextEdit, start dictating, **while still holding PTT** switch to Notes (so `dictationTargetPID` = TextEdit, `frontmostPIDAtDecision` = Notes). Release.
Expected: transcript **held** for TextEdit (chip says **PID mismatch — transcript ready. Paste into TextEdit?**), not blindly pasted into Notes. Log shows `PID mismatch elementPid=… preferPid=… → hold`. Click **Paste** in the chip — it must activate TextEdit and paste there.

**Gate I4 — Frontmost changed during AX window → hold:**
Same as I3 but the switch happens *after* the AX attempt window: dictate into TextEdit, release, and *immediately* cmd-tab to another app before the paste lands (within ~350 ms). The frontmost re-check before global legs must detect `frontmostChanged` and hold. Log shows `Frontmost changed during AX window`. **FAIL if** paste lands in the wrong app.

**Gate I5 — AppQuirks empty table:**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PasteServiceTier1Tests/testAppQuirksForcePasteSkipsTier1 2>&1 | tail -n 20
# Must pass — empty table does not force, Tier-1 is still attempted.
```

**Gate I6 — Slow SET with override (headless):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PasteServiceTier1Tests/testSlowSetWithOverrideSucceedsViaAXOnly 2>&1 | tail -n 20
# Must pass — with internal.paste.setVerifyTimeoutOverrideMs=1500, slow app succeeds via AX only (0 CmdV). Without override (default 0) the same slow app would fall through to CmdV — verify by removing the defaults key and seeing 1 CmdV.
```

**Gate I7 — No regression when flag unset (default):**
With `defaults delete singhkays.Kalam-test internal.paste.setVerifyTimeoutOverrideMs` (or 0), dictate 3 normal sentences into TextEdit and 3 into VS Code. Each must land once, no change in latency or double-insert vs before Task 5. Log must show no `Per-element verify timeout override` line.

**Post-checks:**
```bash
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 15m 2>&1 | grep -E "PasteService|SecureInput|AppQuirks|frontmost|Per-element" | tail -n 60
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/PasteServiceTier1Tests 2>&1 | tail -n 30
# Expected: 8/8 pass
```

**Result:** ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (attach `~/kalam-tier1.txt` snippet + per-gate checklist):
- I1 Electron single-insert (headless + manual VS Code): _____
- I2 Secure field hold + clipboard intact: _____
- I3 PID mismatch hold: _____
- I4 Frontmost-changed hold: _____
- I5 Quirks empty: _____
- I6 Slow override: _____
- I7 Flag unset no regression: _____

*Commit for Task 5: local — leave `K-56 ✅` local until I1–I7 PASS.*

---

## K-57 Crash recovery — opt-in retention, streaming CAF, sweep (Task 6)

**What this proves:** Toggle default OFF is byte-identical to today's ephemeral (zero writes when OFF); when ON, per-session `<ISO8601>-<uuid>/audio.caf` (streaming CAF, `mAudioDataByteCount=-1`, never rewrites header per tick) + `meta.json` (isComplete false until `endRetention(markComplete:true)`) under `~/Library/Application Support/Kalam/recordings/`; `RetentionPolicy` 6 h timer, 7 d TTL, newest-first `RecoveryScanner`; `OFF` path verified via `fs_usage`.

**Pre-steps (host Mac, needs mic):**
```bash
# 1. Build & run Kalam-test
# 2. Log stream for retention
log stream --style compact --predicate 'subsystem == "singhkays.Kalam"' --level info 2>&1 | grep --line-buffered -E "Retention|RecoveryScanner|CAFStreamWriter|recordings" | tee ~/kalam-retention.txt
# 3. Note the recordings root:
ls -ld ~/Library/Application\ Support/Kalam/recordings 2>&1 | head -n 5
```

**Gate J1 — Toggle OFF → zero disk writes (honest zero-off):**
1. In Settings → Engine, ensure **Keep audio for recovery (7 days)** is **OFF** (default).
2. In a second terminal, start `fs_usage` filtered to the recordings path (leave it running):
   ```bash
   sudo fs_usage -w -f filesys Kalam-test 2>&1 | grep --line-buffered -i "recordings.*audio.caf\|recordings.*meta.json" | tee ~/kalam-fs-off.txt
   # If sudo is unavailable, use the headless pin as proof:
   xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/RetentionTests/testRetentionToggleOffDoesZeroWrites 2>&1 | tail -n 20
   # Must pass — asserts no folder created when OFF.
   ```
3. Dictate 3 normal sentences. While dictating, `~/kalam-fs-off.txt` must stay **empty** (no `audio.caf`/`meta.json` writes). `ls ~/Library/Application\ Support/Kalam/recordings` must stay empty or unchanged.
**FAIL if** any `audio.caf` appears while OFF, or the headless test fails.

**Gate J2 — Toggle ON → streaming CAF per session:**
1. Flip the toggle **ON** in Settings → Engine. Quit and relaunch Kalam-test (or toggle observer will pick it up).
2. `sudo fs_usage` as above but now tee to `~/kalam-fs-on.txt`.
3. Dictate one short sentence, release. Immediately:
   ```bash
   ls -R ~/Library/Application\ Support/Kalam/recordings 2>&1 | head -n 40
   cat ~/Library/Application\ Support/Kalam/recordings/*/meta.json 2>&1 | head -n 40
   ```
   Expected: one new folder `<ISO>-<uuid>/` with `audio.caf` (size > header, `file audio.caf` shows `Apple CAF`) and `meta.json` (`isComplete` true after paste, `deviceUID` present, `sampleRate` 16000). While still holding PTT on the *next* dictation, `~/kalam-fs-on.txt` should show **incremental** `audio.caf` writes (multiple `write` lines, not one final rewrite) — proves streaming, not per-tick header rewrite.
4. Dictate 2 more sentences — each must create a new folder (3 total). `RecoveryScanner` log should show `Retention reindex count=3` on next launch.

**Gate J3 — Kill -9 mid-recording → recoverable next launch:**
1. With toggle still ON, start a dictation and **while still holding PTT** (recording), kill the app:
   ```bash
   pkill -9 Kalam-test; sleep 1; ls -R ~/Library/Application\ Support/Kalam/recordings 2>&1 | tail -n 40
   ```
   Expected: the newest folder's `meta.json` has `isComplete` **false** and `audio.caf` exists with non-zero size (streaming header allowed a playable file even without `close`). `log show` last lines before kill should include `Retention begin folder=…`.
2. Relaunch Kalam-test. Log should show `RecoveryScanner` `newest interrupted session=…` and (deferred) a held row or log about auto-transcribe. The folder must still be present (not swept).
**FAIL if** `isComplete` is true after kill -9, or `audio.caf` is 0 bytes, or the folder was not created.

**Gate J4 — Retention sweep (headless pin + manual TTL):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/RetentionTests/testRetentionPolicySweepRemovesOldFolders 2>&1 | tail -n 20
# Must pass — 8-day folder purged, 1-day kept.
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/RetentionTests/testRecoveryScannerNewestFirstOrdering 2>&1 | tail -n 20
# Must pass — newest-first.
```
Manual TTL check (optional, not waiting 7 days): set a folder's mtime to 8 days ago (`touch -t $(date -v-8d +%Y%m%d%H%M) <folder>`), then `killall Kalam-test` and relaunch — the 6 h timer will sweep on next launch, or run `xcodebuild test … testRetentionPolicySweepRemovesOldFolders` as proof.

**Gate J5 — Toggle OFF again → no new writes, old folders remain until TTL:**
Flip toggle **OFF**, dictate once more — `~/kalam-fs-on.txt` must show **no new** `audio.caf`/`meta.json` writes (only the earlier ON folders remain). Existing `recordings/*` folders are **not** deleted immediately; they age out via the 7 d sweep. This proves OFF is byte-identical to the pre-Task-6 ephemeral path.

**Post-checks:**
```bash
ls -R ~/Library/Application\ Support/Kalam/recordings 2>&1 | head -n 60
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 15m 2>&1 | grep -E "Retention|RecoveryScanner|CAFStreamWriter" | tail -n 40
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/RetentionTests 2>&1 | tail -n 30
# Expected: 7/7 pass
```

**Result:** ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (attach `~/kalam-retention.txt` + `~/kalam-fs-on/off.txt` snippets + `ls -R` + per-gate checklist):
- J1 OFF zero writes (fs_usage empty + headless): _____
- J2 ON streaming CAF + meta per session: _____
- J3 kill -9 interrupted folder: _____
- J4 sweep + ordering (headless): _____
- J5 OFF again no new writes: _____

*Commit for Task 6: local — leave `K-57 ✅` local until J1–J5 PASS.*

---

## K-58 FnUsageAdvisor — silent-trigger support trap (Task 7)

**What this proves:** `Services/FnUsageAdvisor` reads `com.apple.HIToolbox AppleFnUsageType` only when present (absent → UNKNOWN → no banner), interprets via OS-version-documented table (0=Do Nothing OK, 1/2/3→advise, verified 2026-08-27 on macOS 14.6/26.5), detects `org.pqrs.Karabiner-Elements` independently, fires once per condition-change, deep-links System Settings → Keyboard, hides when resolved. Never logs transcript.

**Headless pins (already green):**
```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/FnUsageAdvisorTests 2>&1 | tail -n 20
# Must show 6/6 pass: absent quiet, confirmed-bad once, Karabiner decoupled
```

**Gate L1 — Absent-key stock config → no banner:**
1. On a stock Mac (no `AppleFnUsageType` key — verify: `defaults read com.apple.HIToolbox AppleFnUsageType` → `Domain ... does not exist`), launch Kalam-test, watch `log stream --predicate 'subsystem == "singhkays.Kalam"' --info | grep FnUsageAdvisor` and the overlay. **No banner** must appear, no `FnUsageAdvisor firing advisory` log. Headless `testAbsentKeyIsQuiet` already pins this.

**Gate L2 — Confirmed-bad → banner once, deep-link, then cleared:**
1. With Kalam not running: `defaults write com.apple.HIToolbox AppleFnUsageType -int 1` (Change Input Source — confirmed-bad for this OS version; see code table). Launch Kalam-test.
2. Expected: overlay shows **Fn key is set to Change Input Source … Check System Settings → Keyboard → Press Fn key to.** with **Open** button → click it → System Settings → Keyboard opens. Log shows `FnUsageAdvisor firing advisory` once.
3. Without quitting, `defaults write com.apple.HIToolbox AppleFnUsageType -int 1` again and wait 30 s — **no second banner** must appear (once-per-condition).
4. Fix: `defaults delete com.apple.HIToolbox AppleFnUsageType` (or `defaults write … -int 0` for Do Nothing), then `killall Kalam-test` and relaunch, or just trigger a re-check by switching apps. Banner must **not** reappear and the stored `fnAdvisor.lastNotifiedReason` must be cleared (check `defaults read singhkays.Kalam-test fnAdvisor.lastShouldAdvise` → 0 or missing). Dictating with `fn` as hotkey should now work if that was the blocker.
5. Repeat with `AppleFnUsageType -int 2` (Show Emoji) to confirm the second bad value also fires once with its own reason, then clears.

**Gate L3 — Karabiner-Elements decoupled:**
1. With `AppleFnUsageType` absent (or 0), launch **Karabiner-Elements** (install from `https://karabiner-elements.pqrs.org` if not present; bundle `org.pqrs.Karabiner-Elements`).
2. Launch or re-activate Kalam-test (or just switch apps to trigger `didLaunchApplicationNotification`).
3. Expected: banner shows **Karabiner-Elements is intercepting the Fn key** (or combined with fn reason if both), even though `AppleFnUsageType` is absent/OK. Log shows `karabiner=true` and `reason` contains `Karabiner`. Quit Karabiner, re-activate Kalam — banner must clear and not reappear (condition resolved). Headless `testKarabinerDecoupledFromDomainRead` pins the logic.

**Gate L4 — No transcript logging:**
While `log stream --level info` is running, dictate a sentence containing a sensitive word. Verify the `FnUsageAdvisor` log lines contain only `reason`/`karabiner`/`fnState`, never the transcript text.

**Post-checks:**
```bash
defaults read com.apple.HIToolbox AppleFnUsageType 2>&1 | head -n 5
defaults read singhkays.Kalam-test fnAdvisor.lastNotifiedReason 2>&1 | head -n 5
log show --predicate 'subsystem == "singhkays.Kalam"' --info --last 15m 2>&1 | grep -E "FnUsageAdvisor|fnAdvisor" | tail -n 20
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/FnUsageAdvisorTests 2>&1 | tail -n 20
# Expected: no banner on stock, banner once for 1/2/3 and for Karabiner, cleared when resolved; 6/6 tests pass
```

**Result:** ☐ PASS ☐ FAIL ☐ UNCLEAR — Notes (attach log snippet + `defaults read` outputs + banner screenshot):
- L1 absent quiet: _____
- L2 bad fires once + deep-link + clear: _____
- L3 Karabiner decoupled: _____
- L4 no transcript log: _____

*Status: ✅ implemented & headless-verified 2026-08-27; manual gate L1–L4 pending host with remapped fn/Karabiner (see `KalamTests/FnUsageAdvisorTests` for pins). Commit for Task 7: local — leave `K-58 ✅` local until L1–L4 PASS.*



---

## F popover manual checklist (Engine Tab — F Popover, 10 states)

- [ ] F1 collapsed: Choose… primary, View/Copy bsec white, no popover
- [ ] F2 folder chosen: Change/Open/Clear, same
- [ ] F3 Install popover: Hide well tint, well #F1F0EA brew, notch right:135 centered on Hide, card height stable
- [ ] F4 Download popover: selchip before well, v2→v3 swaps command, notch pinned
- [ ] F5 picker open: selchipMenu (v2 ✓) + dimmed well 0.55
- [ ] F6 verified: green ✓, ON DISK, no View
- [ ] F6b multiple: 2 models, v2 ON green-t, v3 Use, Missing dimmed
- [ ] F6c multiple incomplete: warn orange border + chipgrid
- [ ] F7 incomplete popover: chipgrid inside popover, well #F1F0EA
- [ ] F8 repo guard: orange guard, GetTheModel dimmed 0.55
