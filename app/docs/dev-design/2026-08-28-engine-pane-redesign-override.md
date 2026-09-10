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

**Status:** Design override attempted (user directive); rebuilt Swift passed build (`BUILD SUCCEEDED`); user rejected result ("does not look like existing design at all" — `upload_20260828_062647_8.png` vs `v1.4` mockup); EnginePane rolled back to original flat card (`cp`, hairline `.kHair`, `Fog card` tokens); backing extensions (`downloadCommand`, `selectedDownloadVersion`) kept; design-brief (`2026-08-28-engine-pane-redesign-brief.md`) saved as audit; override doc preserved for future reference. (code rebuild + backing/store/protocol), `29e2ace` (checklist restructure), `6e11d9d` (design brief + override doc). Build verified (`BUILD SUCCEEDED`). Design-override doc (`2026-08-28-engine-pane-redesign-override.md`) confirms contradiction with K-30 spec line 27 (`cp`-only lock) overridden by user directive; production screenshots (`upload_20260828_055818_5/6/7`) are design authority.
