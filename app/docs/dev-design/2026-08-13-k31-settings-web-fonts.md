# K-31 — Compass settings window: adopt landing-page web fonts (Instrument Serif · Plus Jakarta Sans · IBM Plex Mono)

- **Date:** 2026-08-13
- **Status:** Plan authored — execution pending user approval
- **Tracker:** `IMPROVEMENT_PLAN.md` K-31 (Priority 2 — Architecture)
- **Scope:** Compass settings window ONLY (map + dives). Onboarding, overlay, status-bar chrome stay on system fonts.
- **Spec package:** NOT updated (user decision 2026-08-13) — this plan documents the deviation; `NEW-kalam-settings-redesign` remains the frozen source of truth for layout/types.

---

## 1. Summary

The Compass spec (both v1 and the current NEW revision) locks **system fonts** — New York (serif), SF Pro (sans), SF Mono (mono) — and explicitly bans bundled custom UI fonts (`CompassTokens.swift` "Typography (LOCKED — do not improvise)"; README "Typography (non-negotiable)"). The user's standing agreement, however, is that the product's typography is the landing-page trio — **Instrument Serif**, **Plus Jakarta Sans**, **IBM Plex Mono** (`landing-page/src/styles/fonts.css` imports all three from Google Fonts). The mockups approximate that editorial look with native equivalents; the app should render the real brand families.

This plan adopts the three OFL-licensed web fonts in the Compass window only: vendor them into the app bundle (the app has **no network entitlement** — fonts must ship on disk), register them at launch, and swap the `CompassFont` token layer so every view picks them up without per-view churn.

## 2. Why the spec says system fonts (review finding)

| Evidence | Location | Meaning |
|---|---|---|
| `--sf:-apple-system,"SF Pro Text"…; --ser:ui-serif,"New York"…; --mono:ui-monospace,"SF Mono"…` | `spec/compass-mockups.html:8`, `compass-impl.html:8` (identical in OLD v1 and NEW) | The mockups **render with system fonts** — no Google Fonts import exists anywhere in the spec package. |
| `// MARK: - Typography (LOCKED — do not improvise) … NEVER use … bundled custom UI fonts.` | `NEW…/CompassTokens.swift:37-49` | The spec author deliberately chose system fonts — a native approximation of the landing-page look (New York ≈ Instrument Serif, SF Pro ≈ Plus Jakarta Sans, SF Mono ≈ IBM Plex Mono). |
| `@import url('https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Plus+Jakarta+Sans:ital,wght@0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap')` | `landing-page/src/styles/fonts.css:1` | The **landing page** carries the agreed web-font trio (CDN-loaded in the browser; fine there — the app must bundle). |

**Conclusion:** no one dropped the ball — the two design systems intentionally diverged (web brand vs native approximation). The user's agreement ("web fonts in the HTML mocks") refers to the landing-page design system; the settings mockups were built to *echo* it with system stacks. This plan makes the native app carry the true brand families, per the user's explicit instruction.

## 3. Locked decisions (user, 2026-08-13)

1. **Scope: Compass settings window only.** Onboarding, dictation overlay, and status-menu chrome keep system fonts (separate design systems; not in the redesign contract).
2. **Spec package untouched.** `NEW-kalam-settings-redesign` stays as-is; the "LOCKED — no bundled fonts" rule is overridden for the Compass window by this plan and its execution notes (documented deviation).
3. **Fonts are vendored on disk** (OFL license files included). No runtime fetching — the app has no network entitlement (hard invariant, AGENTS.md).
4. **Exact non-standard weights (560/640) are honored** via the Plus Jakarta Sans variable font (`wght` axis) — no weight snapping.
5. **System-font fallback remains**: if registration fails or a face is missing, `CompassFont` degrades to New York/SF/SF Mono (existing fallback path) — the window never renders tofu.
6. Commit after execution + verification (same policy as K-30), pending confirmation at execution time.

## 4. Font assets

All three families are SIL OFL 1.1 — bundling and redistribution are permitted provided the license text ships with the fonts. Source: `google/fonts` GitHub (raw files, **pinned commit** — record the SHA in execution notes for reproducibility).

| Family | Files (Google Fonts path) | Used for | Weights |
|---|---|---|---|
| Instrument Serif | `ofl/instrumentserif/InstrumentSerif-Regular.ttf` · `InstrumentSerif-Italic.ttf` (+ `OFL.txt`) | `CompassFont.Family.serif` — map hero (32), dive display (30), map-card titles (19/22), map foot (15), model name (20), updates figure (44) | 400 only (family has no bold; spec uses serif at 400 everywhere) |
| Plus Jakarta Sans | `ofl/plusjakartasans/PlusJakartaSans[wght].ttf` (variable, wght 200–800) (+ `OFL.txt`) | `CompassFont.Family.sans` — body, UI chrome, buttons, rows | 400 / 500 / **560** / 600 / **640** via `wght` variation axis |
| IBM Plex Mono | `ofl/ibmplexmono/IBMPlexMono-Regular.ttf` · `-Medium.ttf` · `-SemiBold.ttf` (+ `OFL.txt`) | `CompassFont.Family.mono` — kickers, ranks, states, hotkey symbols, code paths | 400 / 500 / 600 (static faces) |

Approx. size added to the app: **~1.1 MB** (verify at fetch; acceptable for a settings-only change).

**Italic:** Instrument Serif Italic is a real face. The hero emphasis ("Everything is *ready.*") must use `InstrumentSerif-Italic` — no faux `.italic()` synthesis. Add `CompassFont.displayItalic(_:)` and route emphasis sites to it (grep `.italic()` in Compass views during execution).

## 5. Architecture

### 5.1 File layout (new)

```
app/Kalam/Resources/Fonts/            ← vendored TTFs + OFL.txt × 3 (folder reference in Xcode)
app/Kalam/FontRegistration.swift      ← new service (below)
app/KalamTests/FontRegistrationTests.swift  ← new tests
```

Xcode: add the `Fonts` folder as a **folder reference** (blue folder) in the Kalam target's Copy Bundle Resources phase — one `PBXFileReference`, minimal pbxproj churn. Verify post-build: `Contents/Resources/Fonts/*.ttf` present in the product. KalamTests are app-hosted, so `Bundle.main` in tests resolves the app bundle's fonts.

### 5.2 Registration (`FontRegistration.swift`)

```swift
enum FontRegistration {
    /// Returns (registered, failed). Counts only — never log font paths/names.
    @discardableResult
    static func registerBundledFonts() -> (registered: Int, failed: Int) {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"), !urls.isEmpty else { return (0, 0) }
        var registered = 0, failed = 0
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { registered += 1 } else { failed += 1 }
        }
        // Logger: "registered N bundled fonts, M failed" — counts only, privacy: .public
        return (registered, failed)
    }
}
```

Called once from `AppDelegate.applicationDidFinishLaunching` (before any window can open; process-scope registration covers the whole app run). Guard against double registration. Failure is non-fatal → token layer falls back to system fonts.

### 5.3 Token swap (`CompassTokens.swift` — `CompassFont` only)

**Weight-mapping correction (probe-verified 2026-08-13) — do this FIRST in the token file.** The sibling-synced `nsWeight` linear formula `(w−400)/500×0.8` does not match CoreText's trait→wght mapping; the live window renders card headers visibly heavier than the mockup (user report). Headless probe (`/usr/bin/swift` + `NSFontDescriptor` + `fontName` decoding; instance-name hex encodes wght/65536):

| CSS weight | Current formula → rendered | Corrected anchors → rendered |
|---|---|---|
| 500 | trait 0.160 → **476** (lighter) | trait 0.23 → **500** (exact `SFNS-Medium`) |
| 560 | trait 0.256 → **540** | trait 0.272 → **558** |
| 600 | trait 0.320 → **612** | trait 0.30 → **600** (exact `SFNS-Semibold`) |
| 640 | trait 0.384 → **682** (near-bold — the visible "bolder") | trait 0.34 → **634** |
| 700 | trait 0.480 → **780** | trait 0.40 → **700** (exact `SFNS-Bold`) |

Replacement (anchors = `NSFont.Weight` raw values, linear between):

```swift
private static func nsWeight(_ w: CGFloat) -> CGFloat {
    let anchors: [(CGFloat, CGFloat)] = [(400, 0.0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
    let w = min(900, max(100, w))
    for i in 0..<(anchors.count - 1) {
        let (w0, t0) = anchors[i], (w1, t1) = anchors[i + 1]
        if w >= w0 && w <= w1 { return t0 + (w - w0) / (w1 - w0) * (t1 - t0) }
    }
    return anchors.last!.1
}
```

Note: the same buggy formula ships in the spec stub (`NEW…/CompassTokens.swift`); the spec stays untouched per user decision — record in execution notes that the spec copy keeps the old formula until a future spec revision.

Keep the API the sibling-session sync just landed (`variable(_:size:weight:)`, `display/body/mono`, `Family`); replace the system-font implementation with web-font resolution:

- `.serif` → `Font.custom("InstrumentSerif-Regular", size:)`; weight < 500 ⇒ regular (only 400 exists).
- `.sans` → variable font, exact weight:
  ```swift
  guard let base = NSFont(name: "PlusJakartaSans-Regular", size: size) else { return nil }
  let desc = base.fontDescriptor.addingAttributes([.variation: ["wght": weight]])
  return NSFont(descriptor: desc, size: size).map { Font($0) }
  ```
  (verify the `wght` axis key at runtime; if the variation route fails, fall back to nearest static instance via `Font.custom`.)
- `.mono` → static face by weight: `<450` Regular, `<550` Medium, else SemiBold.
- Fallback chain unchanged: web font miss → existing `fallback(_:size:weight:)` (system design fonts).
- Add `displayItalic(size:)` → `Font.custom("InstrumentSerif-Italic", size:)`; route hero/emphasis `.italic()` sites to it.

`CompassType` sizes/tracking/weights stay untouched — they are em-derived and face-agnostic; only visual QA may adjust tracking if a face renders loose (see gates).

### 5.4 Straggler audit (hardcoded `.font(.system(...))` in views)

Convert to `CompassType` styles so nothing in Compass renders SF:

| Site | Current | Action |
|---|---|---|
| `DiveView.swift:43,46` | `.system(12/.semibold)`, `.system(11/.regular)` | new styles (e.g. `styleDiveChromeTitle/Detail`) |
| `MapView.swift:45` | `.system(12/.medium)` | new style |
| `Controls/HotkeyControl.swift:69` | `.system(10/.medium)` | new style |
| `Controls/PrivacyPill.swift:10` | `.system(11/.regular)` | new style |
| `Panes/BeingHeardPane.swift:97,174,185` | `.system(10/.medium)`, `.system(9/.semibold)` ×2 | new styles |
| `Panes/DictionaryPane.swift:88` | `.system(14/.regular)` | new style |

⚠️ These are exactly the files the concurrent sibling session is mid-sync on — **re-read each file immediately before patching** (shared-mount workflow, AGENTS.md).

## 6. Deviations from spec (recorded, user-authorized)

1. **Bundled custom UI fonts in the Compass window** — the spec's "NEVER use bundled custom UI fonts" is overridden for the three brand families (user decision). All other "NEVER" rules (no Inter/Roboto/Helvetica/etc., no `.bold` card headers, no `.title/.headline` text styles) remain in force.
2. **Mockup CSS keeps system stacks** — side-by-side QA compares design intent, not pixels (documented; spec package untouched per user decision).
3. Visual deltas to expect vs the approved mocks: Instrument Serif is finer/more contrasty than New York; Plus Jakarta Sans has a taller x-height than SF Pro; IBM Plex Mono is wider than SF Mono. Tracking constants are em-derived and stay; if a face visibly clips or crowds (e.g. updates figure 44pt, contents 248pt rail), adjust the *point* tracking constant and record it — do not redesign layouts.

## 7. Execution phases

- **P0 — Concurrency checkpoint (mandatory, first).** `git status` + `git log --oneline -3`. The sibling session's NEW-spec sync (14 files, +519/−206, uncommitted at plan time) touches `CompassTokens.swift` and every straggler site. If it is still uncommitted: **`git worktree add -b feat/k31-web-fonts <dir>`** and do all edits there (shared-mount rule: never two agents on one file). Re-read files before every patch.
- **P1 — Vendor fonts.** Fetch the 7 TTFs + 3 OFL.txt from `google/fonts` at a pinned commit; place under `app/Kalam/Resources/Fonts/`; record the SHA. Add the folder reference to the Kalam target (pbxproj). Build; verify `Contents/Resources/Fonts/` in the product.
- **P2 — Registration.** `FontRegistration.swift` + AppDelegate call + logger counts.
- **P3 — Token swap.** Rewrite `CompassFont` implementations (5.3); add `displayItalic`; no `CompassType` changes yet.
- **P4 — Stragglers.** Convert the 8 hardcoded font sites (5.4) to new `CompassType` styles; re-read before each patch.
- **P5 — Tests.** `FontRegistrationTests` (RED→GREEN): registration returns ≥ 7 registered, 0 failed; `NSFont(name: "InstrumentSerif-Regular")` etc. non-nil; variable-weight descriptor resolves 560 and 640 instances without crashing. (No pixel tests — visual gate is manual.)
- **P6 — Docs.** DEVELOPER_GUIDE.md settings section: one line — Compass typography = bundled OFL web fonts, families + `FontRegistration`. Append execution notes to this plan (evidence + SHA + any tracking adjustments + deviation confirmation).
- **P7 — Verify + commit.** Engine suite, full Xcode suite, build; live smoke (open Compass, screenshot map + a dive, confirm faces render); 🧑 gates below; single commit `feat(K-31): …` after user approval.

## 8. Manual gates (🧑)

1. **Visual QA** — Compass map + all six dives: Instrument Serif displays (incl. real italic hero), Plus Jakarta Sans body at 560/640 weights, IBM Plex Mono kickers/states; no clipped ascenders (updates figure 44pt, map hero 32pt), no crowding in the 248pt contents rail or hotkey chips.
2. **Brand echo** — compare against `landing-page` rendering (same families; accept native metrics differences).
3. **Reopen persistence** — close/reopen the settings window: fonts stable (process-scope registration), no system-font flash.
4. **Failure path (optional, dev-only)** — temporarily rename the Fonts folder → window renders New York/SF/SF Mono fallback, no crash, log shows 0 registered.

## 9. Risks & pitfalls

- **Sibling session concurrency (highest risk).** Live `CompassTokens.swift` + 7 view files are being rewritten by another session right now. P0 worktree isolation is mandatory; never trust a stale read (`read_file` dedup can serve stale content on this mount — re-read via terminal if a patch misses).
- **Variable-font weight route.** SwiftUI `.weight()` does not reliably map to a variable `wght` axis; the NSFont-descriptor variation route is the deterministic path. Verify axis key at runtime on macOS 14.6 (deployment target).
- **Faux italic.** Must use the real `InstrumentSerif-Italic` face; `.italic()` on `Font.custom` synthesizes.
- **Font name mismatches.** Use PostScript names (`InstrumentSerif-Regular`, `IBMPlexMono-SemiBold`); verify each face resolves after registration inside tests (P5) — don't trust web naming.
- **No network invariant.** All font loading is bundle-local; the Google Fonts `@import` in `landing-page` is browser-side and out of app scope. Reviewers should flag any `URLSession`/fetch added here.
- **Layout drift.** IBM Plex Mono is ~8–10% wider than SF Mono; watch the contents rail, hotkey chips, and `cp` path line in EnginePane. Tracking constants are the only permitted adjustment lever.
- **OFL compliance.** License files must ship in the bundle alongside the fonts (folder reference copies them).
- **App size** ~+1.1 MB — accepted (documented).

## 10. References

- Landing-page font spec: `landing-page/src/styles/fonts.css`, design brief `landing-page/src/imports/pasted_text/editorial-broadsheet-art-book-.md`
- Spec (frozen, untouched): `app/docs/plans/NEW-kalam-settings-redesign/` — `CompassTokens.swift` (LOCKED typography), README (Typography non-negotiable), `spec/compass-mockups.html` (visual SoT)
- Live token layer: `app/Kalam/Settings/Compass/CompassTokens.swift` (sibling-session NEW-spec sync, uncommitted at plan time)
- K-30 plan: `app/docs/dev-design/2026-08-13-k30-settings-compass-redesign.md`
- Licenses: SIL OFL 1.1 — `ofl/instrumentserif/OFL.txt`, `ofl/plusjakartasans/OFL.txt`, `ofl/ibmplexmono/OFL.txt` (google/fonts, pinned commit)

---

## 11. Execution notes (2026-08-13, machine evidence)

**P0 — Concurrency.** Sibling session's NEW-spec sync was still uncommitted (14 Compass files + tests) → executed in isolated worktree `feat/k31-web-fonts` at `/Volumes/My Shared Files/GitHub/kalam-k31` (snapshot of the main working tree ported via `git diff` + untracked copies). Main tree untouched. Baseline build in the worktree: green.

**P1 — Fonts vendored.** 6 TTF files + 3 OFL licenses at pinned `google/fonts` SHA `73fc2ff52147e34a74804b500cf89ca219eac55d` → `app/Kalam/Resources/Fonts/` (Instrument Serif ×2 static, Plus Jakarta Sans variable `PlusJakartaSans[wght].ttf`, IBM Plex Mono ×3 static). The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **no pbxproj edits needed**; fonts auto-copy, flattened into `Contents/Resources/` (verified in the built product). *Deviation from plan §4: 6 TTFs, not 7* (three families = 2+1+3 files).

**P2 — Registration.** `FontRegistration.swift` (`CTFontManagerRegisterFontsForURL`, `.process`, tolerant of already-registered, counts-only log); called first in `applicationDidFinishLaunching` (`KalamApp.swift:126`). Pre-flight probe confirmed all PostScript names resolve and the `wght` axis (id 2003265652) accepts exact 400–700 requests.

**P3 — Token swap.** `CompassFont.variable` now resolves web faces: serif → Instrument Serif (400), sans → Plus Jakarta Sans variable via `.variation ["wght": w]`, mono → IBM Plex Mono static (400/500/600). `displayItalic` + `styleMapHeroItalic`/`styleDiveDisplayItalic` added; 6 faux-`.italic()` sites converted to the real italic face. `nsWeight` replaced with the probe-verified anchor mapping (plan §5.3 table) — now the degraded fallback path. Header comment rewritten (deviation from the spec's LOCKED rule recorded in code).

**P4 — Straggler audit (plan refinement).** All 9 pre-audited `.font(.system)` sites are **SF Symbol icon sizing** (chevrons, magnifyingglass, grid) or the `✕` chrome glyph — kept on the system font deliberately: SF Symbols require SF to render, and the mockups' icons are SVG equivalents (documented deviation from plan's convert-everything wording). One *real* straggler found beyond the audit: `DictionaryPane.swift` `FlexibleChipRow` used `.fontWeight(.medium)` which the parent `.font()` silently overrode (mockup: `.cv b` = 500) → now explicit `CompassFont.mono(11, weight: wMedium)`.

**P5 — Tests.** `FontRegistrationTests` (5 tests) GREEN: clean registration, all six faces resolve, exact 560/640 on the variable axis, Instrument Serif Italic carries the real italic trait, all three families available. (Test import module is `Kalam_test` in this build config.)

**P7 — Verification pending at note time:** full Xcode suite, engine suite, live AX smoke (fonts render in map + dives), 🧑 visual QA (§8), then commit on user approval.
