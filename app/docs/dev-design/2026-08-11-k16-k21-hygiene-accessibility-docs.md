# K-16 … K-21 Implementation Plan — Priority 5: Hygiene, accessibility & docs

> **For agentic workers:** execute task-by-task; checkboxes track progress. Read `app/docs/IMPROVEMENT_PLAN.md` protocol first (status legend, claim → verify → ✅). Re-verify every line number and re-read each file right before editing — the shared-repo tree drifts (sibling sessions commit on the same `main`; **at plan time `KalamApp.swift`, `OnboardingFlow.swift`, `.gitignore`, `OnboardingFlowTests.swift`, `Kalam.xcscheme`, `.github/workflows/deploy-kalam-landing.yml`, `landing-page/package*.json` carry uncommitted sibling hunks; untracked: `Models/`, `app/.grok/`, `app/.hermes/`, `app/Kalam/Assets.xcassets/AppIcon.appiconset copy/`, `hermes-verify-k10-*.log`**). Run all commands from the repo root `/Volumes/My Shared Files/GitHub/Kalam`. Do not `git add -A`; stage only your hunks. `error: fsmonitor_ipc__send_query …` on commit is cosmetic on this mount. If `read_file`/`search_files` misreport on the mount, use `ls` (terminal) and `git show :0:./<path>` (index copy).

**Goal:** Close Priority 5 of `app/docs/IMPROVEMENT_PLAN.md`:

- **K-16** — remove the debug leftover + convert the remaining raw `print()` calls to `Logger` (9 sites across 4 files).
- **K-17** — fix `app/docs/DEVELOPER_GUIDE.md` drift: stray pasted paragraph, list numbering; re-audit the original `TextCleanupConfiguration` claim (already resolved — see Current state).
- **K-18** — gitignore `.grok/` and `.hermes/` session-artifact dirs.
- **K-19** — accessibility: label icon-only buttons, expose the hotkey dropdown to VoiceOver, add keyboard paths to onboarding, and a 🧑 VoiceOver / Full Keyboard Access gate.
- **K-20** — dictionary data-loss edges: imported `userAdded == false` entries dropped on relaunch; corrupt `user_dictionary.json` silently resets with no backup/notice. Fix both, with tests behind a new injectable-storage seam.
- **K-21** — unify the settings window width (created at 750, then min/max set to 900 → inconsistent).

**Approach:** six independent tasks, each with its own commit; recommended execution order is the part order (A → F), K-20 (Part E) is TDD (seam → RED → fix → GREEN), K-19 (Part D) is audit-driven and ends in a 🧑 human gate. No new dependencies anywhere (OSLog is system); no network code; no entitlements.

**Test commands (from repo root):**

```bash
# Build
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
# Targeted new tests (K-20)
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/CustomDictionaryManagerTests CODE_SIGNING_ALLOWED=NO
# Full suite
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
# Engine sanity (untouched by this plan)
./scripts/test-engine.sh        # expect 41 green
```

## Global Constraints

- **No network code, no new entitlements, no new dependencies.** OSLog is a system framework; nothing else is added.
- **Never log transcript or audio content; Logger only, with `privacy: .public` on counts/timings/metadata.** K-16 converts prints to Logger — device names and hotkey strings are metadata (like the model versions already logged), NOT transcript content; UIDs and error descriptions stay `.private`/summary-only.
- **Tree stays buildable at every commit.** K-20's RED is a *runtime* RED (the storage seam compiles and does not change behavior), so the shared tree is never broken — unlike K-09/K-12's compile-failure REDs.
- **Behavior preservation is the K-19/K-21 contract.** Only the AX surface and the window width change; no layout, copy, or pipeline changes.
- **Concurrent-session rules (shared VirtIOFS):** `KalamApp.swift` (Part F), `OnboardingFlow.swift` (Parts A/D) and `.gitignore` (Part C) are dirty at plan time. Re-read each right before editing; if a sibling commits first, re-base your hunk on the committed text. `IMPROVEMENT_PLAN.md` and `app/docs/DEVELOPER_GUIDE.md` are clean at plan time — re-check before editing.
- **Line numbers below verified 2026-08-11** against the working tree at HEAD `3ec5f90`. Re-locate before editing.

---

## Current state (verified 2026-08-11, HEAD `3ec5f90`)

### K-16 — `print()` audit (all 9 sites confirmed; `KalamApp.swift` print-free since K-03, `AppRelauncher` since K-12)

| File | Lines | Content |
|---|---|---|
| `app/Kalam/OnboardingFlow.swift` | 513–530 | `#if DEBUG` block: `resetAllOnboardingState()` with `print("\n[DEBUG] RESETTING ONBOARDING STATE")` (516) + multi-line tccutil-instructions `print("""…""")` (521–529). **This is the debug leftover.** |
| `app/Kalam/AccessibilityHelper.swift` | 17, 24–29 | `print("Accessibility: trusted = true")`; multi-line explainer `print("""…""")` |
| `app/Kalam/SettingsConfiguration.swift` | 211, 217–223, 226, 395 | `logDefaultInputDeviceSummary()` — error print, multi-line device block (name/UID/channels/SR/Logitech flag), non-fatal notice, `-10877` notice |
| `app/Kalam/Services/HotkeyListener.swift` | 37, 52 | `print("Hotkey registered: …")` (both branches) |

`KalamTestRunner.swift` prints are **intentional** (special-mode harness — keep). No `Logger` exists yet in any of the four files (verified by grep); the app convention is `Logger(subsystem: "singhkays.Kalam", category: "<CamelCase>")` (see `CustomDictionaryManager.swift:13`, `KalamApp.swift:74`).

### K-17 — DEVELOPER_GUIDE drift (finding partially already resolved)

- **Stray paragraph:** `app/docs/DEVELOPER_GUIDE.md:258` — `What's the challenge we are finding with this issue and then why are we not able to fix it? Let's take a problem and solve it.` sits between the `grammarMode = full` example (257) and the `grammar protected terms` heading (261). (Drifted from the plan's `:249`.)
- **Original second half (stale `TextCleanupConfiguration` ref) is RESOLVED:** the guide now points at the package (`:79` lists `Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift / TextCleanupConfiguration.swift`), the package **does** contain `TextCleanupConfiguration.swift` (verified with `ls`), and `grep TextCleanupService app/docs/DEVELOPER_GUIDE.md` → 0 hits. **No action needed** — record this re-audit in the tracker note.
- **New drift found during read-through (in scope as a sweep):** the "Model Setup → Quick Setup" list (316–350) numbers two items "2." (`2. **Step 1: Choose a model folder**` and `2. **Download a model**`) then `3. **Select the model**` — should be 2/3/4. Optional sweep items: duplicated `AppKit` entry in the frameworks list (377 vs 382) and "Xcode 16.x recommended" (470) is stale vs the K-22 CI pin (`setup-xcode '26.6'`).

### K-18 — session artifacts untracked

`.gitignore` (lines 38–44, "# AI Agent Specific" block) has `.agents/`, `.gemini/`, `.brain/` but **no** `.grok/`/`.hermes/`; `git status` shows `?? app/.grok/` and `?? app/.hermes/` (the latter holds `desktop-attachments/`). **`.gitignore` itself is dirty (sibling hunks) — re-read before editing.**

### K-19 — accessibility (evidence re-verified + one bonus finding)

- App-wide `.accessibilityLabel` count is **2** (as claimed): `ModelAcquisitionPanel.swift:190` (copy button — already good) and `CommandCopyRow.swift:103` (already good).
- `SetupDropdownField.swift:25` — `.accessibilityHidden(true)` on the chevron only; the `Menu` (`.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)`, lines 9–41) is the actual AX gap: it may expose no pop-up-button role/label. Used by the onboarding hotkey step (`OnboardingFlow.swift:1020, 1041`), the model wizard (`ModelAcquisitionPanel.swift:120`), and `ModelsSettingsTab.swift:216`.
- **Bonus:** `ModelAcquisitionPanel.swift:271` — `.accessibilityHidden(true)` on `stepBadge` (decorative number/checkmark circle). This one is **correct** (decorative element) — keep, and document as intentional.
- Icon-only buttons missing labels (all `.buttonStyle(.plain)` + `.help()` only — `.help` is hover-only, not announced by VoiceOver): `WordReplacementView.swift:93` (plus/"Add rule"), `:104` (sort/"Sort by spoken phrase"), `:279` (trash/"Delete rule"). `ModelAcquisitionPanel.swift:183` copy button is already labeled (190).
- `ShortcutSettingsTab.swift:69, 124` — two chevron images inside Menu labels NOT `.accessibilityHidden(true)` (inconsistent with `SetupDropdownField`).
- Onboarding: traffic lights hidden (`KalamApp.swift:489–491`), window `styleMask = [.titled, .closable]` (462) → Cmd+W works but there is **no Esc path**; exactly one `.keyboardShortcut(.defaultAction)` in the app (`OnboardingFlow.swift:761`, "Start Dictating" — keep, do NOT add a second defaultAction). Requirement action buttons go through the `actionButton(_:)` factory (`OnboardingFlow.swift:1245–1266`, used at 1205–1219). `OnboardingView` has an `onClose: () -> Void` stored closure (567–579) wired to window close in `KalamApp.swift:451–453` — ready-made for an Esc binding.

### K-20 — dictionary data loss (both edges confirmed)

- `CustomDictionaryManager.swift:103` — `entries = decoded.filter { $0.userAdded }`: imported entries (`userAdded == false`) survive `importJSON` (76–84 sets `entries = decoded` and saves) but are **silently dropped on next launch**. `userAdded` is `public var` with default `true` (`DictionaryEntry.swift:17`) and its only other consumers are `isFirstLaunch` (`:36`), the Word Replacement "add" path (`WordReplacementView.swift:187`), and `SettingsUI.swift:144` (`removeAll { !$0.userAdded }` — a purge-defaults affordance).
- `CustomDictionaryManager.swift:105–108` — decode failure logs a warning then `entries = []`: **no `.bak`, no notice**. The manager is a hard-wired singleton (`static let shared`, `private init()`, `appSupportURL` computed to the real `~/Library/Application Support/Kalam/user_dictionary.json`); `CustomDictionaryManagerTests` deliberately avoids persistence ("don't want to mess with the shared manager's persistence") — so K-20 needs a storage seam before tests are possible.

### K-21 — settings window width (confirmed, drifted lines)

`KalamApp.swift:331–333` creates the window at `750×640` (setContentSize + minSize + maxSize) **after** `configureSettingsWindow(w)` (329) already set `900×640` min/max (343–355). Net effect: first creation ends up 750 wide with min 750; on **reopen** (315–323) `configureSettingsWindow` re-applies min/max 900 to the 750-wide window → `minWidth(900) > currentWidth(750)`, clamped on the next resize. The 750 literals are dead-wrong for the post-K-04 tabbed shell (designed at 900).

---

# Part A — K-16: `print()` → `Logger`

**Files:** modify `OnboardingFlow.swift`, `AccessibilityHelper.swift`, `SettingsConfiguration.swift`, `Services/HotkeyListener.swift` (all clean except `OnboardingFlow.swift` — re-read first). No new tests (logging-only); verification is a grep + build.

## Task 1: `OnboardingFlow.swift` — debug leftover + reset logs

- [ ] **Step 1: Re-read `OnboardingFlow.swift` (dirty — sibling hunks).** Locate the `#if DEBUG` `resetAllOnboardingState()` block (~513–530). Replace both prints with Logger calls; the function itself stays (DEBUG-only dev affordance; deletion is optional and NOT required — the finding's "debug leftover" is the raw print noise, which the conversion removes):

```swift
    #if DEBUG
    func resetAllOnboardingState() {
        logger.info("Onboarding state reset (DEBUG-only)")
        OnboardingConfiguration.reset()

        // Provide TCC instructions
        let bundleID = Bundle.main.bundleIdentifier ?? "singhkays.Kalam"
        logger.info("To fully reset system permissions, run tccutil reset Microphone \(bundleID, privacy: .public) and tccutil reset Accessibility \(bundleID, privacy: .public)")
        refreshAction()
    }
    #endif
```

- [ ] **Step 2: Add the logger to `OnboardingFlowController`** (`final class OnboardingFlowController: ObservableObject`, line 319) — next to its other stored properties, and add `import OSLog` at the top of the file (check current imports first):

```swift
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "Onboarding")
```

## Task 2: `AccessibilityHelper.swift` — trusted/explainer logs

- [ ] **Step 1: Rewrite the file's prints** (add `import OSLog`; the file currently imports only `ApplicationServices`):

```swift
enum AccessibilityHelper {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "Accessibility")

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            explainAccessibilityIfNeeded()
        } else {
            logger.info("Accessibility trusted")
        }
        return trusted
    }

    static func explainAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        logger.info("Accessibility not enabled — enable Kalam in System Settings → Privacy & Security → Accessibility, then relaunch")
    }
}
```

(One-line info log replaces the console-targeted multi-line block; `Logger` renders as a single line anyway.)

## Task 3: `SettingsConfiguration.swift` — device-summary logs

- [ ] **Step 1: Add `import OSLog` and a static logger** (the file imports Foundation/AppKit/CoreAudio/AudioToolbox today). `logDefaultInputDeviceSummary()` is a `static` func, so the logger is static:

```swift
private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioDevice")
```

- [ ] **Step 2: Replace the four print sites** (211, 217–223, 226, 395):

```swift
        } catch {
            logger.error("Failed to query default input device domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            info = nil
        }
        if let info = info {
            let isLogitech = info.name.localizedCaseInsensitiveContains("logitech") ||
                info.name.localizedCaseInsensitiveContains("c920")
            logger.info("Input device name=\(info.name, privacy: .public) channels=\(info.inputChannels) sampleRate=\(info.nominalSampleRate) logitech=\(isLogitech)")
        } else {
            logger.info("Could not query input device details (non-fatal, proceeding with defaults)")
        }
```

and at the `-10877` site (395):

```swift
            if status == -10877 {
                logger.info("Non-fatal invalid property (-10877) for input channels; assuming default (2)")
                return 2
            }
```

> **Privacy note:** the device **UID is dropped** (it identifies a hardware device — keep it out of logs); name/channels/SR are metadata on the user's own machine, `.public` like the model-version logs elsewhere. Error text goes through `domain#code` (the `privacySafeErrorSummary` pattern from `CustomDictionaryManager.swift:5–8`).

## Task 4: `Services/HotkeyListener.swift` — registration logs

- [ ] **Step 1: Add `import OSLog` and a logger** (`HotkeyListener` is a class — instance property):

```swift
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "Hotkey")
```

- [ ] **Step 2: Replace lines 37 and 52:**

```swift
            logger.info("Hotkey registered \(safeConfiguration.keyCombination.displayName, privacy: .public)")
```

```swift
        logger.info("Hotkey registered \(safeConfiguration.displayString, privacy: .public)")
```

(Key-combo strings are counts/timings-class metadata, not transcript content.)

## Task 5: Verify + commit

- [ ] **Verify:** `grep -rn 'print(' app/Kalam --include='*.swift'` → only `KalamTestRunner.swift` remains. Build green. Engine untouched (`./scripts/test-engine.sh` still 41/41 — cheap sanity).
- [ ] **Commit** (if `OnboardingFlow.swift` has sibling hunks, stage only yours — awk-extract per the `kalam-app-development` skill, or commit the other three files first and flag the OnboardingFlow hunk):

```bash
git add app/Kalam/OnboardingFlow.swift app/Kalam/AccessibilityHelper.swift app/Kalam/SettingsConfiguration.swift app/Kalam/Services/HotkeyListener.swift
git commit -m "chore(K-16): replace raw print() with Logger; remove debug-print leftover"
```

---

# Part B — K-17: DEVELOPER_GUIDE drift

**Files:** modify `app/docs/DEVELOPER_GUIDE.md` (clean at plan time). Docs-only; no build needed beyond a read-through.

## Task 1: Remove the stray paragraph

- [ ] **Step 1: Re-read the guide around 250–262.** Delete line 258 (`What's the challenge we are finding with this issue and then why are we not able to fix it? Let's take a problem and solve it.`) — it sits between the `grammarMode = full` output block and the `grammar protected terms` heading.

## Task 2: Fix the Model Setup list numbering (316–350)

- [ ] **Step 1: Renumber `2. **Step 1: Choose a model folder**` → keep as item 2, change `2. **Download a model**` → `3. **Download a model**`, and `3. **Select the model** (Settings → Models → Step 3)` → `4. **Select the model** (Settings → Models → Step 3)`.

## Task 3: Optional sweep (do if trivial; otherwise record as follow-up)

- [ ] Frameworks list: `AppKit` appears at 377 and 382 — merge the `NSSpellChecker` note into the 377 entry and delete 382.
- [ ] `Xcode 16.x recommended` (470) → `Xcode 16.0 or newer (CI runs Xcode 26.6)`, matching the K-22 pin.
- [ ] Full read-through for anything else stale (the finding's verify step is literally "read-through of the guide").

## Task 4: Verify + commit

- [ ] **Verify:** `grep -n 'TextCleanupService' app/docs/DEVELOPER_GUIDE.md` → 0 hits; `grep -n 'TextCleanupConfiguration' app/docs/DEVELOPER_GUIDE.md` → exactly the valid package ref at `:79`; read the diff.
- [ ] **Commit:**

```bash
git add app/docs/DEVELOPER_GUIDE.md
git commit -m "docs(K-17): remove stray paragraph, fix Model Setup numbering, guide sweep"
```

---

# Part C — K-18: gitignore `.grok/` + `.hermes/`

**Files:** modify `.gitignore` (**dirty — re-read first**). No build; verification is `git check-ignore` + `git status`.

## Task 1: Add the ignore entries

- [ ] **Step 1: Re-read `.gitignore`** (sibling hunks possible). Append inside the "# AI Agent Specific (Private Context)" block (after `*.py`, line 44):

```gitignore
.grok/
.hermes/
```

> Unanchored patterns match at any depth, so a single `.grok/` / `.hermes/` covers the repo root **and** `app/.grok/` / `app/.hermes/` (including `app/.hermes/desktop-attachments/`). No need for `app/`-prefixed duplicates — note this in the commit message.

## Task 2: Verify + commit

- [ ] **Verify:**

```bash
git check-ignore app/.grok app/.hermes          # both exit 0 (ignored)
git status --short                               # no ?? app/.grok/ or ?? app/.hermes/
```

- [ ] **Commit:**

```bash
git add .gitignore
git commit -m "chore(K-18): gitignore .grok/ and .hermes/ session-artifact dirs"
```

> **Observations (out of scope — flag to the user, do NOT delete anything):** untracked `Models/` (real model folders for `RealModelSmokeTests` — consider a `.gitignore` entry so `git status` stays clean), `hermes-verify-k10-*.log` (stale verification logs at repo root — safe to delete, but not ours to remove silently), and `app/Kalam/Assets.xcassets/AppIcon.appiconset copy/` (stray asset copy — ask the user whether to delete; it is NOT covered by K-18).

---

# Part D — K-19: accessibility

**Files:** modify `WordReplacementView.swift`, `SetupDropdownField.swift`, `ShortcutSettingsTab.swift`, `OnboardingFlow.swift` (dirty — re-read), `KalamApp.swift` (dirty — only if Task 3's Esc placement lands there; it should not). Ends with a 🧑 VoiceOver gate. No automated tests (AX trees are not unit-testable in this repo's XCTest host); verification = grep + build + Accessibility Inspector + human pass.

## Task 1: Label icon-only buttons

- [ ] **Step 1: `WordReplacementView.swift`** — add `.accessibilityLabel(...)` to the three plain-style icon buttons, matching their existing `.help()` strings (labels: "Add rule" at 93, "Sort by spoken phrase" at 104, "Delete rule" at 279):

```swift
                .buttonStyle(.plain)
                .help("Add rule")
                .accessibilityLabel("Add rule")
```

(and the analogous two). Keep `.help()` — it serves sighted hover users; `.accessibilityLabel` is what VoiceOver announces (`.help` alone is not announced).

- [ ] **Step 2: `ShortcutSettingsTab.swift`** — mark the two chevron images decorative (consistency with `SetupDropdownField`): add `.accessibilityHidden(true)` after `.font(KalamTheme.captionFont)` at lines 69 and 124. The Menu labels' visible text (mode display name / shortcut label) then becomes the clean AX label.
- [ ] **Step 3: Sweep for more icon-only buttons** (audit candidates; label any that are interactive):

```bash
grep -rn 'Image(systemName' app/Kalam --include='*.swift' | grep -v KalamTestRunner
```

Known-safe (do NOT touch): `ModelAcquisitionPanel.swift:271` (`stepBadge` — decorative, already hidden), `SetupDropdownField.swift:25` (chevron — decorative, already hidden), `GeneralSettingsTab.swift:98` (drag handle inside a row), empty-state/status icons (`WordReplacementView.swift:125, 373`; `OnboardingFlow.swift:948, 979, 1059, 1185` are inside text-bearing rows/buttons — verify VoiceOver reads the accompanying Text, hide the icon if it's announced redundantly). Audit specifically: `WordReplacementView.swift:77` (xmark.circle.fill — if it's a Button, label it "Clear search").

## Task 2: Expose the hotkey dropdown (SetupDropdownField)

- [ ] **Step 1: `SetupDropdownField.swift`** — add an explicit AX label + hint on the `Menu` (the visible selection text becomes the label; the chevron stays hidden):

```swift
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // K-19: expose the control to VoiceOver as a labeled pop-up button.
        .accessibilityLabel(Text(label(selection)))
        .accessibilityHint("Opens a menu of options.")
```

- [ ] **Step 2: Verify with Accessibility Inspector** (Xcode → Open Developer Tool → Accessibility Inspector, target the running app): the dropdowns on the onboarding hotkey step, the model wizard, and Models settings must appear as focusable pop-up buttons whose value/name = current selection, and be reachable by Tab + Space/Return (Full Keyboard Access on).
- [ ] **Fallback if the role stays flat:** switch to `.menuStyle(.button)` (the style `ShortcutSettingsTab` already uses, which exposes a standard menu-button role) — visually re-check the label capsule (`.button` adds a bezel; adjust padding/background if it looks different) and note the trade-off in the commit message. Only take this path if the Inspector shows no pop-up role after Step 1.

## Task 3: Onboarding keyboard paths

- [ ] **Step 1: Esc closes the wizard.** `OnboardingView` already stores `onClose` (567–579; wired to `onboardingWC?.window?.close()` in `KalamApp.swift:451–453`). On the root container of `OnboardingView.body` (line 583+), add:

```swift
        .onExitCommand(perform: onClose)
```

This is the discoverable close path now that traffic lights are hidden (`KalamApp.swift:489–491`). Cmd+W already works (`styleMask = [.titled, .closable]`, 462). Do NOT add a visible close button (design decision — onboarding is a deliberate, distraction-free flow; Esc + Cmd+W cover keyboard, the "Quit Kalam" menu item covers mouse).

- [ ] **Step 2: Keep exactly one `.keyboardShortcut(.defaultAction)`** ("Start Dictating", 761). Do NOT add `.defaultAction` to the per-requirement `actionButton(_:)` variants (1245–1266) — multiple default-action buttons in one window are ambiguous. Their keyboard path is Tab-focus + Space/Return, which SwiftUI buttons get by default with Full Keyboard Access on.
- [ ] **Step 3: Audit the Option-key-sensitive control** (781–799 — a modifier-press reveal; verify what it does: if it's the DEBUG reset affordance, confirm it stays `#if DEBUG`-gated and add `.accessibilityHidden(true)` if it's not keyboard-reachable; if it's user-facing, it needs a keyboard path or a label).

## Task 4: Verify + 🧑 gate

- [ ] **Automated:** build green; `grep -rn 'accessibilityLabel' app/Kalam --include='*.swift'` count grows by ≥4 (3 WordReplacementView + 1 SetupDropdownField; ShortcutSettingsTab chevrons don't add labels); `grep -c '.accessibilityHidden(true)' app/Kalam/Settings/ShortcutSettingsTab.swift` = 2.
- [ ] **🧑 Human gate (required for ✅):** on a real Mac (this VM's VoiceOver is not representative):
  1. VoiceOver pass over **Settings** (all tabs): every button announces a name; the Activation/Hotkey dropdowns announce current selection; Word Replacement add/sort/delete announce their actions; no "unlabeled" announcements.
  2. VoiceOver pass over **Onboarding** (fresh-state launch): each step's action buttons and the two hotkey dropdowns are reachable and announced; Esc closes the window.
  3. **Full Keyboard Access** pass: Tab order reaches every interactive control in Settings and Onboarding; Space/Return activates; Esc closes onboarding.
  4. Accessibility Inspector: hotkey dropdowns show role "pop-up button" (or the documented fallback).
- [ ] **Commit** (flag if `OnboardingFlow.swift` hunks entangle with a sibling's):

```bash
git add app/Kalam/Settings/WordReplacementView.swift app/Kalam/SetupDropdownField.swift app/Kalam/Settings/ShortcutSettingsTab.swift app/Kalam/OnboardingFlow.swift
git commit -m "feat(K-19): accessibility labels, hotkey dropdown AX exposure, onboarding Esc path"
```

---

# Part E — K-20: dictionary data-loss edges (TDD)

**Files:** modify `CustomDictionaryManager.swift`, `Settings/WordReplacementView.swift`; modify `KalamTests/CustomDictionaryManagerTests.swift` (all clean at plan time). Three new tests; RED is a runtime failure (the seam compiles and preserves behavior).

## Task 1: Injectable storage seam (buildable, behavior-preserving)

- [ ] **Step 1: `CustomDictionaryManager.swift`** — replace `private init()` with an overridable store URL; the singleton and all production call sites stay source-compatible:

```swift
@MainActor
final class CustomDictionaryManager: ObservableObject {
    static let shared = CustomDictionaryManager()

    @Published var entries: [DictionaryEntry] = []

    /// Set when `user_dictionary.json` exists but fails to decode; the corrupt
    /// file is preserved as `user_dictionary.json.bak` before the store resets.
    @Published var loadFailureNotice: String?

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")
    private let storeURLOverride: URL?

    init(storeURL: URL? = nil) {
        self.storeURLOverride = storeURL
    }

    private var appSupportURL: URL {
        if let storeURLOverride { return storeURLOverride }
        let fm = FileManager.default
        let appName = "Kalam"
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }
```

(`static let shared` still resolves via the default `nil` argument. `@testable import Kalam_test` grants tests access to the internal `init(storeURL:)`.)

- [ ] **Step 2: Build** — must succeed, no behavior change.

## Task 2: RED tests (runtime failures against current behavior)

- [ ] **Step 1: Append to `app/KalamTests/CustomDictionaryManagerTests.swift`** (existing tests are unaffected; helper creates an isolated temp store per test):

```swift
    // MARK: - K-20 persistence edges

    private func makeIsolatedManager() throws -> (CustomDictionaryManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamDictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("user_dictionary.json")
        return (CustomDictionaryManager(storeURL: store), store)
    }

    func testImportedEntriesSurviveRelaunch() throws {
        let (manager, store) = try makeIsolatedManager()
        let importURL = store.deletingLastPathComponent().appendingPathComponent("import.json")
        let imported = DictionaryEntry(trigger: "kalam", replacement: "Kalam",
                                       caseInsensitive: true, preserveCase: false, userAdded: false)
        try JSONEncoder().encode([imported]).write(to: importURL)

        try manager.importJSON(from: importURL)
        XCTAssertEqual(manager.entries.count, 1)

        // Simulate relaunch: a fresh manager over the same store file.
        let relaunched = CustomDictionaryManager(storeURL: store)
        relaunched.bootstrap()
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertEqual(relaunched.entries.first?.trigger, "kalam")
        XCTAssertTrue(relaunched.entries.first?.userAdded == true)
    }

    func testCorruptStoreIsBackedUpAndNoticeSet() throws {
        let (manager, store) = try makeIsolatedManager()
        try Data("not json {{{".utf8).write(to: store)

        manager.bootstrap()

        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertNotNil(manager.loadFailureNotice)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.deletingPathExtension().appendingPathExtension("json.bak").path))
    }

    func testHealthyStoreHasNoBackupOrNotice() throws {
        let (manager, store) = try makeIsolatedManager()
        let entry = DictionaryEntry(trigger: "apple", replacement: "orange")
        try JSONEncoder().encode([entry]).write(to: store)

        manager.bootstrap()

        XCTAssertNil(manager.loadFailureNotice)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.deletingPathExtension().appendingPathExtension("json.bak").path))
    }
```

> `DictionaryEntry(trigger:replacement:isEnabled:caseInsensitive:preserveCase:userAdded:)` — full init verified at `DictionaryEntry.swift:19–27`. The `imported.userAdded == true` assertion on the relaunched manager is the fix contract: import is an explicit user action, so imported entries are user-owned by definition.

- [ ] **Step 2: Run targeted tests — expect RED:**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/CustomDictionaryManagerTests CODE_SIGNING_ALLOWED=NO
```

All three fail at runtime against current behavior (filter drops the imported entry; no `.bak`; no notice). Record the failure output as evidence.

## Task 3: Fixes (GREEN)

- [ ] **Step 1: Import marks entries user-owned** — `importJSON` (76–84):

```swift
    func importJSON(from url: URL) throws {
        logger.info("Custom dictionary import started")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        // An explicit import is a user action: imported entries are user-owned,
        // so they must survive the `userAdded` filter on the next launch.
        entries = decoded.map { entry in
            var owned = entry
            owned.userAdded = true
            return owned
        }
        logger.info("Custom dictionary import complete; count=\(self.entries.count)")
        save()
        recompile()
    }
```

(Load filter at `:103` and `isFirstLaunch` at `:36` keep their semantics; `SettingsUI.swift:144`'s purge-defaults affordance still works for hand-edited JSON with `userAdded: false` — note this in the commit message.)

- [ ] **Step 2: Corrupt-store backup + notice** — `load()` (93–108):

```swift
    private func load() {
        let url = appSupportURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            loadFailureNotice = nil
            logger.info("Custom dictionary file missing; starting empty")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            entries = decoded.filter { $0.userAdded }
            loadFailureNotice = nil
            logger.info("Custom dictionary loaded entries=\(decoded.count), userEntries=\(self.entries.count)")
        } catch {
            logger.warning("Custom dictionary load failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            preserveCorruptFile(at: url)
            entries = []
            loadFailureNotice = "Kalam couldn't read your saved dictionary. A backup was kept next to the original file."
        }
    }

    private func preserveCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension().appendingPathExtension("json.bak")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: url, to: backupURL)
            logger.info("Custom dictionary corrupt file preserved as \(backupURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Custom dictionary backup failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }
    }
```

- [ ] **Step 3: Surface the notice in-app** — `Settings/WordReplacementView.swift`, insert a dismissible banner at the top of the tab content (above the search/toolbar row ~85; re-verify the anchor). The view already holds `manager` (`manager.sortEntriesByTrigger()` at 104):

```swift
            if let notice = manager.loadFailureNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.footnote)
                    Spacer()
                    Button("Dismiss") { manager.loadFailureNotice = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(KalamTheme.accent)
                }
                .padding(10)
                .background(KalamTheme.controlTint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
```

(In-app banner per the product rule — surfaces live in the app, never OS notifications. The notice persists on the manager from bootstrap, so it shows whenever the tab is opened; "Dismiss" clears it for the session. Corrupt store → `entries == []` → `isFirstLaunch` becomes true, so the "Your Dictionary is Empty" empty-state appears — now with an explanation and a `.bak` on disk. Documented, intended.)

## Task 4: Verify + commit

- [ ] **Verify:** targeted `CustomDictionaryManagerTests` green (3 new + existing); full suite green; engine 41/41; build green.
- [ ] **Commit** (tests + implementation together — the tree stays buildable at every commit):

```bash
git add app/Kalam/CustomDictionaryManager.swift app/Kalam/Settings/WordReplacementView.swift app/KalamTests/CustomDictionaryManagerTests.swift
git commit -m "fix(K-20): imported entries survive relaunch; corrupt dictionary backed up with in-app notice"
```

---

# Part F — K-21: unify settings window width

**Files:** modify `KalamApp.swift` (**dirty — re-read first**). No new tests (visual); verification = build + manual open/reopen.

## Task 1: One width constant, both paths

- [ ] **Step 1: Re-read `KalamApp.swift` around 300–360** (sibling hunks possible). Add a static constant to `AppDelegate` and use it in both places:

```swift
    // K-21: single source of truth for the settings window width.
    private static let settingsWindowWidth: CGFloat = 900
```

In `configureSettingsWindow` (342–356), replace `let fixedWidth: CGFloat = 900` with `let fixedWidth = Self.settingsWindowWidth`. In the creation path (331–333), replace the 750 literals:

```swift
        w.setContentSize(NSSize(width: Self.settingsWindowWidth, height: 640))
        w.minSize = NSSize(width: Self.settingsWindowWidth, height: 640)
        w.maxSize = NSSize(width: Self.settingsWindowWidth, height: .greatestFiniteMagnitude)
```

> Why 900: the post-K-04 settings shell (sidebar tabs) is designed at 900 (`configureSettingsWindow` already said so); the 750 literals were the pre-K-04 leftover and are what makes first-open (750) disagree with every reopen (900 min/max). Unifying on 900 makes first-open == reopen == the designed width. Do NOT touch `onboardingFrameSize`/`targetFrameSize` (493–494, 537–538) — onboarding is intentionally fixed-size at its own frame.

## Task 2: Verify + commit

- [ ] **Verify:** build green; manual open → window is 900 wide, horizontally non-resizable (min == max), same on reopen (twice: first open and after close/reopen via the menu-bar item). Confirm the tab sidebar and Word Replacement tab render correctly at 900 (this is the width they were designed for).
- [ ] **Commit** (flag if sibling hunks entangle):

```bash
git add app/Kalam/KalamApp.swift
git commit -m "fix(K-21): settings window width unified on 900 via single constant"
```

---

# Part G — tracker update + final commit

- [ ] **Step 1: Re-read `app/docs/IMPROVEMENT_PLAN.md` first** (clean at plan time; a sibling may have edited it since). Flip the six Priority-5 statuses `⬜` → `🔄` (K-16, K-17, K-18, K-19, K-20, K-21).
- [ ] **Step 2: Insert one note AFTER the full Priority-5 table** (before the `---` + "## What looks solid"; do NOT split the table — K-04/K-08/K-09 precedent):

> **K-16..K-21 (2026-08-11):** dev plan authored → `app/docs/dev-design/2026-08-11-k16-k21-hygiene-accessibility-docs.md`. Statuses flipped to `🔄` pending execution. Plan-time re-audit notes: K-16 has 9 `print()` sites (plan said 12 — `KalamApp.swift` and `AppRelauncher` are already print-free via K-03/K-12); K-17's stale-`TextCleanupConfiguration` half is already resolved (guide `:79` points at the package file, which exists — only the stray paragraph + list numbering remain); K-19 has a bonus finding (`ModelAcquisitionPanel.swift:271` decorative hide — correct, keep); K-20 confirmed at `CustomDictionaryManager.swift:103, 105–108` (import + corrupt-reset edges; fix = import marks `userAdded = true`, corrupt file → `.json.bak` + in-app notice, new `storeURL` test seam + 3 tests); K-21 drifted to `KalamApp.swift:331–333` vs `:343–355` (750 vs 900 — unify on 900).

- [ ] **Step 3: Final commit + proof:**

```bash
git add app/docs/IMPROVEMENT_PLAN.md
git commit -m "docs(K-16..K-21): flip Priority 5 to in-progress with plan reference"
git show --stat HEAD           # prove it landed
git status --short             # confirm only expected files remain dirty (sibling hunks)
```

---

## Human gates (🧑) required before any Priority-5 ✅

| Item | Gate |
|---|---|
| K-19 | VoiceOver + Full Keyboard Access pass over Settings (all tabs) and Onboarding; Accessibility Inspector shows pop-up-button role for the dropdowns (Part D Task 4). |
| K-20 | Optional but recommended: corrupt a real `user_dictionary.json` copy, relaunch, confirm the `.bak` appears and the Word Replacement tab shows the banner; dismiss works. |
| K-21 | Visual check: settings opens at 900 wide, consistent across open/reopen. |

## Out of scope (flag, don't fix)

- `Models/` untracked at repo root (RealModelSmokeTests fixture dir) — suggest a `.gitignore` entry separately.
- `hermes-verify-k10-*.log`, `AppIcon.appiconset copy/` — stale artifacts; ask the user before deleting.
- K-11 (workflow pinning) and the remaining Priority-1..4 manual gates — owned by their own plans.
