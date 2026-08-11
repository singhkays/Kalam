# K-04 — SettingsUI.swift Tab Split: Implementation Plan

**Date:** 2026-08-11
**Status:** Planned — not yet executed. Authored per the K-05/K-06 precedent (plan first, then claim `🔄`, then execute).
**Scope:** Split the 2,154-line `app/Kalam/SettingsUI.swift` into per-tab files under `app/Kalam/Settings/`, leaving a slim orchestrator shell. Pure structural refactor — **zero behavior change**.
**Sources:** `app/Kalam/SettingsUI.swift` (read in full, 2,154 lines, verified 2026-08-11), `app/Kalam/KalamApp.swift:31–34, 323–350` (SettingsView consumers), `app/KalamTests/` (grep: zero references to settings types), `app/Kalam/KalamTheme.swift:56` (NoiseView), `app/Kalam/KalamControlStyles.swift` (KalamToggleStyle/KalamCheckboxStyle/KalamSegmentedControl/KalamMenuPicker), `app/Kalam/ModelsConfiguration.swift:7,91` (ASRModelVersion/ASRModelAvailability), `app/Packages/KalamTextEngine/Sources/KalamTextEngine/DictionaryEntry.swift:3` + `TextCleanupConfiguration.swift:3` (engine types), AGENTS.md:41,85, DEVELOPER_GUIDE.md:75, IMPROVEMENT_PLAN K-04.
**Executing agent note:** all line numbers below were verified against the working tree on 2026-08-11 and **will drift** — every task re-locates its range by anchor string before cutting (the grep commands are given).

---

**Goal:** `SettingsUI.swift` 2,154 → ~350-line shell. `SettingsView` keeps orchestration (tab state, config loading, persistence); each tab becomes an internal `View` struct in its own file.

**Architecture (the key design decision):** *Binding-hoisting, not per-tab self-loading.*

- `SettingsView` **stays the orchestrator**: it keeps the shared config `@State` (`hotkeyDraft`, `modelsConfig`, `generalConfig`, `micPriorityConfig`), the `onAppear` full-config load, the four `persist*IfNeeded()` handlers, the `isInitializingSettingsState` save-guard, `selectedTab` + the nested `SettingsTab` enum (KalamApp.swift:334 references `SettingsView.SettingsTab` — **must stay nested**), and the `.selectModelsSettingsTab` → `selectedTab = .models` receive handler (KalamApp posts it at :330/:348).
- Each tab becomes a new internal `View` struct that **receives the config it edits as a `@Binding`** and **owns only its UI-local `@State`** (expand flags, copied-feedback flags, mic rows, sheet/alert presentation, refresh IDs).
- **Why NOT per-tab self-loading configs:** `modelsConfig` is edited by *two* tabs (Models selects `asrVersion`; Cleanup edits `textCleanup`). Two independent `@State .load()` copies would diverge — the second tab to save would clobber the first's edits. Hoisting in the shell is the minimal-change structure that preserves today's single-copy semantics exactly.
- **Why NOT an `@Observable`/`ObservableObject` config rearchitecture:** K-04 is a Medium-severity structural split. Changing config storage changes persistence semantics (save triggers, guards, notification fan-out) and deserves its own plan + test pass. Out of scope here.
- **File-private helpers travel with their sole consumer** (K-03 precedent): `Metrics` + `MicrophoneRowDropDelegate` → General; `instructionRow`/`ShortcutRecorderSheet` → Shortcut; `refineOption`/`grammarDescription`/`grammarModeBinding`/`PreferenceRow` → Cleanup; `ModelSelectionRow` → Models; `EditableRow` → WordReplacementView. The one shared helper, `settingsCardSurface` (used by all six tabs), gets promoted `fileprivate` → `internal` and lives in a shared file.
- `Notification.Name.selectModelsSettingsTab` → shared file (used by shell `onReceive` and posted from KalamApp).

**Tech Stack:** Swift 6 (strict concurrency), AppKit/SwiftUI, Xcode project with `PBXFileSystemSynchronizedRootGroup` targets — dropping `.swift` files into `app/Kalam/Settings/` auto-joins the app target (the `Services/` subfolder already proves nested folders synchronize; **no pbxproj edits**). SwiftPM engine package untouched.

---

## Global Constraints

1. **Zero behavior change.** This is a cut-and-paste + binding-wiring refactor. The only permitted edits are: (a) per-file import blocks, (b) `settingsCardSurface` `fileprivate`→`internal`, (c) the shell `mainContent` branch rewiring, (d) deleting the moved members from the shell, (e) the alert/sheet attachments moving from shell to tab body. Do not rename symbols, reorder members, reformat, or "fix" anything.
2. **No network code; never log transcript/audio content** (hard invariants). Restated for the new files: none of this UI touches the network or logs content — keep it that way (the only `NSWorkspace` call is `openModelLibraryInFinder` / `KalamExternalLinks`, browser/AppKit-only).
3. **Swift 6 annotations travel verbatim.** All tab structs are SwiftUI `View`s (MainActor-isolated by the `View` protocol) — no concurrency restructuring during the move.
4. **Folder-synced groups:** new files auto-join the `Kalam` target. No `project.pbxproj` changes. Do not create an Xcode group manually.
5. **Shared-mount git discipline (critical — siblings work on this repo; `IMPROVEMENT_PLAN.md`, `KalamApp.swift`, `OnboardingFlow.swift`, `OnboardingFlowTests.swift` currently carry uncommitted sibling changes):**
   - Never `git add -A`. New files are safe to add wholesale (`git add app/Kalam/Settings/<file>`); `SettingsUI.swift` deletions use the deterministic hunk-extraction method (awk `index()` match on `@@` headers, `git apply --cached --recount`, verify `git diff --cached` shows ONLY your hunks) — or commit the whole file only if `git status` shows it clean of sibling edits at that moment.
   - Re-check `git status` + `git log --oneline -5` before starting and before each commit; re-read `SettingsUI.swift`'s current anchors before every cut.
   - `error: fsmonitor_ipc__send_query: unspecified error` is cosmetic on this mount — ignore it. `.git/index.lock` present? `rm -f .git/index.lock` and re-check status.
6. **VirtIOFS transient-unreadable race:** if `read_file`/grep report "No such file" on a file `ls` shows with real size, read the index copy (`git show :0:./app/Kalam/SettingsUI.swift`) — the race clears on its own; re-read the working tree before editing.
7. **Do not touch** `KalamApp.swift` (its `SettingsView`/`SettingsView.SettingsTab` API is unchanged by this work), `KalamTheme.swift`, `KalamControlStyles.swift`, `SettingsConfiguration.swift`, `ModelsConfiguration.swift`, `ModelSetupSupport.swift`, `CustomDictionaryManager.swift`, `OnboardingFlow.swift`, the engine package, or any test file.
8. **K-21 (window sizing 750 vs 900) is out of scope** — do not "fix" `KalamApp.swift:341–343`/`353` while here.

---

## Current state (verified 2026-08-11, working tree)

`app/Kalam/SettingsUI.swift` = 2,154 lines. Type map with anchors:

| Lines (WT) | Anchor string | Member | New home |
|---|---|---|---|
| 1–5 | `import AppKit` … | imports | per-file (compiler is the arbiter) |
| 8–1324 | `struct SettingsView: View {` … (closes 1324) | shell | **stays** in `SettingsUI.swift` |
| 11–13 | `private enum Metrics` | `pickerWidth` (used only by `indicatorPlacementRow`) | `GeneralSettingsTab.swift` |
| 16–45 | `enum SettingsTab: CaseIterable` | tabs enum | **stays** (nested; KalamApp.swift:334) |
| 47–68 | `// MARK: - State Properties` | `@State` inventory (see state table below) | split per state table |
| 71–76 | `var selectedShortcutLabel` | hotkey label (used only at :578) | `ShortcutSettingsTab.swift` |
| 78 | `@State … selectedDownloadVersion` | model version picker (used :851/:856) | `ModelsSettingsTab.swift` |
| 80–88 | `downloadCommand(for:)` / `copyToClipboard(_:)` | (used only in `modelsContent` :825/:856/:872) | `ModelsSettingsTab.swift` |
| 90–106 | `@ViewBuilder private var mainContent` | tab switch | **stays** (rewired per task) |
| 108–126 | `rootContent` | split view shell | **stays** |
| 128–137 | `selectedTabBinding` | sidebar binding | **stays** |
| 139–147 | `sidebarNavigation` | sidebar list | **stays** |
| 150–214 | `var body` | sheet/onAppear/onChange/onReceive/alert | **stays**, minus: sheet (→Task 4), alert (→Task 5), `onChange(of: selectedTab)` + `didBecomeActive` branches (→Tasks 3/6) |
| 218–370 | `private var generalContent` | General tab UI | `GeneralSettingsTab.swift` |
| 372–437 | `private var updatesContent` | Updates tab UI | `UpdatesSettingsTab.swift` |
| 439–459 | `behaviorToggleRow` | General helper | `GeneralSettingsTab.swift` |
| 461–483 | `indicatorPlacementRow` | General helper | `GeneralSettingsTab.swift` |
| 485–643 | `keyboardControlsContent` | Hotkey tab UI | `ShortcutSettingsTab.swift` |
| 645–663 | `instructionRow` | Hotkey helper | `ShortcutSettingsTab.swift` |
| 665–1031 | `modelsContent` | Models tab UI | `ModelsSettingsTab.swift` |
| 1033–1142 | `refineContent` | Refine tab UI | `CleanupSettingsTab.swift` |
| 1144–1165 | `refineOption` | Refine helper | `CleanupSettingsTab.swift` |
| 1167–1176 | `grammarDescription(for:)` | Refine helper | `CleanupSettingsTab.swift` |
| 1178–1186 | `refreshMicrophoneRows` | General helper (mic list) | `GeneralSettingsTab.swift` |
| 1188–1197 | `syncPriorityConfigFromRows` | General helper (reorder) | `GeneralSettingsTab.swift` |
| 1201–1211 | `applyRecordedShortcut` | Hotkey helper | `ShortcutSettingsTab.swift` |
| 1213–1236 | `onAppear` | config load (all tabs) | **stays** (drop :1223 grammar line → Task 5) |
| 1238–1265 | `persistHotkey/Models/MicrophonePriority…IfNeeded` | persistence | **stays** |
| 1267–1281 | `grammarModeBinding` | Cleanup binding w/ warning | `CleanupSettingsTab.swift` |
| 1283–1285 | `normalizeSelectedModelForAvailability` | Models helper | `ModelsSettingsTab.swift` |
| 1287–1322 | `useParentFolderForSelectedModelRepo` / `chooseModelLibraryFolder` / `openModelLibraryInFinder` / `clearModelLibraryFolder` / `setModelLibraryFolder` | Models folder helpers | `ModelsSettingsTab.swift` |
| 1326–1523 | `private struct ShortcutRecorderSheet` | record-shortcut sheet | `ShortcutSettingsTab.swift` (private) |
| 1527–1718 | `struct WordReplacementView` | Dictionary tab | `WordReplacementView.swift` |
| 1722–1964 | `struct EditableRow` | dictionary row (used only by WordReplacementView) | `WordReplacementView.swift` |
| 1968–2061 | `struct ModelSelectionRow` | models row (used only in `modelsContent`) | `ModelsSettingsTab.swift` |
| 2063–2091 | `private struct MicrophoneRowDropDelegate` | General drag-reorder | `GeneralSettingsTab.swift` (private) |
| 2093–2095 | `extension Notification.Name { selectModelsSettingsTab }` | notification (posted by KalamApp :330/:348) | `SettingsSharedComponents.swift` |
| 2097–2119 | `private struct PreferenceRow<Label, Content>` | Refine row (used only in `refineContent`) | `CleanupSettingsTab.swift` (private) |
| 2121–2147 | `extension View { settingsCardSurface }` | shared card surface (used by ALL tabs) | `SettingsSharedComponents.swift` (`fileprivate`→`internal`) |
| 2149–2154 | `#Preview` | `SettingsView()` preview | **stays** in shell |

### @State inventory — where each piece of state lands

| State (line) | Consumers | New home |
|---|---|---|
| `selectedTab` (48) | shell body/sidebar | **stays** |
| `isInitializingSettingsState` (49) | persist guards | **stays** |
| `showingShortcutRecorder` (50) | sheet (body 152–163) + `keyboardControlsContent` | Shortcut tab |
| `hotkeyDraft` (51) | shell onChange + keyboard tab + sheet | **stays** (Binding to Shortcut tab) |
| `modelsConfig` (52) | shell onChange + Models + Cleanup tabs | **stays** (Binding to both tabs) |
| `generalConfig` (53) | shell onChange + General tab | **stays** (Binding to General tab) |
| `micPriorityConfig` (54) | shell onChange + General tab | **stays** (Binding to General tab) |
| `microphoneRows` (55) | General tab only | General tab |
| `activeInputUID` (56) | General tab only | General tab |
| `showFullGrammarWarning` (57) | alert (202–213) + `grammarModeBinding` | Cleanup tab |
| `previousGrammarModeSelection` (58) | `onAppear`:1223 + alert Cancel | Cleanup tab |
| `step1/2/3Expanded` (59–61) | Models tab only | Models tab |
| `installCommandCopied` / `downloadCommandCopied` (62–63) | Models tab only | Models tab |
| `modelAvailabilityRefreshID` (64) | `.id()` :104 + onChange/didBecomeActive | Models tab |
| `selectedDownloadVersion` (78) | Models tab only | Models tab |

### Cross-file consumers (verified)

- `KalamApp.swift:31–34` — Settings scene: `SettingsView().environmentObject(CustomDictionaryManager.shared)` (API unchanged).
- `KalamApp.swift:323–350` — `openSettingsWindow(selectModelsTab:)`: `SettingsView.SettingsTab` (:334), `SettingsView(initialTab:)` (:335), posts `.selectModelsSettingsTab` (:330/:348). The notification's *tab-switch* job (`selectedTab = .models`) stays in the shell; the *availability refresh* job moves into the Models tab (see Task 6).
- `KalamTests/` — **zero references** to `SettingsView`/`WordReplacementView`/`EditableRow`/`ModelSelectionRow`/`SettingsUI` (grep-verified 2026-08-11). No test churn.
- External types the tabs use (same target, no imports needed): `KalamTheme`/`NoiseView` (KalamTheme.swift:56), `KalamToggleStyle`/`KalamCheckboxStyle`/`KalamSegmentedControl`/`KalamMenuPicker` (KalamControlStyles.swift), `MicrophoneDeviceService` (SettingsConfiguration.swift:111), `ModelSetupSupport`, `ASRModelVersion`/`ASRModelAvailability` (ModelsConfiguration.swift:7,91), `GeneralSettingsConfiguration`/`MicrophonePriorityConfiguration`/`IndicatorPlacementPreset` (SettingsConfiguration.swift), `PTTHotkeyConfiguration`/`PTTHotkeyKey`/`KeyCombination` (PTTHotkeyConfiguration.swift), `CustomDictionaryManager` (CustomDictionaryManager.swift), `ModelsConfiguration` (ModelsConfiguration.swift).
- Engine types (need `import KalamTextEngine` in the new file): `DictionaryEntry` (package `DictionaryEntry.swift:3`) → WordReplacementView file; `TextCleanupGrammarMode` (package `TextCleanupConfiguration.swift:3`) → CleanupSettingsTab file.

### Size targets (sanity check — sum ≈ current 2,154 + headers)

| File | ~Lines |
|---|---|
| `SettingsUI.swift` (shell after all tasks) | 350 |
| `Settings/GeneralSettingsTab.swift` | 200 |
| `Settings/ShortcutSettingsTab.swift` (incl. sheet) | 290 |
| `Settings/CleanupSettingsTab.swift` | 190 |
| `Settings/ModelsSettingsTab.swift` (incl. `ModelSelectionRow`) | 430 |
| `Settings/UpdatesSettingsTab.swift` | 70 |
| `Settings/WordReplacementView.swift` (incl. `EditableRow`) | 245 |
| `Settings/SettingsSharedComponents.swift` | 55 |

---

## Task 0: Pre-flight (5 min)

- [ ] **Step 1: Confirm repo state**
  ```bash
  cd /Volumes/My\ Shared\ Files/GitHub/Kalam
  git status --short
  git log --oneline -5
  ```
  Expected: `main`. Sibling-uncommitted files (`IMPROVEMENT_PLAN.md`, `KalamApp.swift`, `OnboardingFlow.swift`, `OnboardingFlowTests.swift`, …) ride along — **do not stage or revert them**.

- [ ] **Step 2: Baseline build** (proves the starting point is green before any cut)
  ```bash
  ./scripts/test-engine.sh && echo ENGINE_OK
  xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | tail -3
  ```
  Expected: engine 32/32; `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-verify anchors** — `grep -n "private var generalContent\|private var updatesContent\|private var keyboardControlsContent\|private var modelsContent\|private var refineContent" app/Kalam/SettingsUI.swift` matches the type map above (drift check).

## Task 1: Scaffold — `app/Kalam/Settings/SettingsSharedComponents.swift` (5 min)

**Files:**
- Create dir: `mkdir app/Kalam/Settings`
- Create: `app/Kalam/Settings/SettingsSharedComponents.swift`

**Content** (cut verbatim from `SettingsUI.swift`, then one access change):
1. `extension View { settingsCardSurface(cornerRadius:) }` (lines 2121–2147) — change `fileprivate func` → `internal func` (delete the `fileprivate` keyword).
2. `extension Notification.Name { static let selectModelsSettingsTab … }` (lines 2093–2095).
3. Imports: `import SwiftUI` (Color/View); add `import AppKit` only if the compiler demands (it should not — no AppKit symbols here).

**In `SettingsUI.swift`:** delete both blocks (2121–2147 and 2093–2095).

**Verify:** `grep -rn "settingsCardSurface\|selectModelsSettingsTab" app/Kalam --include="*.swift"` → shared file + all original call sites still present. `xcodebuild build … | tail -3` → `** BUILD SUCCEEDED **`.

## Task 2: Extract Updates tab → `Settings/UpdatesSettingsTab.swift` (10 min)

**Create:** `app/Kalam/Settings/UpdatesSettingsTab.swift` — the warm-up task (no state):

```swift
import SwiftUI

struct UpdatesSettingsTab: View {
    var body: some View {
        updatesContent
    }
    // <cut `private var updatesContent` verbatim from SettingsUI.swift:372–437>
}
```

**In `SettingsUI.swift`:**
- Delete `updatesContent` (372–437).
- `mainContent` branch (94–95): `updatesContent` → `UpdatesSettingsTab()`.

**Verify:** `grep -n "updatesContent" app/Kalam/SettingsUI.swift` → no output. Build green.

## Task 3: Extract General tab → `Settings/GeneralSettingsTab.swift` (~25 min)

**Create:** `app/Kalam/Settings/GeneralSettingsTab.swift`:

```swift
import AppKit        // NSApplication (didBecomeActiveNotification)
import SwiftUI
import UniformTypeIdentifiers   // UTType.text (onDrop)

struct GeneralSettingsTab: View {
    @Binding var generalConfig: GeneralSettingsConfiguration
    @Binding var micPriorityConfig: MicrophonePriorityConfiguration

    @State private var microphoneRows: [MicrophoneDeviceDescriptor] = []
    @State private var activeInputUID: String?

    private enum Metrics { static let pickerWidth: CGFloat = 150 }   // from 11–13

    var body: some View {
        generalContent
            .onAppear { refreshMicrophoneRows() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshMicrophoneRows()
            }
    }
    // <cut verbatim: generalContent (218–370), behaviorToggleRow (439–459),
    //  indicatorPlacementRow (461–483), refreshMicrophoneRows (1178–1186),
    //  syncPriorityConfigFromRows (1188–1197)>
}

private struct MicrophoneRowDropDelegate: DropDelegate { … }   // cut verbatim from 2063–2091
```

**In `SettingsUI.swift`:**
- Delete state: `microphoneRows` (55), `activeInputUID` (56).
- Delete: `Metrics` (11–13), `generalContent`, `behaviorToggleRow`, `indicatorPlacementRow`, `refreshMicrophoneRows`, `syncPriorityConfigFromRows`, `MicrophoneRowDropDelegate`.
- `mainContent` branch (92–93): `generalContent` → `GeneralSettingsTab(generalConfig: $generalConfig, micPriorityConfig: $micPriorityConfig)`.
- Body: delete the `didBecomeActive` branch for `.general` (193–201) and the `onChange(of: selectedTab)` branch for `.general` (186–192).

**Behavior note (verified equivalent):** today the shell refreshes mic rows on tab-switch-to-General and on app activation while on General. The tab is only in the view hierarchy when selected, so its own `.onAppear` + `.onReceive(didBecomeActive)` fire in exactly those situations. Parent `onAppear` (config normalization, :1229–1231) fires before child `onAppear` in SwiftUI, so rows are computed from the normalized `micPriorityConfig` — if that ordering ever proves unreliable, add `.onChange(of: micPriorityConfig) { _ in refreshMicrophoneRows() }` in the tab (fallback, not default).

**Verify:** `grep -n "refreshMicrophoneRows\|microphoneRows\|activeInputUID\|Metrics" app/Kalam/SettingsUI.swift` → no output. Build green.

## Task 4: Extract Hotkey tab → `Settings/ShortcutSettingsTab.swift` (~25 min)

**Create:** `app/Kalam/Settings/ShortcutSettingsTab.swift`:

```swift
import AppKit        // NSEvent, PTTHotkeyKey
import SwiftUI

struct ShortcutSettingsTab: View {
    @Binding var hotkeyDraft: PTTHotkeyConfiguration
    @State private var showingShortcutRecorder = false

    var body: some View {
        keyboardControlsContent
            .sheet(isPresented: $showingShortcutRecorder) {
                ShortcutRecorderSheet(
                    initialDisplay: hotkeyDraft.displayString,
                    onCancel: { showingShortcutRecorder = false },
                    onCapture: { key, modifiers in
                        applyRecordedShortcut(key: key, modifiers: modifiers)
                        showingShortcutRecorder = false
                    }
                )
            }
    }
    // <cut verbatim: selectedShortcutLabel (71–76), keyboardControlsContent (485–643),
    //  instructionRow (645–663), applyRecordedShortcut (1201–1211)>
}

private struct ShortcutRecorderSheet: View { … }   // cut verbatim from 1326–1523
```

**In `SettingsUI.swift`:**
- Delete state: `showingShortcutRecorder` (50).
- Delete the `.sheet` modifier from `body` (152–163).
- Delete: `selectedShortcutLabel`, `keyboardControlsContent`, `instructionRow`, `applyRecordedShortcut`, `ShortcutRecorderSheet`.
- `mainContent` branch (98–99): `keyboardControlsContent` → `ShortcutSettingsTab(hotkeyDraft: $hotkeyDraft)`.

**Behavior note:** the sheet's attachment point moves from the shell root to the tab — SwiftUI presents it in the same window; identical UX (the sheet is only reachable from the Hotkey tab either way). The shell's `onChange(of: hotkeyDraft)` persistence handler still runs (binding flows through the shell).

**Verify:** `grep -n "ShortcutRecorderSheet\|keyboardControlsContent\|applyRecordedShortcut\|selectedShortcutLabel\|showingShortcutRecorder" app/Kalam/SettingsUI.swift` → no output. Build green.

## Task 5: Extract Cleanup (Refine) tab → `Settings/CleanupSettingsTab.swift` (~20 min)

**Create:** `app/Kalam/Settings/CleanupSettingsTab.swift`:

```swift
import SwiftUI
import KalamTextEngine      // TextCleanupGrammarMode

struct CleanupSettingsTab: View {
    @Binding var modelsConfig: ModelsConfiguration
    @State private var showFullGrammarWarning = false
    @State private var previousGrammarModeSelection: TextCleanupGrammarMode = .light

    var body: some View {
        refineContent
            .onAppear { previousGrammarModeSelection = modelsConfig.textCleanup.grammarMode }
            .alert("Use Full Grammar Mode?", isPresented: $showFullGrammarWarning) { … }   // verbatim from 202–213
            message: { Text(…) }   // verbatim
    }
    // <cut verbatim: refineContent (1033–1142), refineOption (1144–1165),
    //  grammarDescription (1167–1176), grammarModeBinding (1267–1281)>
}

private struct PreferenceRow<Label: View, Content: View>: View { … }   // cut verbatim from 2097–2119
```

**In `SettingsUI.swift`:**
- Delete state: `showFullGrammarWarning` (57), `previousGrammarModeSelection` (58).
- Delete the `.alert` modifier from `body` (202–213).
- Delete from `onAppear`: line 1223 (`previousGrammarModeSelection = currentModelsConfig.textCleanup.grammarMode`).
- Delete: `refineContent`, `refineOption`, `grammarDescription`, `grammarModeBinding`, `PreferenceRow`.
- `mainContent` branch (100–101): `refineContent` → `CleanupSettingsTab(modelsConfig: $modelsConfig)`.

**Behavior note:** the alert is only triggerable via `grammarModeBinding`'s setter, which moves with the tab; parent `onAppear` (loads `modelsConfig`, :1221–1222) fires before the child's, so the child captures the committed mode. `modelsConfig` save-on-change stays in the shell (`persistModelsConfigurationIfNeeded` unchanged).

**Verify:** `grep -n "showFullGrammarWarning\|grammarModeBinding\|refineContent\|refineOption\|grammarDescription\|PreferenceRow" app/Kalam/SettingsUI.swift` → no output. Build green.

## Task 6: Extract Models tab → `Settings/ModelsSettingsTab.swift` (~35 min — the big one)

**Create:** `app/Kalam/Settings/ModelsSettingsTab.swift`:

```swift
import AppKit        // NSWorkspace (openModelLibraryInFinder), NSAlert (setModelLibraryFolder)
import SwiftUI

struct ModelsSettingsTab: View {
    @Binding var modelsConfig: ModelsConfiguration

    @State private var step1Expanded = false
    @State private var step2Expanded = false
    @State private var step3Expanded = false
    @State private var installCommandCopied = false
    @State private var downloadCommandCopied = false
    @State private var selectedDownloadVersion: ASRModelVersion = .v2
    @State private var modelAvailabilityRefreshID = UUID()

    var body: some View {
        modelsContent
            .id(modelAvailabilityRefreshID)
            .onAppear { modelAvailabilityRefreshID = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                modelAvailabilityRefreshID = UUID()
            }
    }
    // <cut verbatim: modelsContent (665–1031), downloadCommand (80–82),
    //  copyToClipboard (84–88), normalizeSelectedModelForAvailability (1283–1285),
    //  useParentFolderForSelectedModelRepo (1287–1294), chooseModelLibraryFolder (1296–1302),
    //  openModelLibraryInFinder (1304–1307), clearModelLibraryFolder (1309–1311),
    //  setModelLibraryFolder (1313–1322)>
}

struct ModelSelectionRow: View { … }   // cut verbatim from 1968–2061 (may stay internal)
```

**In `SettingsUI.swift`:**
- Delete state: `step1Expanded`/`step2Expanded`/`step3Expanded` (59–61), `installCommandCopied`/`downloadCommandCopied` (62–63), `modelAvailabilityRefreshID` (64), `selectedDownloadVersion` (78).
- Delete: `downloadCommand`, `copyToClipboard`, `modelsContent`, `ModelSelectionRow`, `normalizeSelectedModelForAvailability`, `useParentFolderForSelectedModelRepo`, `chooseModelLibraryFolder`, `openModelLibraryInFinder`, `clearModelLibraryFolder`, `setModelLibraryFolder`.
- `mainContent` branch (102–105): drop `.id(modelAvailabilityRefreshID)`; `.models` → `ModelsSettingsTab(modelsConfig: $modelsConfig)`.
- Body: delete the `didBecomeActive` branch for `.models` (193–201) and the `onChange(of: selectedTab)` branch for `.models` (186–192). **KEEP** `.onReceive(NotificationCenter.default.publisher(for: .selectModelsSettingsTab))` (183–185) — it is what switches the shell to the Models tab when the window already exists (KalamApp.swift:330).

**Behavior notes (verified equivalent):**
- Refresh triggers: today `modelAvailabilityRefreshID` bumps on (a) switching to Models and (b) app activation while on Models. The tab is only in the hierarchy when selected → `.onAppear` and `.onReceive(didBecomeActive)` fire in exactly those situations. Delta: on first-ever open of the tab, today no bump (onChange doesn't fire for initial values) but the fresh view computes availability anyway; with the new code `.onAppear` bumps once — one extra cheap file-exists availability re-eval, harmless.
- `.id(modelAvailabilityRefreshID)` must stay INSIDE the tab's body (applied to `modelsContent`) so the id change still recreates the subtree and re-evaluates `selectedAvailability`/`installedModels` — the whole point of the refresh.

**Verify:** `grep -n "modelsContent\|ModelSelectionRow\|copyToClipboard\|downloadCommand\|step1Expanded\|modelAvailabilityRefreshID\|selectedDownloadVersion" app/Kalam/SettingsUI.swift` → no output; shell still has the `.selectModelsSettingsTab` receive. Build green.

## Task 7: Extract Dictionary tab → `Settings/WordReplacementView.swift` (15 min)

**Create:** `app/Kalam/Settings/WordReplacementView.swift`:

```swift
import SwiftUI
import KalamTextEngine      // DictionaryEntry

struct WordReplacementView: View { … }   // cut verbatim from 1527–1718
struct EditableRow: View { … }           // cut verbatim from 1722–1964
```

**In `SettingsUI.swift`:** delete both structs (1527–1964). `mainContent` branch (96–97) already calls `WordReplacementView()` — **no change** (the `@EnvironmentObject manager` flows from the shell's environment, injected at KalamApp.swift:33/:335).

**Verify:** `grep -n "WordReplacementView\|EditableRow" app/Kalam/SettingsUI.swift` → only the `mainContent` call site. Build green.

## Task 8: Shell polish — `SettingsUI.swift` (15 min)

- Trim imports to what the shell still uses (`AppKit` for `NSApplication`/`NotificationCenter`; drop `UniformTypeIdentifiers`; drop `KalamTextEngine` unless the compiler demands it — `manager.entries` operations reference `DictionaryEntry` only implicitly through `CustomDictionaryManager`).
- Confirm the shell contains only: `SettingsTab` enum, remaining `@State` (6: `selectedTab`, `isInitializingSettingsState`, `hotkeyDraft`, `modelsConfig`, `generalConfig`, `micPriorityConfig`), `init(initialTab:)`, `mainContent` (6 branches), `rootContent`, `selectedTabBinding`, `sidebarNavigation`, `body` (onAppear/onChange ×5/onReceive `.selectModelsSettingsTab`), the four `persist*IfNeeded()`, `#Preview`.
- **Verify:** `wc -l app/Kalam/SettingsUI.swift` ≈ 350; `grep -c "private var\|private func" app/Kalam/SettingsUI.swift` small (≤ ~12); `grep -n "settingsCardSurface" app/Kalam/SettingsUI.swift` → 0 (shared file owns it now). Build green.

## Task 9: Doc sync (required — K-04's contract with AGENTS.md/DEVELOPER_GUIDE.md)

- [ ] **AGENTS.md:41** — replace the `SettingsUI.swift` architecture-map row: shell stays (`SettingsView` orchestration), add a row for `Kalam/Settings/` (per-tab files: General, Hotkey, Cleanup, Models, Updates, Word Replacement, shared card surface). Drop the "(K-04)" marker.
- [ ] **AGENTS.md:85** — "**Add Settings UI** → `SettingsUI.swift` (or split per K-04)" → point at `Kalam/Settings/` + `SettingsSharedComponents.swift`; keep the KalamTheme/KalamControlStyles/K-19 guidance.
- [ ] **DEVELOPER_GUIDE.md:75** — replace the bare `- SettingsUI.swift` bullet with the shell + `Kalam/Settings/` file list (check for any other SettingsUI references in the guide first: `grep -n "SettingsUI\|SettingsView" app/docs/DEVELOPER_GUIDE.md`).
- [ ] **IMPROVEMENT_PLAN.md** — after Task 10 passes: K-04 → `✅`, append a "resolved" changelog entry (per the file's own instructions). (The `🔄` claim flip happens in Task 0.)
- [ ] SECURITY.md: no SettingsUI references (grep-verified) — no change; confirm the grep again in case of drift.

## Task 10: Full verification (the K-04 gate)

1. **Engine untouched:** `./scripts/test-engine.sh` → 32/32 green.
2. **Build:** `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`.
3. **Full suite:** `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → green (module name is `Kalam_test` — no new tests needed; KalamTests has zero settings-type references, verified).
4. **Invariant greps:**
   - `grep -rn "print(" app/Kalam/Settings --include="*.swift"` → no output (no new logging).
   - `grep -rn "URLSession\|http://\|https://" app/Kalam/Settings --include="*.swift"` → no output (no network code).
   - `grep -rn "SettingsView" app/Kalam/KalamApp.swift` → exactly :32, :334, :335 (public API unchanged).
   - `grep -rn "fileprivate" app/Kalam/Settings --include="*.swift"` → only `MicrophoneRowDropDelegate`/`ShortcutRecorderSheet`/`PreferenceRow` if kept private (no accidental leaked fileprivate in shared code).
5. **Manual smoke — every tab (the K-04 verify):**
   - **General:** toggles persist after relaunch; mic priority drag-reorder persists; indicator-placement picker; "Run Setup Again…" opens onboarding.
   - **Hotkey:** activation-mode + key-combination menus; Record Shortcut… sheet captures a combo (e.g. ⌘⇧K), ESC cancels; change persists after relaunch; push-to-talk still fires from the menu bar.
   - **Cleanup:** enable-pipeline toggle; each rule toggle; grammar segmented control; selecting **Full** shows the warning alert → Cancel restores the previous mode, OK applies.
   - **Models:** Step 1 choose/clear folder + Open in Finder; Step 2 copy install + download commands (Copied! feedback); Step 3 model row selection; Setup-Required banner; switch away and back → availability re-evaluates.
   - **Dictionary:** add/edit/delete/search/sort; Smart vs Literal matching; example matches update; entries persist across relaunch.
   - **Updates:** installed version string; "View Latest Release…" opens the browser.
   - **Window plumbing:** menu-bar Settings opens the window; "Models" entry point from onboarding/setup flow lands on the Models tab (exercises `.selectModelsSettingsTab` + `SettingsView(initialTab:)`).
6. **Commit** (per-task or batched; never `git add -A`): messages like `refactor(K-04): extract <Tab> into Kalam/Settings/<Tab>.swift`; final `docs(K-04): mark K-04 done — tab split implemented + verified (build, full Xcode suite, manual smoke)`.

---

## Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| 1 | **onAppear ordering** (parent vs child): General mic rows need the normalized `micPriorityConfig`; Cleanup's `previousGrammarModeSelection` needs the loaded `modelsConfig`. | Parent `onAppear` fires before child `onAppear` in SwiftUI — the design depends on it. Fallback if observed otherwise: `.onChange(of: micPriorityConfig)` refresh in General; accept one-run staleness for the grammar Cancel restore (only matters mid-session after a Full attempt). |
| 2 | **`.selectModelsSettingsTab` race** (posted right after window presentation may beat view mount) — pre-existing, unchanged. | Not made worse: the shell receive stays; `didBecomeActive` + `onAppear` refreshes in the Models tab carry the load, same as today. |
| 3 | **`settingsCardSurface` visibility widening** (`fileprivate`→`internal`). | Project-wide name is unique (grep before finalizing); it already compiled file-scope with multiple users, so no semantics change. |
| 4 | **Sheet/alert attachment moved** from shell root to tab body. | SwiftUI attaches to the presenting window; both are reachable only from their tab. Manual smoke covers both. |
| 5 | **Sibling edits to `SettingsUI.swift` mid-extraction** (shared repo, concurrent sessions). | Re-read anchors immediately before each cut; per-task `grep` verifies; commit per task so conflicts surface early. |
| 6 | **`.id(modelAvailabilityRefreshID)` placement** — forgetting to re-apply inside the tab would silently break models-tab refresh. | Explicit in Task 6; smoke step "switch away and back" exercises it. |
| 7 | **Accidental capture of shell-only state** (e.g. keeping `microphoneRows` in the shell while the tab also declares it). | Per-task grep of the state-inventory table; compiler flags duplicates; Task 8 line-count check. |
| 8 | **Import drift** (missing `KalamTextEngine` in WordReplacement/Cleanup files). | The compiler is the arbiter; Task 8's import trim happens last. |

## Out of scope (do NOT do here)

- K-21 window sizing (750 vs 900) — explicitly forbidden (Global Constraint 8).
- K-19 accessibility labels — do not add labels while moving code; that is K-19's item.
- K-16 `print()` → Logger in moved code — move verbatim; hygiene is K-16's item (SettingsUI.swift is currently print-free — keep it that way).
- `@Observable`/`ObservableObject` config rearchitecture; per-tab self-loading configs; any tab content/UX redesign; adding per-tab `#Preview`s; renaming `SettingsUI.swift` → `SettingsView.swift` (optional later; the shell keeps its name to minimize diff noise in the shared repo).
- Any change to `KalamApp.swift`, `KalamTheme.swift`, `KalamControlStyles.swift`, config/persistence types, the engine package, or tests.
