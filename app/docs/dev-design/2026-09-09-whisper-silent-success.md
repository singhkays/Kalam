# Recording indicator silent-success — decision record (2026-09-09)

**Status: IMPLEMENTED 2026-09-09.** The `.success` overlay state, its "Inserted"
presentation, and `showSuccessAndAutoHide()` are deleted; the three paste-success call
sites route straight to `hide()`. The SwiftUI surfaces (flag-gated, plan §10 Phase 3)
inherit the behavior through the published state — the parity matrix's success row is the
spec there. Full decision history below.

**Decision:** A successful paste shows no "Inserted" confirmation flash in ANY indicator
style (machined, whisper, caret). The pasted text appearing in the target app IS the
confirmation; the overlay fades out silently through the existing hide path. The
`.success` overlay state is retired entirely.

**Why (investigation evidence):**

- All three paste-success flows (normal paste, paste fallback, held-transcript paste)
  route through one controller method and display one hardcoded "Inserted" string, so the
  flash is a single-site behavior, not a per-style feature.
- In whisper style the flash renders on the full 290x34 machined deck even though the
  session runs the 200x30/150x30 pill: an in-code rule makes transient auto-hide states
  never compact-eligible. The mockup's fallback law (`kalam-indicator-v1/index.html`)
  authorizes deck fallback only for actionable states (held/blocked need buttons), and a
  buttonless 0.35s text flash does not qualify — hence the visible length/design mismatch.
- The pill already renders short text in-compact (the "Transcribing" pill), so compact
  eligibility was never the blocker; the flash simply did not belong on the deck for a
  non-actionable confirmation.

**Implementation shape (for the implementing agent):** see the plan, section 15, D-1 —
delete the `.success` overlay state and its presentation branch; call `hide()` directly at
the three success call sites; no token, dimension, copy, or lifecycle-event changes.

**Supersedes:** the earlier whisper-only framing of this decision.