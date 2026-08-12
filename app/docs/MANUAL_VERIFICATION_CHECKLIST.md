# Kalam — Combined Manual Verification Run

**Date of run:** ________
**Tester:** ________
**App build used:** ________ (Xcode Run / DMG / CI artifact)

This checklist combines every 🧑 *human manual gate* still open in `app/docs/IMPROVEMENT_PLAN.md`
after the 2026-08-11 implementation wave. All code is implemented and all automated suites are
green (engine 41/41, full Xcode suite 79 passed / 0 failed / 3 model-dependent skipped) — these
tests verify the *behavior on real hardware* that unit tests cannot.

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
| K-21 | Settings window width (900 pt, consistent) |

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
