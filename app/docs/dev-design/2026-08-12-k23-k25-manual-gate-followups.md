# Dev plan — K-23 / K-24 / K-25: manual-gate follow-up fixes

**Date:** 2026-08-12
**Origin:** Combined manual verification run (`app/docs/MANUAL_VERIFICATION_CHECKLIST.md`) —
three findings surfaced by the run that need code fixes before their gates can close.

| ID | Severity | Finding | Fix shape |
|---|---|---|---|
| K-23 | Medium | Paste targets the **front-most app at paste time**; overlay shows the record-start target. Switching apps mid-transcription pastes into the wrong app. | **User chose "Both"**: capture target app + focused element at record start; paste into the captured element (AX insert, no pasteboard) when the frontmost app changed; if that insert fails, **hold** the transcript with an overlay "Paste" action instead of pasting into the wrong app. |
| K-24 | Medium | "Quit & Reopen Kalam" button unreachable — `confirmAccessibilityEnabled()` has no app-side caller. | Controller method `confirmAccessibilityEnabledIfAttempted()` called from `KalamApp.refreshOnboardingState` after `apply(snapshot:)`; transitions `.needsExternalEnable → .enabledPendingRelaunch` (or `.idle` when trusted). |
| K-25 | Low | Word Replacement header renders raw template — `"\\(..."` double backslash prints literal `\(`. | One-line: single backslash interpolation in `WordReplacementView.swift:59`. |

## K-25 — one-liner

`app/Kalam/Settings/WordReplacementView.swift:59`:
`Text("\\(manager.entries.count) rules • \\(activeRuleCount) active")`
→ `Text("\(manager.entries.count) rules • \(activeRuleCount) active")`

Verify: build; open Settings → Dictionary tab; header shows real counts.

## K-24 — make the relaunch path reachable

1. `OnboardingFlow.swift` — add after `confirmAccessibilityEnabled()`:
   ```swift
   /// K-24: called on every snapshot refresh. Once the user has attempted Accessibility
   /// setup (state == .needsExternalEnable), surface the relaunch path whenever the
   /// running process still isn't trusted — previously `.enabledPendingRelaunch` (and the
   /// "Quit & Reopen Kalam" button) was unreachable because nothing called this.
   func confirmAccessibilityEnabledIfAttempted() {
       guard accessibilitySetupState == .needsExternalEnable else { return }
       confirmAccessibilityEnabled()
   }
   ```
2. `KalamApp.swift` `refreshOnboardingState` — after `onboardingController?.apply(snapshot: snapshot)`:
   ```swift
   onboardingController?.confirmAccessibilityEnabledIfAttempted()
   ```

Flow: Grant Access click → `.needsExternalEnable` (+ persisted `hasAttemptedAccessibilitySetup`) →
next refresh → untrusted → `.enabledPendingRelaunch` → **"Quit & Reopen Kalam"** (+ secondary
"Open System Settings"). If the user granted in System Settings meanwhile, refresh → snapshot
`.ready` → `apply` resets to `.idle` ("Granted"). No recursion risk: the call site is gated on
`accessibilitySetupState == .needsExternalEnable`, and `apply(snapshot:)` already resets state
to `.idle` when the snapshot is ready.

Tests (OnboardingFlowTests, controller-level, injected `accessibilityTrustCheck`):
- `testConfirmAccessibilityEnabledIfAttemptedTransitionsToPendingRelaunchWhenUntrusted`
- `testConfirmAccessibilityEnabledIfAttemptedGoesIdleWhenTrusted`
- `testConfirmAccessibilityEnabledIfAttemptedIsNoopWhenIdle`

Verify (live): onboarding → Grant Access → row shows "Quit & Reopen Kalam" → click →
app relaunches, exactly one process, onboarding reopens.

## K-23 — record-time target capture + guard

### PasteService.swift
1. Refactor the AX insert: extract the attribute-setting core into
   `static func insertTextViaAccessibility(into element: AXUIElement, text: String) -> String?`
   (existing `kAXSelectedTextAttribute` → `kAXValueAttribute` fallback body); the existing
   frontmost-resolving `insertTextViaAccessibility(_ text:)` delegates to it.
2. `PasteStrategies` gains:
   ```swift
   var insertTextIntoElement: (AXUIElement, String) -> String? =
       { PasteService.insertTextViaAccessibility(into: $0, text: $1) }
   ```
3. Routing (pure, headless-testable):
   ```swift
   enum PasteTarget: Equatable {
       case frontmost
       case capturedElement(AXUIElement)
   }
   enum PasteRouting {
       /// K-23: no capture, or the frontmost app is still the record-time target → frontmost.
       /// Different app → insert into the captured element (never the wrong app).
       static func target(capturedPID: pid_t?, capturedElement: AXUIElement?,
                          frontmostPID: pid_t?) -> PasteTarget {
           guard let capturedPID, let capturedElement, let frontmostPID,
                 capturedPID != frontmostPID else { return .frontmost }
           return .capturedElement(capturedElement)
       }
   }
   ```
4. `func paste(into element: AXUIElement, text: String) async throws` — AX-trust guard, then
   `strategies.insertTextIntoElement(element, text)`; throw `pasteExecutionFailed` on error.
   **No pasteboard involvement** — zero clipboard exposure on the switched-app path.

### KalamApp.swift
1. State: `private var dictationTargetPID: pid_t?`, `private var dictationTargetElement: AXUIElement?`,
   `private var heldTranscript: String?`.
2. `startRecording` (after the guards, near `overlay.showRecording`): resolve the focused
   element in the frontmost app via `AccessibilityFocusResolver.resolveFocusedElement(frontmostApp:)`;
   store pid + element; failure → nil (fall back to current behavior).
3. Paste dispatch (the `try await self.paster.paste(postProcessed)` site): route via
   `PasteRouting.target(capturedPID:frontmostPID:)`:
   - `.frontmost` → existing pipeline unchanged.
   - `.capturedElement(element)` → `try await self.paster.paste(into: element, text: postProcessed)`;
     on failure → `heldTranscript = postProcessed`, overlay error
     `"Transcript ready — paste into <frontmost name>?"` with `action: .pasteHeldTranscript`,
     `autoHideAfter: nil` (stays until acted on / next recording), log via `Logger`; return.
   - Clear capture + held transcript on success and on hold.
4. `pasteHeldTranscript()` — pastes `heldTranscript` into the **current** frontmost app via the
   existing `paster.paste` (explicit user intent via the overlay button); clears held state;
   success → `showSuccessAndAutoHide`, failure → error overlay.
5. `cancelRecording()` — clear capture + held transcript.
6. `applicationDidFinishLaunching` (next to `overlay.setWaveformProvider`):
   `overlay.setPasteHeldTranscriptAction { [weak self] in self?.pasteHeldTranscript() }`.

### DictationOverlayController.swift
- `OverlayAction` += `case pasteHeldTranscript`; `actionTitle` → `"Paste"`; `handle(action:)`
  dispatches to an injected `pasteHeldTranscriptAction` closure (overlay stays decoupled).
- `showError(_:action:autoHideAfter:)` → `autoHideAfter: TimeInterval? = nil` (nil = no auto-hide;
  existing call sites unchanged).

### Tests (PasteServiceTests)
- `testPasteIntoCapturedElementSucceedsWithoutTouchingPasteboard` (injected insert → nil;
  assert called with the captured element; named pasteboard empty after).
- `testPasteIntoCapturedElementThrowsOnInsertFailure`
- `testPasteIntoCapturedElementRequiresTrust` (insert NOT called)
- `testPasteRoutingNoCaptureFallsBackToFrontmost` / `testPasteRoutingSameAppUsesFrontmost` /
  `testPasteRoutingSwitchedAppTargetsCapturedElement` (pure pins; `AXUIElementCreateSystemWide()`).

## Verification
- `./scripts/test-engine.sh` green (41).
- `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` green.
- Live: K-24 (onboarding Grant Access → "Quit & Reopen Kalam" → relaunch, single process) and
  K-25 (Dictionary header counts) via desktop automation — no mic needed.
- 🧑 K-23 live gate (switch apps mid-dictation in each mode; transcript lands in record-time
  target or is held with the notice) requires a mic session — deferred to the user (K-10-style).

## Execution notes (2026-08-12)

- **K-24 ✅** — implemented as planned. Live verify (desktop automation, unsigned debug build):
  first-run onboarding → click "Grant Access" → Accessibility row shows **"Quit & Reopen Kalam"**
  (+ secondary "Open System Settings") → click → app quits and relaunches itself, **exactly one
  process**, onboarding reopens. The "AX trusted after relaunch" leg needs a real TCC grant
  (user action) and remains part of the K-12 gate.
- **K-25 ✅** — one-line interpolation fix. Live verify: Dictionary header renders "0 rules • 0 active".
- **K-23 code done, 🧑 gate pending** — all planned pieces landed: capture in `startRecording`,
  `PasteRouting` dispatch, `paste(into:element:text:)` (no pasteboard), held-transcript overlay
  with a "Paste" action, `cancelRecording` cleanup. 6 new `PasteServiceTests` + 3 K-24
  `OnboardingFlowTests` green; full Xcode suite 88 passed / 0 failed / 3 skipped; engine 41/41.
  The live gate (switch apps mid-dictation) needs a mic session — deferred to the user (K-10-style).
- Working tree: 9 files changed (4 app, 2 test, 2 docs + 1 new plan). Not committed (user's call).
