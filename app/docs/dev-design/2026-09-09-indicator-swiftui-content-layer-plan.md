# Recording Indicator → SwiftUI Content Layer — Implementation Plan

> **For the implementing agent:** implement this plan task-by-task; steps use checkbox syntax for tracking. Every task is a self-contained, independently revertible change. This document is a design contract — it deliberately contains no code fragments; the implementing agent chooses syntax, types not named here, and the rendering code.

**Goal:** Move the recording indicator's *content rendering* (machined deck / whisper pill / caret chip / waveform / timer / held & blocked interactivity) from hand-rolled AppKit views to SwiftUI, hosted in the existing AppKit windows. All non-visual machinery — window choreography, AX caret tracking, session rules, state machine, prewarm — stays AppKit and stays in `DictationOverlayController.swift`. No behavior, dimension, token, copy, or state-machine change.

**Design authority (verification truths — do not restyle from memory):**
- `app/docs/plans/kalam-indicator-v1/index.html` + `README.md` (canonical state matrix, fallback law, style-specific renders, timer/typography rules)
- `app/docs/plans/kalam-indicator-v1/contrast-remedy.html` (green-ring / rim interactive spec: 1px hairline, 6pt glow twin, brand green #52B788)
- `app/docs/plans/kalam-onboarding-v3.2/` (shared token ground truth for deck surfaces)
- `app/docs/plans/kalam-compass-1.7/kalam-compass-v1.7.html` (Being-heard pane: indicator picker + preview strip grammar)
- Live source being migrated: `app/Kalam/DictationOverlayController.swift` (1,962 lines)

---

## 1. Context

The app already runs a hybrid stack: AppKit windows owned by the app delegate, SwiftUI content hosted inside those windows via `NSHostingController` (`KalamApp.openSettingsWindow`, `showOnboardingWindow`). The onboarding deck file opens with both `import AppKit` and `import SwiftUI`. The recording indicator is the only surface whose *content* is still hand-rolled AppKit: `OverlayCapsuleView`, `WaveformView`, `PillLevelGlyphView`, and `CaretChipView` build their UI out of `NSTextField`/`NSButton`, `NSLayoutConstraint` plumbing, and CALayer chrome. That content layer is where the maintenance pain lands — git history shows repeated clip/shadow/ring fixes ("square halo", "hard square behind pill", "no rotation ring"). This plan moves that content layer to SwiftUI without rewriting the parts that genuinely must stay AppKit.

## 2. Goals and Non-Goals

**Goals**

- SwiftUI hosted surfaces: machined deck, whisper pill, caret chip — same states, same pixels as the mockups and the current build.
- Identical session contract: style / dark-appearance / reduce-motion captured once per `showRecording`, applied for the whole session.
- Strictly less AppKit content code; window shell, session rules, AX caret work, and prewarm untouched.
- Pure, unit-testable extraction of the audio envelope math (waveform + level glyph) out of the views.
- A parity phase where old and new content coexist behind a DEBUG toggle; the parity checklist is the acceptance gate before cutover.
- Zero behavior, state-machine, token, copy, or dimension deltas.

**Non-Goals**

- Rewriting the window layer: placement math, alpha fades, shadow rules, `ignoresMouseEvents` handoff, caret AX work all stay AppKit.
- Changing states, fallback law, interactions, dimensions, colors, timer format, or the post-recording flow.
- Introducing a `WindowGroup` scene or migrating window management into SwiftUI.
- Removing AppKit from the file entirely (window shell remains).

## 3. Architecture Decisions (locked)

1. **The hybrid split is the product pattern.** SwiftUI-in-AppKit-window is already how settings and onboarding ship. The indicator adopts the same shape: AppKit window shell + SwiftUI content host.
2. **Hosting.** Each of the two overlay windows (main capsule window, caret chip window) replaces its `contentView` with a SwiftUI hosting view exactly once (build time / prewarm); after that the window is never rebuilt. Window properties stay as shipped today (borderless, clear background, popUpMenu-level +2, join-all-spaces + full-screen auxiliary, `hasShadow`), preserving the corner shadow behavior.
3. **State flow is one-way.** The controller keeps its private state enum and all transition logic. On each transition it publishes an immutable presentation value (view model) through a small observable holder the SwiftUI roots read. SwiftUI never writes back; every callback (Paste, Discard, Open Settings) is an action closure injected by the controller, exactly like today.
4. **Pure math extraction.** Envelope/AGC/smoothing (waveform) and the three-bar level-glyph math move to framework-free shared helpers, unit-testable without views. Both the AppKit parity build and the SwiftUI build consume identical numbers. This lands as its own no-visual-change phase **before** any SwiftUI surface exists.
5. **Tokens consolidate once.** Geometry, colors, typography currently scattered through the content-view metrics enums consolidate into one indicator tokens source (values unchanged; ramps and palette identical). SwiftUI surfaces and the settings preview strip read the same tokens.
6. **Parity A/B.** While both content paths exist, the controller serves whichever the DEBUG flag selects. The SwiftUI path becomes the default only after the parity checklist (section 10) passes; the AppKit view classes are removed only after the flag ships as SwiftUI-only.

## 4. State Model and Session Rules (unchanged contract)

The implementing agent must preserve these behaviors verbatim:

- Five canonical states: listening / pausing / transcribing / held / blocked.
- **Fallback law:** held and blocked always render on the full machined deck regardless of selected style; whisper falls back to the deck for those two states; the caret chip falls back to the deck whenever no caret rect resolves at record start or on the 2Hz tick; pausing never changes the capsule surface size.
- **Session capture:** style, dark appearance, and reduce-motion are read exactly once per `showRecording` and drive every visual rule for the session; mid-flight style changes apply at the next session, never mid-session.
- **Copy rules:** the pinned message strings, button titles, and punctuation are unchanged; no em dashes, no mid-dot compounds.
- **Dimensions:** machined deck width, compact pill widths (listening/pausing vs transcribing), chip width, all metrics, and the window size-transition pattern (full deck <-> compact) stay exactly as today; the controller sizes and repositions the window, not SwiftUI.
- **Timer:** SF Mono tabular digits, update cadence unchanged.

## 5. File Structure

**Create (all under `app/Kalam/`; folder-synchronized groups mean new files auto-join the target — no pbxproj edits):**

1. `IndicatorTokens.swift` — consolidated indicator geometry, color, and typography constants; the single source both SwiftUI surfaces and the settings strip read. Values equal today's; no new properties.
2. `IndicatorWaveformMath.swift` — framework-free envelope/AGC/smoothing and the three-bar level-glyph normalization, deterministic and unit-testable.
3. `IndicatorPresentationState.swift` — the observable holder the controller publishes per transition; carries presentation fields, session flags, the current sample backlog, and the elapsed-time string. No AppKit/SwiftUI imports.
4. `IndicatorSurfaces.swift` — the SwiftUI views: machined deck surface, whisper pill surface, caret chip surface, plus shared stadium/pill/chip chrome modifiers (surface fill, hairline ring + glow, shimmer, waveform slot).
5. `IndicatorWaveformView.swift` — the SwiftUI waveform renderer driven by the pure math.

**Modify:**

- `app/Kalam/DictationOverlayController.swift` — the AppKit content views are replaced by a hosted SwiftUI root in each window; the published state is filled at every transition; both paths coexist under the parity flag until cutover.
- `app/Kalam/IndicatorStateModel.swift` — only if a pure constant/value needs to move (e.g. widths read by both worlds); otherwise leave untouched; no behavioral change.
- `app/Kalam/Settings/Panes/BeingHeardPane.swift` — optional follow-up only: render the preview-strip tiles as miniature live SwiftUI surfaces instead of the bespoke mini renders, once the surfaces are stable.

**Remove (phase 4 only):**

- The AppKit content classes (`OverlayCapsuleView`, `WaveformView`, `PillLevelGlyphView`, `CaretChipView`), their private metrics schemas, and any now-orphaned ring/layering helpers, once the parity gate passes.

**Tests:**

- Keep: `KalamTests/IndicatorStyleTests.swift`, `KalamTests/IndicatorStateModelTests.swift`.
- Add: `KalamTests/IndicatorWaveformMathTests.swift` for the extracted math.

## 6. Rendering Design per Surface

**6.1 Machined deck (machined; and every held/blocked fallback)**

- A stadium-shaped surface whose visible fill is clipped to rounded-corner geometry so nothing square escapes (the "no square halo" rule). The fill is the flat obsidian surface color — deliberately **not** a live blur; the WindowServer window shadow (`hasShadow`) provides the elevation, exactly as today, with no in-layer shadow.
- A hairline rim around the surface: 1px stroke in the current rim color, plus the static green hairline ring when the state/session requires it (uniform full-border, no rotation) and its 6pt glow twin at the shipped opacity; both are layered so the outer half of the hairline sits on the background, mirroring today's double-stroke result.
- Top row (deck states): app icon, app name with middle-truncation behavior matching the current label, red recording dot, elapsed timer in SF Mono tabular digits. Truncation and the dot/timer spacing must match the mockup; the layout is SwiftUI stack layout, which handles the "stop before the waveform" constraint natively.
- Waveform area for listening/pausing: the `IndicatorWaveformView` fills the width with the right-entry flow, per-bar width/gap, minimum floor, and the green alpha ramp, with the pausing floor-and-slow-dot rule. The surface does not capture clicks.
- Held / blocked footer: on held, a filled primary action (Paste) and a secondary text action (Discard); on blocked, a single action label (Open Settings). Both are real buttons with generous hit targets; texts match today's strings.

**6.2 Whisper pill (whisper)**

- Compact surface at the shipped pill width and corner radius; no message text in listening/pausing/transcribing compact forms (matches today).
- Level glyph: three bars driven by the pure three-level math, brand green; the "glyph sinks to floor" pausing behavior is preserved.
- Ring: green hairline + glow twin installed only where today's law places it — whisper listening gets the slow ring (breathing), all-transcribing gets the fast ring; caret listening never; pausing keeps the existing ring behavior; reduce-motion freeze honored.
- Shimmer: the existing three-dot transcribing shimmer, using the same cadence, shown only in transcribing.

**6.3 At-caret chip (caret)**

- The small chip surface (dot + mini level bars + timer + hairline ring) rendered by SwiftUI inside the chip hosting view **inside the existing chip window** whose size is the currently shipped chip metrics.
- The chip content renders only while the controller owns the caret-visible recording states; fallback to deck is a controller decision using the existing anchored-rect rules, never a SwiftUI decision.
- The chip never resizes itself; the window frame comes from the controller.

**6.4 Waveform renderer**

- The waveform draws bars from the pure history array: right-to-left flow from the entry fraction, bar width/gap from tokens, heights from the smoothed amplitudes, minimum floor, alpha ramp progressing leftward. Rendering should isolate to a canvas-like draw of just the bars (a drawing group over the whole surface so per-tick layout never touches the whole hierarchy).
- Reset semantics: when a surface leaves a state that hides the waveform, the backlog clears so the next session starts fresh (today's `reset` behavior), driven by the published state change.

## 7. Window Ergonomics and Hosting Contract

- **Build-once, show-many:** both hosted roots are constructed once and reused; hiding/showing is window alpha + state, not host reconstruction.
- **Prewarm budget:** the first recording start must not pay SwiftUI initialization. The hosted root is materialized during controller prewarm (window build happens off-screen at launch, exactly as today). Verify with the existing first-trigger measurement that latency has not regressed.
- **Sizing:** the controller continues to own window frames/sizes (compact vs full) and placement/positioning math; SwiftUI fills whatever size the controller sets, with the root clipped to that size.
- **Interaction switching:** the `ignoresMouseEvents` toggle (on for the passive states, off for held/blocked when buttons must be tapped) remains a controller-owned store in response to state transitions — nothing inside SwiftUI changes hit-testing that.

## 8. Accessibility and Interactivity

- Buttons: fields/buttons expose the same labels and traits as today; the two-action held row keeps VoiceOver-readable separations and its button semantics, not a monolithic element.
- Ambient surfaces (waveform, chip) expose the elapsed recording time via an accessibility label equivalent to what exists today, and are not focusable.
- Reduce Motion differences remain visual only: they mask animations, never change state or labels.
- The app name/target for the held prompt comes from the genuinely captured target app (NSWorkspace identity at record start); the visual accent is unchanged.

## 9. Timing and Latency Rules

- Audio sample consumption stays on the main actor as today, fed by the same buffer path and the same cadence. Drive changes at existing rates; no new throttling expectation.
- The waveform tick is the compatibility risk: rendering on each tick must be measured as no slower than today before cutover. If measurement shows slowdown, the escape hatches are throttling updates to the currently effective cadence or pre-rendering bars ahead of the visible frame; design the renderer so these options remain available after measurement rather than requiring a rewrite.
- Any sample buffer lifecycle (reset on surface exit) is identical across both paths.

## 10. Migration Phases and Checklist

**Phase 0 — Baseline capture** *(moot post-cutover — annotated 2026-09-10)*
- [x] ~~Capture a rendered-reference screenshot per (state x style) from the current build and pin them (with build date) beside the study's HTML as the parity references.~~ *(Never captured before cutover; the AppKit path was deleted at Phase 4, so a pre-change reference is no longer obtainable. The study's HTML mockups remain the design reference.)*
- [x] Record the passing indicator-adjacent test list (green signature) so later phases can compare. *(Focused suites green throughout; full-suite signatures recorded at each phase's commit.)*

**Phase 1 — Extract pure math (no visual change)**
- [x] Move waveform envelope/AGC/smoothing and the level-glyph normalization out of the AppKit views into `IndicatorWaveformMath`.
- [x] The AppKit views consume the helpers; identical pixels, identical cadence.
- [x] New unit tests cover floor, noise gate, clamping, smoothing, AGC recovery, and the three-level normalization.
- [x] Gate: builds green; manual smoke shows no pixel diff across all five states. *(Build + focused suites green 2026-09-09; the manual smoke was superseded by the owner's post-implementation visual checks and the Phase 3 parity pass.)*

**Phase 2 — Published presentation-state bridge (AppKit views still render)**
- [x] Introduce `IndicatorPresentationState`; the controller publishes once per transition with values identical to what the AppKit views consume today.
- [x] A temporary probe asserts exactly one publish per transition. (`IndicatorPresentationStateTests` — revision bumps once per publish; timer ticks excluded.)
- [x] Gate: no behavior change observed; tests green. (AppKit path remains the default; the published state is consumed only by the flag-gated SwiftUI path.)

**Phase 3 — SwiftUI surfaces behind the parity flag**
- [x] Build the SwiftUI surfaces from `IndicatorTokens` only.
- [x] Host the SwiftUI root in both overlay windows; a DEBUG flag routes between the AppKit path and the SwiftUI path (same controller, same state source). Flag: `KALAM_SWIFTUI_INDICATOR=1` at launch; default stays AppKit.
- [x] Manual parity pass: every state x style against the references, including ring/glow, shimmer, Reduce-Motion, the fallback deck for held/blocked, chip positioning, and the Paste/Discard/Open Settings interactivity. *(Owner sign-off 2026-09-09 — two owner-reported visual deviations (constant glow ring, listening-state ring) were fixed under D-2 before sign-off.)*
- [ ] Performance check: first-trigger latency and per-tick waveform frame rates must not regress vs the AppKit path (measure, don't eyeball). *(STILL OPEN — the one concrete verification leftover. Practical route post-cutover: the app's `Recording start latency … toIndicatorMs=` telemetry against the recorded pre-cutover AppKit numbers (41–413 ms across the owner's 2026-09-09 log); a direct A/B would require checking out the pre-cutover commit (`556d70a^`).)*
- [x] Gate: parity matrix (section 11) fully green before any cutover. *(Satisfied by the owner's sign-off; the two D-2 fixes were re-verified.)*

**Phase 4 — Cutover and deletion** *(executed 2026-09-09 after the owner's parity sign-off)*
- [x] Flip the default to the SwiftUI path; keep the old views behind a compile-time fallback, then remove the fallback once smoke passes. *(Owner confirmed the parity matrix passed on their machine; `KALAM_SWIFTUI_INDICATOR` is no longer consulted — SwiftUI is the sole path.)*
- [x] Delete the AppKit content classes and their now-orphaned helpers; remove the parity flag. *(Removed: `OverlayCapsuleView`, `WaveformView`, `PillLevelGlyphView`, `CaretChipView`, the file-scope ring constants, and every `contentView`/`caretChipContentView` call site. `Presentation` was promoted from `OverlayCapsuleView` to the controller; the held-row width grow was reimplemented with token-matched text measurement in place of Auto Layout `fittingSize`.)*
- [x] Confirm the retained controller logic is unchanged in behavior (diff review excludes anything but content deletion). *(Window choreography, placement, AX caret anchoring, fades, sizing, auto-hide, and telemetry all untouched; one deliberate fix: the held chip's Discard title/action now travel in the published presentation itself — the old AppKit-only side channel had never reached the SwiftUI surface.)*
- [x] Final: full suite + one more manual pass of the matrix and the repo's manual verification checklist. *(Full suite 468 passed / 0 failed post-cutover; final manual pass on the running app owed by the owner as usual.)*

## 11. Parity Verification Matrix

| State | machined (deck) | whisper (pill) | caret (chip) |
|---|---|---|---|
| listening | waveform flow + icon row + timer | pill + level glyph + slow ring | chip at caret |
| pausing | waveform floor + slow dot | glyph at floor, ring keeps breathing | chip dims |
| transcribing | Transcribing + shimmer | compact pill + shimmer + fast ring | falls back to deck |
| held | message + Paste + Discard interactive | falls back to deck | falls back to deck |
| blocked | message + Open Settings | falls back to deck | falls back to deck |
| success (D-1) | surface fades out, no flash | surface fades out, no flash | surface fades out, no flash |

Horizontal invariants checked in every cell: window geometry/z-order/shadow, alpha fades, middle-truncated target name, timer digits, session styling (light/dark), and Reduce Motion behavior.

## 12. Tests and Gates

- Run at every checkpoint: the focused indicator suites (`IndicatorStyleTests`, `IndicatorStateModelTests`, new `IndicatorWaveformMathTests`) then the full repo suite at phase sign-offs, per the repo's existing build/test recipes (signing disabled).
- No pixel snapshots are introduced for the waveform (timing-sensitive); visual parity stays a manual matrix.
- The parity flag does not ship production-default until section 11 passes.

## 13. Open Questions for the Implementer

- Precise SwiftUI animation mechanism for the two ring speeds and the shimmer under Reduce Motion — pick the minimal approach tuned to the tokens' visual check.
- The deck <-> compact window size change: confirm SwiftUI-hosted content keeps corners exactly as the window animates its frame (the window resize path is today's, so this is a heritability check).
- Whether the waveform renderer needs a min-bar-floor at exactly the deck's floor value today (it stays token-specified either way); measurement decides if any throttling is needed.

## 14. Out of Scope (boundary — must not creep)

- Light appearance beyond the existing opt-in follow-appearance token set (standing ruling).
- Behavior/material changes: the surfaces stay flat obsidian; no live blur is introduced by the SwiftUI port.
- Any new state, new animation, new interaction, or a timer-format change.
- New dependencies, network paths, entitlements, or persistence/schema changes.

## 15. Decision Log (recorded during design — implementation pending)

Decisions taken while this plan was written. They amend the plan's scope where noted and land with the implementing agent's work; nothing here has been applied to the working tree.

**D-1 Silent success — the pasted text is the confirmation (2026-09-09)**

- Finding: the transient "Inserted" confirmation (the overlay's `.success` state) renders on the full 290pt machined deck in every style, including mid-whisper-pill sessions (transient auto-hide states are never compact-eligible). That produces a horizontal-length and design jump the mockup's fallback law does not authorize: only actionable states (held, blocked) fall back to the deck because they need buttons, and the confirmation carries none.
- Decision: a successful paste shows no confirmation flash in ANY indicator style. The pasted text appearing in the target app IS the confirmation; the overlay simply fades out through the existing hide path.
- Implementation shape: remove the `.success` case from the controller's private overlay-state enum and its presentation branch — a smaller interface with the same behavior behind it, so the overlay module gets strictly deeper. Route the three paste-success call sites in KalamApp (normal paste, paste fallback, held-transcript paste) directly to the existing `hide()`. The lifecycle event stream is unchanged (`.insertSucceeded` still fires); error/info/held auto-hide states keep their current forms (long info strings, actionable errors, buttoned held row).
- Verification addition: the parity matrix in section 11 gains a success row — every cell expects the visible surface to fade out with no flash (the state is removed, not restyled).
- Status: recorded only. The working tree still ships the flash; this decision lands with this plan's implementation.
- Indicator placement/positioning logic: the controller positioning and AX code has no change in this plan.
- Rewriting the window-shell and caret-trajectory code the product has intentionally kept AppKit.