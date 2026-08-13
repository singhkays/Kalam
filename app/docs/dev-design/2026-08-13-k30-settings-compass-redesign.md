# K-30 — Settings window redesign ("Compass")

**Date:** 2026-08-13 · **Status:** 🔄 (plan authored; implementation pending) · **Scope:** `app/Kalam/` app shell only — no `KalamTextEngine` package changes, no network code, no new UserDefaults schema.

## 1. Goal

Replace the current tabbed Settings window (`SettingsUI.swift` + `Kalam/Settings/*`) with the **Compass** design: a fixed 980×660 plain-chrome window with a "map" root (5 journey cards + Updates foot, exactly one attention card) and "dive" destinations (navigation path length 0 or 1), rendered in the locked **Fog card** token set, backed by one `SettingsModel` façade over the existing app store. All processing stays on-device; the window remains a window on the existing configuration.

## 2. Source of truth (read before any code)

Folder `app/docs/plans/kalam-settings-redesign/`:

| File | Role |
|---|---|
| `spec/compass-mockups.html` | Visual SoT — every 980×660 frame (M.1–M.8, D.1–D.6). Layout wins. |
| `spec/compass-impl.html` | Implementation law — types, bans, hotkey catalogue, live audit, build order, acceptance. |
| `Settings/Compass/**` | Swift stubs (≈2,500 lines) — symbol/file names win; port and adjust for the live store. |
| `spec/index.html` · `spec/swift-tree.html` · `README.md` | Reading order + precedence rules. |

**Precedence:** mockups > impl contract > stubs > this plan. "If it is not in mockups or impl, do not invent it."

## 3. User decisions (locked 2026-08-13)

1. **Presentation:** the AppDelegate-owned `NSWindow` hosts `CompassRoot` (no `WindowGroup` scene, no parallel Settings scene). The stub's `@Environment(\.dismiss)` and `CompassScene` are replaced by an injected `onClose` closure + a borderless-window configuration (documented deviations, §5.1).
2. **Full replacement:** after Compass lands, `SettingsUI.swift` and `Kalam/Settings/*` tabs are deleted. `.selectModelsSettingsTab` deep-links to the **Engine** dive (`path = [.engine]`).
3. **Dictionary:** one-time migration re-enables all existing disabled rules, gated by a new defaults flag; the per-rule enable toggle is not ported.
4. **Engine pane:** shows the `cp` copy command only (mockups lock "no HF CLI" in Settings); onboarding keeps its existing `hf download` flow untouched.

## 4. Architecture

```
AppDelegate (KalamApp.swift)
  └─ openSettingsWindow(selectModelsTab:)          [existing plumbing, hosts Compass]
       └─ NSWindow (borderless, 980×660 fixed, single instance, Cmd-W)
            └─ CompassRoot(store: LiveCompassBacking(), onClose:)
                 ├─ NavigationStack path []/[dest]  [Map ⇄ Dive; contents REPLACES path]
                 ├─ MapView (attention/hero/spanning from SettingsModel)
                 └─ DiveView → ContentsNav + 6 Panes
                      └─ SettingsModel (@Observable façade, computed props + revision)
                           └─ LiveCompassBacking  ← NEW adapter, the only live-store access
                                ├─ GeneralSettingsConfiguration / MicrophonePriorityConfiguration
                                ├─ PTTHotkeyConfiguration (+ customChord extension)
                                ├─ ModelsConfiguration.textCleanup / model library
                                ├─ CustomDictionaryManager.shared
                                └─ KalamExternalLinks / ModelSetupSupport / AVCaptureDevice
```

- **No second settings store.** Compass persists through the existing config structs and their existing notification posts (`.generalSettingsConfigurationDidChange`, `.pttHotkeyConfigurationDidChange`, `.modelsConfigurationDidChange`, `.microphonePriorityDidChange`) — the AppDelegate observers (`KalamApp.swift:185/199/215/225`) keep applying changes exactly as today.
- **New files** go in `app/Kalam/Settings/Compass/` — folder-synchronized group, no pbxproj edits.
- **Compass scene = none.** The `Settings { SettingsView() }` scene at `KalamApp.swift:29-36` is removed; the menu-bar "Settings…" item (Cmd+,) keeps calling `openSettings()` → the AppDelegate window path.

### 4.1 Reactivity — the critical design point

`SettingsModel` (stub) exposes only **computed** properties forwarding to the store. `@Observable` invalidates views on *stored-property* mutation only — computed properties that read an external store **never invalidate**. Without a fix, no toggle, no dictionary edit, no mic reorder would ever re-render.

**Required addition to the stub's `SettingsModel`:**

```swift
@ObservationIgnored private var onChangeTask: Task<Void, Never>?
/// Bumped on every store change; read by every computed property so views re-evaluate.
private var revision = 0

init(store: any CompassSettingsBacking) {
    self.store = store
    onChangeTask = Task { @MainActor in
        for await _ in store.onChange {
            self.revision += 1   // @Observable stored property → invalidates
        }
    }
}
```

Every computed property in `SettingsModel` reads `revision` (e.g. `_ = revision` as its first line, or `var attention: Destination? { _ = revision; switch engine { … } }`). `LiveCompassBacking.onChange` must yield on **every** change source: the five notifications above + `CustomDictionaryManager.$entries` (Combine sink) + mic/engine refresh calls. Use `AsyncStream` with `.bufferingNewest(1)` so bursts coalesce.

> Stub deviation #1 (documented in the plan file header of `SettingsModel.swift`): the stub relies on static previews; the live app needs the revision mechanism.

## 5. Component design

### 5.1 Window shell (`CompassWindow.swift` — stub deviation #2)

The stub assumes a SwiftUI `WindowGroup(id: "compass")` scene. Live presentation (per user decision 1):

- **NSWindow config** in `KalamApp.openSettingsWindow`:
  - `styleMask = [.borderless]` (no traffic lights — mockup bar is the chrome), `isMovableByWindowBackground = true`, `backgroundColor = .kPaper`, `identifier` stays `"KalamSettingsWindow"`.
  - `setContentSize(980×660)`; `minSize = maxSize = 980×660` (not resizable — replaces the K-21 900-wide config; **K-21's manual gate "900×672×3" is superseded**, update `MANUAL_VERIFICATION_CHECKLIST.md`).
  - **New `CompassWindow: NSWindow` subclass** (`override var canBecomeKey/canBecomeMain = true` — borderless windows refuse key status otherwise). Required for keyboard input (capture, search fields, Cmd-W).
  - Single instance + focus-on-reopen: existing `settingsWC` guard + `presentWindowController(wc, centerIfNeeded:)` unchanged.
- **Close:** `CompassRoot` takes `onClose: () -> Void` (replaces `@Environment(\.dismiss)`); the map's ✕ button and **Cmd-W** both call it → `wc.window?.close()`. Cmd-W is not native on borderless windows: `CompassRoot` installs a local keyDown monitor in `onAppear` (keyCode 13 + `.command` → `onClose()`), removed in `onDisappear` — same pattern as `KeyCapture`.
- **Refresh:** on appear **and** when the window becomes key: `model.refreshMicrophones()` + `model.rescanEngine()` (contract: "Refresh mics + engine on appear and when window becomes key"). `CompassRoot.onReceive(NSWindow.didBecomeKeyNotification)` filtered on `(note.object as? NSWindow)?.identifier == "KalamSettingsWindow"`.
- **Privacy pill:** `@State privacyLine = PrivacyLine.allCases.randomElement()` in `CompassRoot` — rolled once per window lifetime, shared Map/Dive (stub already does this; keep).
- Opening Settings never cancels recording (no change — settings never touched the recording path).
- `CompassScene` enum (stub) is deleted; its `WindowGroup` comment block becomes a "presentation contract" comment in `CompassWindow.swift`.

### 5.2 Types & protocol (`CompassSettingsBacking.swift` — port verbatim)

Port `CompassSettingsBacking.swift` stub as-is: protocol + `MicrophonePermission`, `IndicatorPlacement`, `ActivationMode`, `GrammarPass`, `MatchMode`, `KeySide`, `HotkeyPreset`, `KeyChord`, `Microphone`, `ReplacementRule`, `ModelInfo`, `EnginePresence`, `DictionaryEditorPhase`. One stub edit: `HotkeyPreset.makeChord()` returns `nil` for presets — the adapter resolves presets straight to `KeyCombination` (see §5.4); the stub's zeroed `keyCode/modifiersRaw` placeholder must NOT reach storage.

Note: the protocol's `ActivationMode`/`GrammarPass`/`MatchMode`/`KeySide`/`IndicatorPlacement` duplicate live names (`PTTHotkeyConfiguration.ActivationMode`, `TextCleanupGrammarMode`). Keep the Compass copies (they carry Compass copy strings) and map in the adapter — do not refactor the live enums.

### 5.3 `SettingsModel` (port stub + revision mechanism per §4.1)

Port `SettingsModel.swift` verbatim, plus the `revision` mechanism. All derived logic stays in the model: `attention` (engine missing|incomplete → no mic → key nil → empty rules), `spanning = attention ?? .engine`, `hero`, `mapNeedCTA`, `mapCardTitle/State/Description`, `contentsState`, `cleanupRulesOnCount`, `cleanupMapTitle`, `microphoneStatus(for:)` (IN USE = first connected — **not** row zero; LAST USED = `lastUsedID` still listed; permission denied ⇒ all OFFLINE), `moveMicrophone`, `chooseModelFolder` (cancel = silent).

### 5.4 Hotkey — storage & registration (the deepest integration)

**Live today:** `PTTHotkeyConfiguration` (preset-only `KeyCombination` + legacy `key`/modifiers; 4 UserDefaults keys under `pttHotkey.*`); `HotkeyListener.update` registers modifier-only presets via flagsChanged side-tracking (keyCodes 54/55/58/59/60/61/62) and key+modifier presets via `HotKey(key:modifiers:)`.

**Compass needs:** `nil` (Not specified), the same preset catalogue, and **custom chords** (arbitrary key + modifiers + side + display strings) from Record shortcut… capture.

- **Storage (extends the existing `pttHotkey.*` domain — same schema, additive keys, no Compass-* keys):**
  - `pttHotkey.customKeyCode` (Int), `pttHotkey.customModifiersRaw` (UInt), `pttHotkey.customSide` (String), `pttHotkey.customDisplayVerbose` (String), `pttHotkey.customDisplayCompact` (String). Absent ⇒ no custom chord.
  - `PTTHotkeyConfiguration` gains `var customChord: KeyChord?` (load/save/Equatable updated). Semantics: `hotkey == nil` ⇔ `keyCombination == .notSpecified && customChord == nil`. Custom chord wins over the preset fields when present; selecting a preset clears `customChord`; capture sets it.
  - `normalized()` leaves `customChord` untouched; `resolvedHotkey` prefers it (modifiers from `modifiersRaw`, key via `PTTHotkeyKey.fromKeyCode(keyCode)` — existing table covers A–Z, 0–9, Space, F1–F12).
- **Registration:** extend `HotkeyListener.update(configuration:)` — if `customChord != nil`: key+modifiers → `HotKey(key: <fromKeyCode>.hotKeyValue, modifiers:)`; bare-modifier custom chords → reuse the flagsChanged monitor path generalized to track the chord's exact modifier keyCode (the side tables at `HotkeyListener.swift:118+` already key on keyCode — generalize `activeModifierFlags` to an optional `activeModifierKeyCode`). Keep the public signature; the AppDelegate `.pttHotkeyConfigurationDidChange` observer (`KalamApp.swift:185`) needs no change.
- **Adapter mapping:** `hotkey` getter — nil if unset; else `KeyChord` built from `customChord` if present, else from `KeyCombination` (display strings from the existing `displayName`; verbose form from the stub's `HotkeyPreset.mapVerbose`-style table — add a `KeyCombination.displayVerbose`).
- **Capture (`KeyCapture`/`HotkeyControl` stubs):** port both; replace the stub's placeholder `KeyChordFormatter` display tables with a real formatter:
  - Accept allowlist: letters/digits/Space/F1–F12 (`PTTHotkeyKey.fromKeyCode` non-nil) or bare-modifier keyCodes (54, 55, 58, 59, 60, 61, 62, 63). Escape (53) cancels capture. Everything else → dashed keycap + "That key cannot be used." for 800 ms (`CompassLayout.rejectFlashNanos`), monitor stays registered.
  - Display: modifier symbols ⌘⌥⌃⇧ per flags + key name from `PTTHotkeyKey.displayName` (or `event.charactersIgnoringModifiers` uppercased for letters/digits); side from the keyCode tables (matches `HotkeyListener`'s).
  - System-shortcut conflicts: accept silently (contract). No Clear button. Local monitor only while capturing; `onDisappear` removes it.
- **Preset menu:** `HotkeyControl` stub ports the full catalogue (12 presets + separator + "Record shortcut…" + footnote "Right-side presets need the physical right key."). Checkmark = current selection; a custom chord that matches no preset leaves the menu with none selected (chip still shows the custom label).
- **Modes:** radio rows only (no Activation dropdown) — `TriggerPane` stub.

### 5.5 Indicator placement — migration + overlay support

- `SettingsConfiguration.swift`: replace `IndicatorPlacementPreset` (topCenter/bottomCenter) with the Compass `IndicatorPlacement` (topLeft/topCenter/topRight + `label` + `migrating(fromStored:)`), stored under the **same key** `general.indicatorPlacementPreset`. Legacy raw values (`bottomCenter`, `"Top Center"` etc.) coerce to `.topCenter` on read; **write-through**: `GeneralSettingsConfiguration.save()` always writes one of the three new rawValues, so the legacy value is replaced the first time anything saves.
- **Overlay consumer:** `DictationOverlayController.swift:277` reads the preset at show time — switch it to the new enum and extend the pill placement math to top-left/top-center/top-right (current topCenter geometry is the reference; bottomCenter path is deleted).
- Behavior-card indicator control = SwiftUI `Menu` anchored to the chip (D.1e): three text rows + checkmark, **no toggles in the menu**, no Off, no bottom rows. The stub's D.1e note is the contract — never a custom overlay over the Behavior column.

### 5.6 Microphones

Adapter (`LiveCompassBacking`):

- `microphones` — cache of `MicrophoneDeviceService.mergedPriorityList(config: MicrophonePriorityConfiguration.load())` → `Microphone(id: uid, name:, isConnected: descriptor.isAvailable)`. `refreshMicrophones()` re-derives the cache (and is also called from `onChange` sources).
- `moveMicrophone(from:to:)` — reorder the cached list, then persist `priorityUIDs = orderedUIDs` via `MicrophonePriorityConfiguration.saveAndNotify()` (run `normalize(config:)` first — same as today's `SettingsView` path).
- `lastUsedID` ⇄ `UserDefaults` key `GeneralSettingsKeys.selectedInputUID` (`audio.selectedInputDeviceUID` — the mic the recorder actually used; there is no separate last-used store in the live app).
- `microphonePermission` — `AVCaptureDevice.authorizationStatus(for: .audio)` → granted/denied/notDetermined.
- IN USE = first connected in the ordered list (model logic, pinned by tests); tags IN USE / LAST USED / OFFLINE via `microphoneStatus(for:)`.
- D.1c (no devices — permission not denied) and D.1d (permission denied → "Open System Settings" → `SystemSettingsNavigator.open(.microphone)`, **no** `requestAccess` from this button) — `BeingHeardPane` stub ports these states.

### 5.7 Cleanup

Adapter maps 1:1 onto `ModelsConfiguration().textCleanup` (`TextCleanupConfiguration`, engine package — keys `textCleanup.*`, saved by `ModelsConfiguration.save()`):

| Compass | Live |
|---|---|
| `cleanupEnabled` | `textCleanup.enabled` |
| `removeFillers` | `textCleanup.removeFillers` |
| `handleBacktracks` | `textCleanup.backtrack` |
| `formatLists` | `textCleanup.listFormatting` |
| `normalizePunctuation` | `textCleanup.punctuation` |
| `grammarPass` | `textCleanup.grammarMode` (off/light/full) |

Every setter: load `ModelsConfiguration`, mutate `textCleanup`, `save()`, post `.modelsConfigurationDidChange` (single-flight like the old shell's `persistModelsConfigurationIfNeeded`; the AppDelegate observer reacts as today). `grammarTimeoutMs` is untouched (no UI). Pane: master card + rules card (wells only for fillers and lists, only when master on AND rule on — D.3/D.3b/D.3c) + grammar `PaperSegment`; `.disabled(!cleanupEnabled)` dims but preserves values (D.3b). Well copy is static (mockups D.3, D.3c — "Messy input"/"Clean output" strips, one pressed well, 1px green split at 22%, no two-tone columns).

### 5.8 Dictionary

- **Adapter:** `rules` getter = `manager.entries` → `ReplacementRule(id:, spoken: trigger, typed: replacement, mode: (caseInsensitive || preserveCase) ? .smart : .literal)` (mirrors `CaseMatchingMode.from(entry:)`). Setter = map back (`isEnabled: true` — post-migration; `caseInsensitive/preserveCase` per mode; `userAdded: true`), replace `manager.entries`, call `manager.entriesDidChange()` (debounced save + recompile — pipeline stays hot).
- **One-time migration (user decision 3):** new defaults key `dictionary.migratedToCompassRules` (Bool). On `LiveCompassBacking` first `rules` access: if flag absent → set `isEnabled = true` on every entry that has it false, `manager.saveImmediately()`, set flag (flag set even when nothing was disabled — runs once). Pure function `DictionaryRuleMigration.shouldRun(flag:hasDisabled:)` for tests.
- **Covers:** port the live `DictionaryEntry.exampleMatches` (engine package — already the tested "smartCovers" logic; do NOT reimplement a pluralizer). `DictionaryPane` form builds a temp `DictionaryEntry(trigger: spoken, typed: typed)` and shows `exampleMatches` chips when mode == .smart; exactly one `spoken → typed` chip when .literal (D.4k). Mute hint "Type both sides to see the forms Smart will match." when either side empty.
- **Validation (D.4j):** `canSave` = both sides non-empty after trimming; Save `.disabled` + primary opacity 0.42. Trim on save; **max 128 scalars per side; strip newlines** (contract) — enforce in the pane save path and defensively in the adapter setter.
- **Phase machine** (`DictionaryEditorPhase`): browsing / adding / editing(UUID) / confirmingDelete(UUID) — port the stub; inline confirm (D.4g, "Keep" = primary safe default, "Remove" quiet outline, no red, no NSAlert); hide `+` while adding/editing/filtering (D.4c/D.4h); "1 rule"/"N rules"/"N of M"/no-match copy (D.4e/D.4h/D.4i). Removing the last rule returns the empty state **and** flips map attention (model does this automatically via `attention`).
- **K-20 corrupt-store notice (deliberate deviation):** the spec has no error banner, but silently dropping the `loadFailureNotice` would hide a real recovery path. Show it as a quiet ink-3 mono line at the top of the dictionary card when non-nil (no icon, no red — stays within "no error chrome").
- **First-launch seeding moves:** `SettingsUI.onAppear`'s `isFirstLaunch` cleanup (`entries.removeAll { !$0.userAdded }` + `saveImmediately`) moves to `CompassRoot.onAppear`.

### 5.9 Engine

- `modelFolder` — `ModelsConfiguration.load().modelLibraryURL ?? ~/Kalam/models` (display; tilde-shortened like the stub's `displayPath`).
- `engine` — `availability(for: config.asrVersion)` → `.verified(ModelInfo(name: shortName, detail: version.description))` / `.missing` (`modelLibraryNotConfigured` | `missingModelFolder`) / `.incomplete` (`invalidModelFolder`). **Short name:** "Parakeet v2"/"Parakeet v3"/"Parakeet 110m" (map title must not be the long live `displayName`); `detail` uses the live `ASRModelVersion.description` ("25+ languages · on this Mac" style).
- `chooseModelFolder()` — wrap `ModelSetupSupport.chooseModelLibraryFolder(currentURL:completion:)` in a continuation; on URL: `ModelSetupSupport.applyingModelLibraryFolder(url, to: config)` → save + post `.modelsConfigurationDidChange` + rescan; cancel → silent (D.5d).
- `rescanEngine()` — re-derive presence from `availability(for:)`.
- `installCommand` — `cp ~/Downloads/Parakeet* <modelFolder>/` (user decision 4; the stub's tilde form is the model). Copy via `NSPasteboard` (same as the existing `CommandCopyRow` pattern — user-initiated, not the transcript path).
- **No** HF CLI, no file checklist, no multi-model picker, no Finder/Clear in the pane (D.5/D.5b/D.5c share one pane; strings from the engine-presence matrix in the contract).

### 5.10 Updates

Port `UpdatesPane` stub: maintenance chapter (¶, pinned below divider in ContentsNav), version figure (`SettingsModel.versionString`), "View latest release" → `NSWorkspace.shared.open(KalamExternalLinks.latestReleaseURL)`, why-card. **Never** `URLSession`/`head`; no last-checked date.

### 5.11 Accessibility (contract §a11y)

Close "Close"; Back "Back to overview"; map card label "{dest}, {state}, {title}" with decorative "Open →" hidden; state dots VO-ignored; privacy pill not a live region; fixed Dynamic Type (`dynamicTypeSize(.large)`); reduce motion: no map hover lift, toggles snap. Port `PaperToggle` (a11y button On/Off), `PaperSegment`, `MapCard` hover behavior from stubs.

## 6. File plan

**New — `app/Kalam/Settings/Compass/`** (folder-synced; no pbxproj edits):

```
CompassWindow.swift        CompassRoot (onClose injection) + CompassWindow (NSWindow subclass)
CompassTokens.swift        tokens/layout/type (port verbatim)
CompassSettingsBacking.swift  protocol + shared types (port verbatim)
LiveCompassBacking.swift   NEW adapter (only live-store access)
InMemoryCompassStore.swift fixtures (port; keep for previews + tests)
SettingsModel.swift        port + revision mechanism (§4.1)
Destination.swift          port verbatim
MapView.swift              port verbatim (MapCard/MapFoot included)
DiveView.swift             port verbatim
ContentsNav.swift          port verbatim
Controls/  PaperToggle, PaperSegment, KeyCapture, HotkeyControl, MapCard, PrivacyPill
Panes/     BeingHeardPane, TriggerPane, CleanupPane, DictionaryPane, EnginePane, UpdatesPane
```

**Modified:**

| File | Change |
|---|---|
| `KalamApp.swift` | Remove `Settings` scene (29-36); `openSettingsWindow` hosts `CompassRoot(store: LiveCompassBacking())` with the §5.1 window config; `selectModelsTab: true` → post `.selectModelsSettingsTab` **before** presenting (CompassRoot observes → `path = [.engine]`); move dictionary first-launch seeding into CompassRoot; keep menu item / `openLatestRelease` / `openSetup` unchanged |
| `SettingsConfiguration.swift` | `IndicatorPlacement` replaces `IndicatorPlacementPreset` (+ `migrating(fromStored:)`); move `selectModelsSettingsTab` name here if `SettingsSharedComponents.swift` is deleted |
| `PTTHotkeyConfiguration.swift` | `customChord: KeyChord?` + 5 new keys (§5.4); `displayVerbose` table for `KeyCombination` |
| `Services/HotkeyListener.swift` | Custom-chord registration (§5.4) — generalized modifier-keyCode tracking |
| `DictationOverlayController.swift` | 3-position indicator placement (§5.5) |

**Deleted** (after Phase 6 build is green): `SettingsUI.swift`, `Kalam/Settings/{GeneralSettingsTab,ShortcutSettingsTab,CleanupSettingsTab,ModelsSettingsTab,UpdatesSettingsTab,WordReplacementView,SettingsSharedComponents}.swift`, `SetupDropdownField.swift` (verify no other users first — grep before deleting; `KalamTheme.swift`/`KalamControlStyles.swift` stay: onboarding + overlay still use them).

## 7. Test plan (RED → GREEN)

No engine-package changes — `./scripts/test-engine.sh` must stay **60/60** throughout.

New tests in `KalamTests/` (module `Kalam_test`; `@MainActor` test classes for model/adapter tests — K-20 lesson):

| Suite | Covers | RED shape |
|---|---|---|
| `SettingsModelTests` | attention priority (engine > mic > key > dict; two-problems = engine wins), spanning fill (settled ⇒ engine wide, never vacant), hero text/italic pairs, mapNeedCTA nil for dictionary, cleanupMapTitle ("3 rules, light", "Off"), mapCardTitle/State/Description per state incl. incomplete, contentsState (Unset/Right Cmd/3/4/Empty/v3), microphoneStatus (IN USE = first connected — pin the "not row zero" bug), moveMicrophone via fixture store | Runtime assertions against `SettingsModel(store: fixture)` |
| `LiveCompassBackingTests` | indicator migration (`bottomCenter`/`"Top Center"`/garbage → topCenter + write-through), hotkey round-trip (preset ⇄ chord; custom chord persist/load via temp defaults suite `UserDefaults(suiteName:)`), rules ⇄ entries mapping + `DictionaryRuleMigration` (disabled re-enabled once, flag set; second init no-op), cleanup 1:1 mapping, mic mapping incl. offline rows + `moveMicrophone` persistence, engine presence from availability (inject bookmark seams — `ModelsConfiguration.load` already takes `resolveBookmark`/`makeBookmark`), lastUsedID ⇄ `audio.selectedInputDeviceUID` | Same-suite temp UserDefaults + fixture JSON dict file via `CustomDictionaryManager(storeURL:)` |
| `KeyChordFormatterTests` | synthesized `NSEvent.keyEvent(with:)`: letters/digits/Space/F1–F12 accepted, Escape → nil/cancel, modifier keyCodes → side labels, reject flash path for unmapped keyCodes | Runtime assertions |
| `CompassSettingsBackingTests` (optional) | protocol conformance of fixtures — smoke | — |

Commands (from repo root):
- Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- New suites: `xcodebuild test … -only-testing:KalamTests/SettingsModelTests` (…`/LiveCompassBackingTests`, `…/KeyChordFormatterTests`)
- Full suite must stay green (109 passed / 0 failed / 3 skipped baseline).

## 8. Phased execution (each phase ends green; commit per phase)

| Phase | Deliverable | Verify |
|---|---|---|
| **P1 Window shell** | Tokens, `CompassWindow` subclass, NSWindow hosting `CompassRoot(store: InMemoryCompassStore)`; privacy pill; Cmd-W; fixed 980×660 | Build green; window opens from menu item, no traffic lights, drag by background |
| **P2 Model** | Protocol + types + `SettingsModel` + revision mechanism + `SettingsModelTests` | RED→GREEN; build |
| **P3 Adapter** | `LiveCompassBacking` + hotkey storage/registration + indicator migration + overlay positions + `LiveCompassBackingTests`/`KeyChordFormatterTests` | RED→GREEN; engine 60/60; build |
| **P4 Map** | `MapView` + `MapCard`/`MapFoot` wired to live model | Build; visual check vs M.1–M.8 |
| **P5 Dives** | `DiveView` + `ContentsNav` + 6 panes (stub ports + store calls) | Build; per-pane smoke against live store |
| **P6 Live wiring** | KalamApp scene removal, menu/openSettings window swap, `.selectModelsSettingsTab` → Engine dive, seeding move, delete old settings files (+ `SetupDropdownField` if orphaned) | Build; onboarding "Settings" opens Compass at Map; full suite green |
| **P7 Docs & gates** | DEVELOPER_GUIDE settings section; MANUAL_VERIFICATION_CHECKLIST (K-21 gate → 980×660 fixed); tracker ✅ after 🧑 gates | See §9 |

## 9. 🧑 Manual gates (user or headless-driving per `macos-ui-driving-manual-gates`)

1. Window: 980×660, not resizable, no traffic lights, draggable by background, Cmd-W closes, reopen focuses the same window (single instance), privacy line stable across map⇄dive and changes per window open.
2. Map states: settled / engine missing / engine incomplete / no mic / key unset / empty dict / cleanup off / two problems (reachable via defaults + model folder manipulation).
3. Being heard: 4 toggles persist across relaunch; indicator menu shows exactly 3 rows + checkmark, anchored to chip; mic drag reorder persists (`audio.inputPriorityUIDs`); permission-denied card opens System Settings (mic permission withheld = user-owned gate); empty list card.
4. Trigger: preset select persists + PTT works with the new hotkey immediately; Record shortcut… captures a letter; Escape cancels; invalid key (e.g. Tab) flashes and stays in capture; bare right-⌘ custom capture works for PTT.
5. Cleanup: master off dims + disables rules/grammar, values preserved when re-enabled; wells only for fillers/lists and only when on; grammar segment persists.
6. Dictionary: add → first-rule map flip; edit in place; inline delete confirm ("Keep"/"Remove"); search "1 of 3"/"0 of 3"; covers chips smart (5 forms) vs literal (1); >128-scalar side blocked; pre-seed a disabled rule in `user_dictionary.json` → first Compass open re-enables once, flag set, second open no-op.
7. Engine: Choose… folder → bookmark persists, presence updates immediately; Copy command puts the cp string on the pasteboard; missing/incomplete copy per matrix.
8. Updates: "View latest release" opens the browser; console shows no URLSession traffic.
9. Regression: dictation pipeline untouched — one real dictation after the redesign (engine 60/60 + full suite green are machine gates).

## 10. Risks & pitfalls (repo-specific)

- **`@Observable` computed-only trap** (§4.1) — the #1 silent-failure risk; covered by the revision mechanism + a test that mutates the fixture store and asserts the model reflects it.
- **Folder-synced groups** — new `.swift` files auto-join the target; no pbxproj edits; do not write source mid-build (spurious `SwiftCompile` failures).
- **`@MainActor` tests** — `SettingsModel`/`LiveCompassBacking` are `@MainActor`; test classes must be `@MainActor` (K-20 lesson: fix isolation first, then runtime RED appears).
- **NSWindow borderless** — `canBecomeKey` subclass required or search fields/capture/menu never receive keyboard.
- **`HotKey.Key` mapping for custom chords** — route through existing `PTTHotkeyKey.fromKeyCode` (letters/digits/space/F1–F12); unmapped keyCodes are rejected at capture time, so registration can never receive one.
- **SwiftUI `Menu` styling limits** — paper menu + green selection is approximated (`borderlessButton` + custom label, checkmark rows); do not build custom window-absolute overlays (contract D.1e ban).
- **Deleting old settings files** — grep `SettingsView|SettingsTab|SetupDropdownField|KalamTheme` usages first (`KalamTestRunner.swift`, previews, onboarding); `SettingsSharedComponents.selectModelsSettingsTab` name moves, not dies.
- **`NSPasteboard` in tests** — only `EnginePane` Copy touches the pasteboard (UI, not unit-tested); unit tests that touch pasteboards need the sync-runloop discipline (K-08/K-09 lesson) — avoid by not unit-testing the copy action.
- **Shared-mount git discipline** — stage only own hunks; re-read files before overwriting; sibling sessions may touch `KalamApp.swift` concurrently (it is the shared hot file).

## 11. Acceptance (from impl contract §accept)

M.1 → Dictionary → add rule → Back shows M.2; privacy line stable within a session. Incomplete → M.8 + D.5c strings. D.1c/D.1d correct empty vs permission. D.1e menu anchored to chip, no toggles. Cleanup master off dims rules, values preserved. Updates never URLSession. No Compass-* UserDefaults keys (audit `defaults` domain after a full session). en-US strings. Dictionary delete works; mic IN USE = first connected. Window 980×660 fixed.

---

## Execution notes (2026-08-13, appended after implementation)

Machine-verified: **BUILD SUCCEEDED**; engine 60/60; full Xcode suite **158 passed / 0 failed / 4 skipped** (baseline 109/0/3; +49 Compass tests). Live smoke (headless AX driving): Compass window opens at exactly 980×660 from the status-bar "Settings…" item, borderless (custom ✕ + Kalam wordmark, no traffic lights), map renders M.3 attention ("The engine needs a *model.*", being-heard card "No microphone / OFFLINE"), clicking the engine card opens the Engine dive (contents nav 01 Offline / 02 Shift + Cmd / 03 4/4; D.5b copy). The K-21 900-wide gate is superseded (checklist updated).

Deviations from the plan text (all within the locked decisions):

1. **Live `ActivationMode` renamed → `PTTActivationMode`** (`PTTHotkeyConfiguration.swift`, `PTTStateMachine`, `OnboardingFlow`, old tab). RawValues unchanged, persistence untouched. The Compass copy-carrying `ActivationMode` now compiles collision-free.
2. **`Settings` scene → inert empty scene + `CommandGroup(replacing: .appSettings)`.** Live observation: with `Settings { SettingsView() }`-shaped scenes, SwiftUI injects a system "Settings…" menu item that opened the *scene* (a blank 900×450 titled window) instead of the Compass window. The replaced command group removes that item; only the status-bar item (Cmd+, → `openSettings`) remains. (`defaultLaunchBehavior(.suppressed)` rejected: macOS 15+, target is 14.6.)
3. **Deleted `KalamControlStyles.swift`** (only the old tabs used it) alongside `SettingsUI.swift` + 7 `Kalam/Settings/` files. `SetupDropdownField.swift` kept (onboarding uses it).
4. **Covers** ported via `DictionaryEntry.exampleMatches` (split on first " → ") — verbatim live logic; `LiveSmartCovers` stub deleted.
5. **Mic drag-reorder** = custom grip `.onDrag`/`.onDrop` (stub's `ForEach.onMove` is inert outside a `List`); drop target = 2px green inset hairline @ 45% per contract.
6. **First-launch dictionary seeding** moved into `LiveCompassBacking.init` (was `SettingsView.onAppear`).
7. **No deinit on `LiveCompassBacking`** — Swift 6 forbids touching non-Sendable MainActor properties from nonisolated deinit; observers/sink capture weak self so a released backing is harmless.
8. `DictionaryRuleMigration.runIfNeeded` is `@MainActor`.
9. **`.selectModelsSettingsTab` posted one runloop turn later** (`DispatchQueue.main.async`) — the freshly created CompassRoot must register its observer first.
10. **`HotkeyPreset.makeChord()`** now returns real keyCode/modifiers via `KeyCombination.keyMapping` + new `PTTHotkeyKey.keyCode` reverse table; custom chords register through `Key(carbonKeyCode:)`; bare-modifier custom chords use a generalized flagsChanged monitor (`activeCustomModifierKeyCode`).
11. **`InMemoryCompassStore` properties now `didSet { ping() }`** — the fixture must model the live store's onChange contract (found by the RED revision tests).
12. **K-20 notice** shown as a quiet ink-3 mono line in the dictionary card (documented deviation, plan §5.8).
13. **`CompassRoot`** uses injected `onClose` (no `dismiss()`); `CompassWindow` subclass provides `canBecomeKey`/`canBecomeMain`.
14. `testMoveMicrophonePersistsPriorityOrder` skips when the test host reports no input devices.

Open 🧑 gates (plan §9): per-pane interaction smoke, hotkey capture on real hardware, indicator 3-position rendering, dictionary migration on a real store, mic drag on a real device list, onboarding deep-link.
