# Kalam Compass — SwiftUI implementation package

On-device dictation **Settings** window for macOS 14+.  
American English. Window **980 × 660**. Surfaces locked to **Fog card**.

## Open this first

1. Open `spec/index.html` in a browser (entry + reading order).
2. Open `spec/compass-mockups.html` — **visual source of truth** (interactive frames).
3. Open `spec/compass-impl.html` — **implementation contract** (types, store, bans, plan).
4. Drop `Settings/Compass/` into the macOS app target and bind the live store.

## Precedence

| Conflict | Winner |
|----------|--------|
| Layout / what is on screen | `spec/compass-mockups.html` |
| Types, persistence, bans, migration | `spec/compass-impl.html` |
| File / symbol names | `Settings/Compass/` stubs |
| Spelling | en-US (`behavior`, `Normalize`) |

If it is not in mockups or impl, **do not invent it**.

## Fog card tokens (locked)

| Token | Hex | Role |
|-------|-----|------|
| Paper | `#F3F3EF` | Window / dive stage |
| Panel / control | `#FCFBF9` | Cards, type fields, chips |
| Well | `#EFEEEB` | Inset search, dictionary editor, sample strips |
| Hair | `#DFDFD8` | Borders |
| Green | `#1A5C3A` | Accent only |

See `Settings/Compass/CompassTokens.swift`.


## Typography (non-negotiable)

Use **only** `CompassType.style…` / `CompassFont.variable` from `CompassTokens.swift`.

| Must | Value |
|------|--------|
| Families | System serif (New York), SF Pro, SF Mono |
| Dive display size | **30pt** regular serif (not 32, not semibold) |
| Card header labels | weight **640**, tracked, uppercase SF Pro (not `.bold`) |
| Mic names | **regular** 13.5 (not semibold) |
| Contents titles | weight **560** (not 600) |
| Tracking | use `CompassType.track…` constants |

Full table: `spec/compass-impl.html` § Typography. Visual QA = side-by-side with `spec/compass-mockups.html`.

## Architecture (do not reopen)

- Utility window: `.windowStyle(.plain)`, not resizable, custom Close on map only.
- `NavigationStack` path length **0** (map) or **1** (dive). Contents **replaces** destination — not `NavigationLink` stack.
- One `SettingsModel` façade over existing app store via `CompassSettingsBacking`. **No second UserDefaults schema.**
- No network client. Updates opens release URL with `NSWorkspace`.
- No red error chrome. Attention = green CTA + span-2 card.
- Dictionary is an editor (search / add / edit / delete), not a form of toggles.
- Hotkey is the **live preset menu** (Not specified, right modifiers, combos, Fn) plus **Record shortcut…** capture. Modes stay radio rows only.
- Empty dictionary is span-attention only; hero stays ready; no green map CTA.

## Build order

Follow the numbered plan in `spec/compass-impl.html` (§ Build plan). Summary:

1. Window shell 980×660 + Fog tokens + privacy pill once per window.
2. `CompassSettingsBacking` + `InMemoryCompassStore` fixtures.
3. `SettingsModel` attention / spanning / map strings.
4. MapView (all map states M.1–M.8).
5. Dive chrome + ContentsNav (path assign, not push).
6. Panes: Being heard → Trigger → Cleanup → Dictionary → Engine → Updates.
7. Wire live store; a11y labels; stop.

## Stubs

```
Settings/Compass/
  CompassWindow.swift
  CompassTokens.swift
  CompassSettingsBacking.swift
  InMemoryCompassStore.swift
  SettingsModel.swift
  Destination.swift
  MapView.swift
  DiveView.swift
  ContentsNav.swift
  Controls/
  Panes/
```

Replace `InMemoryCompassStore` with the live app backing object.  
Port `smartCovers()` from the live app — do not keep the stub pluralizer.

## Optional

- `spec/palette-lab.html` — surface A/B explorer (**not** production SoT; Fog card is locked).

## Microphone priority

Numbered list with up/down step controls. **No drag handles.** First connected device is IN USE.

## Hotkey presets

See mockups D.2 / D.2b and impl § Hotkey. Swift: `HotkeyPreset` + `HotkeyControl`.

## Out of scope

Dark mode, second accent, network/update checker, HF download UI, model file checklist, bulk dictionary import, British spelling, “chapter” copy.
