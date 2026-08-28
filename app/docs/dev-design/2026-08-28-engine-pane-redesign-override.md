# Design override — T17 EnginePane redesign (user override 2026-08-28)

**Lock broken:** `dev-design/2026-08-13-k30-settings-compass-redesign.md` §4 line 27:
"Engine pane: shows the `cp` copy command only (mockups lock 'no HF CLI' in Settings);
onboarding keeps its existing `hf download` flow untouched."
This is OVERRIDDEN by user directive (design override A) — "rebuild EnginePane
as a 3-step guided wizard matching onboarding; replace `cp` with `hf download`;
screenshots are spec authority" (production screenshot `upload_20260828_054137_4.png`).

**Source of truth for rebuild:** onboarding flow (dark card, 3-step wizard:
folder picker → `brew install hf` CLI + `Copy Install Command` → `Download model`
with model picker "Parakeet TDT v2 (English-only)" / v3 / v2 / TDT-CTC 110M,
`hf download ... --local-dir` command, "Installed"/"Missing" badges, folder layout info,
"Continue when ready" footer). Live Compass Engine pane (`EnginePane.swift`) is the
live file being redesigned.

**Scope:** `EnginePane.swift` rebuilt as 3-step guided wizard; keep existing
`SettingsModel.engine` state (`EnginePresence`: `.verified`, `.missing`, `.incomplete`);
keep diagnostic sections (Active model / MISSING status / Crash recovery toggle /
"Why there is no download") as footer/state cards; add full `hf download` command
(replacing `cp`); add model picker (replicating onboarding dropdown with
`ASRModelVersion`); keep `rescanEngine()` and `onAppear` behavior.

**Not committed yet — pending implementation verification.**
