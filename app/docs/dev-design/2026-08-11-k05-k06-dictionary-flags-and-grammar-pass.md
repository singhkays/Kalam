# K-05 + K-06 Implementation Plan — Dead Dictionary Flags & Grammar Pass Into the Engine

> **For agentic workers:** execute task-by-task; checkboxes track progress. Read `app/docs/IMPROVEMENT_PLAN.md` protocol first (status legend, claim → verify → ✅). Re-verify every line number and re-read each file right before editing — the shared-repo tree drifts (sibling sessions commit on the same `main`). Run all commands from the repo root `/Volumes/My Shared Files/GitHub/Kalam`.

**Goal:** Kill K-05's dead `wholeWord`/`morphological` dictionary flags (delete, not honor — see Decision below) and move K-06's AppKit grammar pass out of the app shell into `KalamTextEngine` so the app's most fragile code gets headless Swift Testing coverage.

**Architecture:** Two independent changes, both confined to the `KalamTextEngine` package plus a small app-shell cleanup.

1. **K-05:** Remove the two no-op properties from `DictionaryEntry` (they are referenced nowhere in the app, the compiler, or the UI — only by tests that prove they are no-ops). Behavior is unchanged: word rules remain whole-word + suffix-matching unconditionally, exactly as the defaults (`wholeWord: true, morphological: true`) and the README's "morphological matching" copy promise. Tests are rewritten to assert the *unconditional* semantics.
2. **K-06:** Port `TextCleanupService`'s grammar pass (`applyGrammar`, `runGrammar`, `normalizeSentenceStarts`, `isProtectedTerm`, the 1200-char cap) into `TextCleanupEngine.clean` behind `#if canImport(AppKit)`, reusing the engine's existing private `normalizePunctuation` (this deletes the verbatim duplicate). The app-side `TextCleanupService` becomes pure delegation, so it is deleted; the two call sites call `TextCleanupEngine().clean(...)` directly. Grammar tests move from Xcode-only (`KalamTests/TextCleanupServiceTests.swift`) to headless Swift Testing.

**Tech Stack:** Swift 6, SwiftPM (`KalamTextEngine`), AppKit `NSSpellChecker`, NaturalLanguage `NLTokenizer`, Swift Testing (`Testing`), XCTest (app suite), bash (`scripts/test-engine.sh`).

## Global Constraints

- **No behavior change to the cleanup output** for default configs. The pipeline stage order stays: fillers → backtrack → lists → punctuation → grammar (spellcheck → punctuation → sentence starts when `.full`). Grammar runs only when `grammarMode != .off`, is skipped when `text.count > 1200`, and is deadline-bounded by `boundedGrammarTimeoutMs` (25–400).
- **No network code** (hard invariant). `NSSpellChecker` is local system spell-checking — no new entitlements, no network.
- **Never log transcript text** — counts/timings only, `privacy: .public`. The grammar port must not add logging of text.
- **JSON compat:** deleting `wholeWord`/`morphological` from `DictionaryEntry` must not break decoding of existing `user_dictionary.json` files. Synthesized `Codable` ignores unknown keys, so old files with those keys keep decoding; new files simply omit them. Verify with a decode test.
- **Engine test count:** 32 today (24 `TextCleanupEngineTests` + 8 `ReplacementCompilerTests`). After this plan: ~40 headless tests, all green via `./scripts/test-engine.sh`.
- **Headless robustness:** `NSSpellChecker` runs in a bare `swift test` process (no GUI session). The spell server may be slow or absent on the VM. **Every ported grammar test must pass whether or not spell corrections are produced** — assert invariants (protected terms preserved, timeout never empties output, length-skip flags), not exact spell-check rewrites, except where guarded by `grammarTimedOut`.
- **Concurrent-session rules:** the working tree currently has a sibling's uncommitted edits (`KalamApp.swift`, `OnboardingFlow.swift`, …). Re-check `git status` before starting; stage only your hunks (`git add -p` or the awk-extract + `git apply --cached` technique from the `kalam-app-development` skill — never `git add -A`).
- **Folder-synced groups:** deleting `TextCleanupService.swift` / `TextCleanupServiceTests.swift` from disk removes them from the Xcode targets automatically (no pbxproj edits).
- **Module name in app tests is `Kalam_test`** (`@testable import Kalam_test`).

---

## Decision & rejected alternatives (K-05)

**Chosen: delete the flags.** `wholeWord` and `morphological` are referenced by exactly three test files and nothing else — grep confirms zero uses in `ReplacementCompiler`, `SettingsUI`, `CustomDictionaryManager`, or docs' runtime paths. The compiler hardcodes `\b(trigger)('s|’s|s'|es|s)?\b`.

- **Rejected — "honor the flags":** `wholeWord: false` would suddenly enable substring matching (`"car"` → `"truck"` would hit `"carpet"` → `"truckpet"`). No UI creates such entries, so this adds *hidden, surprising* behavior and changes the meaning of any hand-edited JSON that currently decodes but is ignored. For a dictation app, whole-word-only is the safe semantic; substring matching is a footgun.
- **Rejected — "honor + add UI toggles":** feature-surface expansion contradicts the project's trust-over-feature-richness posture, touches `SettingsUI.swift` (a K-04 refactor target), and has no user demand. YAGNI.
- **Net effect:** zero behavior delta; the README's "morphological matching" and the Smart Match popover copy ("handles capitalization, plurals, and possessives") remain true, because suffix + whole-word matching stays unconditional.

---

## Task 1: K-05 — Delete `wholeWord` / `morphological` from `DictionaryEntry` (RED → GREEN)

**Files:**
- Modify: `app/Packages/KalamTextEngine/Sources/KalamTextEngine/DictionaryEntry.swift`
- Modify: `app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/ReplacementCompilerTests.swift`
- Modify: `app/KalamTests/CustomDictionaryManagerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DictionaryEntry` with signature `init(id:trigger:replacement:isEnabled:caseInsensitive:preserveCase:userAdded:)` — no `wholeWord`/`morphological` params. `CompiledRule`, `ReplacementCompiler`, `nonDefaultOptions`, `exampleMatches` unchanged.

- [ ] **Step 1: Delete the dead properties (write the RED)**

In `DictionaryEntry.swift` remove exactly: the `wholeWord` property (line ~10), the `morphological` property (line ~13), the two init params (`wholeWord: Bool = true`, `morphological: Bool = true`), and the two assignments (`self.wholeWord = wholeWord`, `self.morphological = morphological`).

Resulting struct:

```swift
public struct DictionaryEntry: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var trigger: String
    public var replacement: String

    public var isEnabled: Bool = true

    public var caseInsensitive: Bool = true
    public var preserveCase: Bool = true

    public var isPhrase: Bool {
        trigger.contains(where: { $0.isWhitespace })
    }

    public var userAdded: Bool = true

    public init(id: UUID = UUID(),
         trigger: String,
         replacement: String,
         isEnabled: Bool = true,
         caseInsensitive: Bool = true,
         preserveCase: Bool = true,
         userAdded: Bool = true)
    {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.caseInsensitive = caseInsensitive
        self.preserveCase = preserveCase
        self.userAdded = userAdded
    }

    // nonDefaultOptions, exampleMatches: unchanged
}
```

- [ ] **Step 2: Rewrite the two engine tests to assert unconditional semantics**

In `ReplacementCompilerTests.swift`:

`wholeWordEnforcement` (currently pins `wholeWord: false` — the no-op proof):

```swift
@Test func wholeWordEnforcement() {
    // Whole-word matching is unconditional: "car" must never match inside "carpet".
    let entry = DictionaryEntry(
        trigger: "car",
        replacement: "truck"
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "the car is here").0 == "the truck is here")
    #expect(engine.apply(to: "the carpet is here").0 == "the carpet is here")
}
```

`morphologicalSuffixes` (currently pins `morphological: false` — the no-op proof):

```swift
@Test func morphologicalSuffixes() {
    // Suffix matching is unconditional: plurals and possessives always map.
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "orange"
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "apples").0 == "oranges")
    #expect(engine.apply(to: "apple's").0 == "orange's")
}
```

- [ ] **Step 3: Fix the same no-op pins in the Xcode suite**

In `app/KalamTests/CustomDictionaryManagerTests.swift`:

`testMorphologicalSuffixes` — delete `morphological: false` from the `DictionaryEntry(...)` call and replace the comment `// Even if morphological is false, the engine should now enforce it` with `// Suffix matching is unconditional.`

`testWholeWordEnforcement` — delete `wholeWord: false` from the `DictionaryEntry(...)` call and replace the comment `// Even if wholeWord is false, the engine should now enforce it` with `// Whole-word matching is unconditional (never matches inside "carpet").`

(Leave every other line of those tests untouched — assertions stay identical.)

- [ ] **Step 4: Verify RED→GREEN**

```bash
./scripts/test-engine.sh
```
Expected: both rewritten tests pass; all 32 engine tests green. (With the old constructor still compiled, the rewritten tests would fail to compile — so run once before Task 1's edits land if you want to see the RED; the important gate is GREEN after.)

- [ ] **Step 5: JSON compat guard (new engine test)**

Append to `ReplacementCompilerTests.swift`:

```swift
@Test func legacyDictionaryJSONWithDeadFlagsStillDecodes() throws {
    // Pre-K-05 user_dictionary.json files may contain wholeWord/morphological keys.
    // Synthesized Codable ignores unknown keys; old files must keep decoding.
    // (Real files always carry id/isEnabled — only wholeWord/morphological can be absent.)
    let legacy = """
    [{"id": "11111111-1111-1111-1111-111111111111", "trigger": "car", "replacement": "truck", "isEnabled": true, "wholeWord": false, "morphological": false, "caseInsensitive": true, "preserveCase": true, "userAdded": true}]
    """
    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(legacy.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].trigger == "car")
    #expect(entries[0].caseInsensitive)
}
```

- [ ] **Step 6: Commit**

```bash
cd /Volumes/My\ Shared\ Files/GitHub/Kalam
git add -p app/Packages/KalamTextEngine/Sources/KalamTextEngine/DictionaryEntry.swift \
           app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/ReplacementCompilerTests.swift \
           app/KalamTests/CustomDictionaryManagerTests.swift
git commit -m "refactor(K-05): delete dead wholeWord/morphological flags from DictionaryEntry"
```

Verify with `git show HEAD --stat` and `git status` that only your hunks landed.

---

## Task 2: K-06 — Port the grammar pass into `TextCleanupEngine` (headless)

**Files:**
- Modify: `app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift`
- Create (RED, first): `app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupGrammarTests.swift`

**Interfaces:**
- Consumes: `TextCleanupGrammarMode`, `TextCleanupConfiguration.boundedGrammarTimeoutMs`, existing private `normalizePunctuation(in:)`, existing `TextCleanupStats` grammar fields (`grammarAttempted`, `grammarTimedOut`, `grammarSkippedForLength`, `grammarMs`, `grammarEdits` — already present, no stats-type change).
- Produces: `TextCleanupEngine.clean` now performs the grammar stage internally when `configuration.grammarMode != .off`. Signature and return type unchanged. `TextCleanupEngine.isProtectedTerm(_:)` becomes an internal static (was app-side `static func`, now headless-testable via `@testable import`).

- [ ] **Step 1: Write the failing grammar tests first (RED)**

Create `TextCleanupGrammarTests.swift` with the full suite below **before** any engine change. At this point it does not compile (`TextCleanupEngine.isProtectedTerm` doesn't exist yet) and, once that's stubbed, `grammarSkippedForLongTranscripts` and `fullGrammarCapitalizesSentenceStarts` fail — the honest RED.

```swift
import Testing
import Foundation
@testable import KalamTextEngine

private func config(grammarMode: TextCleanupGrammarMode = .off, grammarTimeoutMs: Int = 100) -> TextCleanupConfiguration {
    var c = TextCleanupConfiguration.defaults
    c.grammarMode = grammarMode
    c.grammarTimeoutMs = grammarTimeoutMs
    return c
}

@Test func grammarProtectedTermsStayUntouched() {
    // Holds whether the spell pass runs, times out, or is skipped:
    // protected tokens are never rewritten.
    let result = TextCleanupEngine().clean(
        "this APIKey and GPT4o should stay as is",
        configuration: config(grammarMode: .full, grammarTimeoutMs: 150)
    )
    #expect(result.text.contains("APIKey"))
    #expect(result.text.contains("GPT4o"))
}

@Test func grammarSkippedForLongTranscripts() {
    let long = String(repeating: "this is a long transcript segment ", count: 80)
    let result = TextCleanupEngine().clean(long, configuration: config(grammarMode: .light, grammarTimeoutMs: 100))
    #expect(result.stats.grammarAttempted)
    #expect(result.stats.grammarSkippedForLength)
    #expect(result.stats.grammarEdits == 0)
}

@Test func lightGrammarDoesNotForceSentenceCapitalization() {
    let result = TextCleanupEngine().clean("hello world. also hi there.", configuration: config(grammarMode: .light, grammarTimeoutMs: 150))
    #expect(result.text.hasPrefix("hello"))
    #expect(result.text.contains(". also"))
}

@Test func grammarTimeoutNeverReturnsEmpty() {
    let result = TextCleanupEngine().clean("this should always return content", configuration: config(grammarMode: .full, grammarTimeoutMs: 25))
    #expect(!result.text.isEmpty)
}

@Test func grammarOffIsInert() {
    let result = TextCleanupEngine().clean("hello ,world", configuration: config(grammarMode: .off))
    #expect(!result.stats.grammarAttempted)
    #expect(result.stats.grammarEdits == 0)
}

@Test func fullGrammarCapitalizesSentenceStarts() {
    // NLTokenizer(unit: .sentence) treats all-lowercase prose as ONE sentence
    // (verified: "dog. again" does not split), so use an exclamation boundary,
    // which splits reliably: "hello world! " + "also hi there."
    let input = "hello world! also hi there."
    let result = TextCleanupEngine().clean(input, configuration: config(grammarMode: .full, grammarTimeoutMs: 300))
    if result.stats.grammarTimedOut {
        // Spell server unavailable (e.g. bare swift test on a VM): output must be
        // unchanged and non-empty — never a crash or partial mangling.
        #expect(result.text == input)
    } else {
        #expect(result.text.hasPrefix("Hello "))
        #expect(result.text.contains("! Also"))
    }
}

@Test func isProtectedTermRules() {
    #expect(TextCleanupEngine.isProtectedTerm("APIKey"))    // mixed case
    #expect(TextCleanupEngine.isProtectedTerm("GPT4o"))     // contains digit
    #expect(TextCleanupEngine.isProtectedTerm("HELLO"))     // all caps, >= 2 letters
    #expect(TextCleanupEngine.isProtectedTerm("a") == false)
    #expect(TextCleanupEngine.isProtectedTerm("hello") == false)
    #expect(TextCleanupEngine.isProtectedTerm("openai.com") == true)   // contains "."
}
```

Run and confirm the RED:

```bash
./scripts/test-engine.sh
```
Expected: compile failure (missing `isProtectedTerm`). If it compiles (e.g. a partial port), at minimum `grammarSkippedForLongTranscripts` and `fullGrammarCapitalizesSentenceStarts` must FAIL.

- [ ] **Step 2: Add the AppKit import (guarded)**

At the top of `TextCleanupEngine.swift`, after the existing imports:

```swift
#if canImport(AppKit)
import AppKit
#endif
```

- [ ] **Step 3: Wire the grammar stage into `clean`**

Insert between the punctuation stage and the final trim (current `clean` ends its stages at the `if configuration.punctuation { ... }` block, then does `out = out.trimmingCharacters(...)`):

```swift
        if configuration.grammarMode != .off {
            stats.grammarAttempted = true
            #if canImport(AppKit)
            if out.count > Self.maxGrammarInputCharacters {
                stats.grammarSkippedForLength = true
            } else {
                let stageStart = CFAbsoluteTimeGetCurrent()
                let grammarResult = applyGrammar(
                    in: out,
                    mode: configuration.grammarMode,
                    timeoutMs: configuration.boundedGrammarTimeoutMs
                )
                stats.grammarMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
                stats.grammarTimedOut = grammarResult.timedOut
                if !grammarResult.timedOut {
                    out = grammarResult.text
                    stats.grammarEdits = grammarResult.editCount
                }
            }
            #endif
        }
```

Semantics copied exactly from the current `TextCleanupService.clean`: `grammarAttempted` is set before the length check; a length skip leaves `grammarMs` at 0; a timeout keeps `out` untouched (the partial result is discarded).

- [ ] **Step 4: Port the grammar pass members (verbatim, adjusted visibility)**

Append a new section after the existing private `normalizePunctuation(in:)` (the engine's own, around line 300) — do **not** copy the punctuation regexes again; the grammar pass reuses the engine's `normalizePunctuation`:

```swift
    // MARK: - Grammar pass (AppKit-only)

#if canImport(AppKit)

    private func applyGrammar(in text: String, mode: TextCleanupGrammarMode, timeoutMs: Int) -> (text: String, editCount: Int, timedOut: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + (Double(timeoutMs) / 1000.0)
        let result = runGrammar(text: text, mode: mode, deadline: deadline)
        if result.timedOut {
            return (text, 0, true)
        }
        return (result.text, result.edits, false)
    }

    private func runGrammar(text: String, mode: TextCleanupGrammarMode, deadline: CFAbsoluteTime) -> (text: String, edits: Int, timedOut: Bool) {
        let checker = NSSpellChecker.shared
        let docTag = NSSpellChecker.uniqueSpellDocumentTag()
        let language = Locale.current.identifier
        defer { checker.closeSpellDocument(withTag: docTag) }

        var out = text
        var edits = 0

        let correctionCap = mode == .light ? 12 : 28
        let passCap = mode == .light ? 1 : 2

        for _ in 0..<passCap {
            if CFAbsoluteTimeGetCurrent() >= deadline {
                return (text, 0, true)
            }
            var location = 0
            while location < (out as NSString).length, edits < correctionCap {
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    return (text, 0, true)
                }
                let misspelledRange = checker.checkSpelling(of: out, startingAt: location)
                guard misspelledRange.location != NSNotFound else { break }

                let nsOut = out as NSString
                let originalWord = nsOut.substring(with: misspelledRange)
                if Self.isProtectedTerm(originalWord) {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                let replacement = checker.correction(
                    forWordRange: misspelledRange,
                    in: out,
                    language: language,
                    inSpellDocumentWithTag: docTag
                ) ?? checker.guesses(
                    forWordRange: misspelledRange,
                    in: out,
                    language: language,
                    inSpellDocumentWithTag: docTag
                )?.first

                guard let replacement else {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                if replacement.caseInsensitiveCompare(originalWord) == .orderedSame {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                out = nsOut.replacingCharacters(in: misspelledRange, with: replacement)
                edits += 1
                location = misspelledRange.location + (replacement as NSString).length
            }
        }

        if CFAbsoluteTimeGetCurrent() >= deadline {
            return (text, 0, true)
        }
        let punctuationResult = normalizePunctuation(in: out)
        out = punctuationResult.0
        edits += punctuationResult.1

        if mode == .full {
            if CFAbsoluteTimeGetCurrent() >= deadline {
                return (text, 0, true)
            }
            let sentenceResult = normalizeSentenceStarts(in: out)
            out = sentenceResult.0
            edits += sentenceResult.1
        }

        return (out, edits, false)
    }

    private func normalizeSentenceStarts(in text: String) -> (String, Int) {
        guard !text.isEmpty else { return (text, 0) }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var output = text
        var editCount = 0
        var offsets = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            guard let letterIndex = sentence.firstIndex(where: { $0.isLetter }) else { return true }
            let ch = sentence[letterIndex]
            guard ch.isLowercase else { return true }

            guard let utf16Position = letterIndex.samePosition(in: sentence.utf16) else { return true }
            let utf16Offset = sentence.utf16.distance(from: sentence.utf16.startIndex, to: utf16Position)
            let nsRangeOriginal = NSRange(range, in: text)
            let nsLocation = nsRangeOriginal.location + utf16Offset + offsets
            let replaceRange = NSRange(location: nsLocation, length: 1)

            let nsOutput = output as NSString
            let replacement = String(ch).uppercased()
            output = nsOutput.replacingCharacters(in: replaceRange, with: replacement)
            editCount += 1
            offsets += (replacement as NSString).length - 1
            return true
        }

        return (output, editCount)
    }

    /// True when the token must never be rewritten by the grammar pass:
    /// numbers, URLs/paths, all-caps acronyms, and mixed-case words (brands, APIKeys).
    /// Internal (not private) so headless tests can pin the rules.
    static func isProtectedTerm(_ token: String) -> Bool {
        if token.count <= 1 { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        if token.contains("@") || token.contains("/") || token.contains("_") || token.contains(".") { return true }

        let letters = token.filter { $0.isLetter }
        if letters.count >= 2 && letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        var sawUpper = false
        var sawLower = false
        for ch in letters {
            if ch.isUppercase { sawUpper = true }
            if ch.isLowercase { sawLower = true }
        }
        return sawUpper && sawLower
    }

    private static let maxGrammarInputCharacters = 1200

#endif
```

> `TextCleanupEngine` is `Sendable`; the pass is stateless (local `NSSpellChecker` handle, no stored state) so the struct stays `Sendable`-safe — same thread it already ran on in `TextCleanupService`.

- [ ] **Step 5: Confirm GREEN — existing engine tests plus the new grammar suite**

All pre-existing engine tests use `grammarMode: .off` via their `config()` helper, so the new stage must be inert for them; the 7 grammar tests from Step 1 must now pass:

```bash
./scripts/test-engine.sh
```
Expected: all green — 32 original + 1 (Task 1 decode) + 7 grammar ≈ 40 tests.

- [ ] **Step 6: Commit**

```bash
git add -p app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift \
           app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupGrammarTests.swift
git commit -m "feat(K-06): move grammar pass into KalamTextEngine behind canImport(AppKit)"
```

---

## Task 3: K-06 — Delete `TextCleanupService`, update call sites

**Files:**
- Delete: `app/Kalam/TextCleanupService.swift`
- Modify: `app/Kalam/KalamApp.swift` (line ~1023, inside the transcription task)
- Modify: `app/Kalam/KalamTestRunner.swift` (line ~33, `runTextPipeline`)

**Interfaces:**
- Consumes: Task 2's `TextCleanupEngine.clean(text:configuration:)` (unchanged signature).
- Produces: no `TextCleanupService` anywhere; app shell calls `TextCleanupEngine()` directly.

- [ ] **Step 1: Re-read before editing (shared repo — siblings touch `KalamApp.swift`)**

```bash
git status --short
sed -n '1015,1030p' app/Kalam/KalamApp.swift   # locate the current cleanup call
```

- [ ] **Step 2: Update `KalamApp.swift`**

Replace:

```swift
                let cleanupResult = TextCleanupService.shared.clean(trimmedText, configuration: cleanupConfig)
```

with:

```swift
                let cleanupResult = TextCleanupEngine().clean(trimmedText, configuration: cleanupConfig)
```

`KalamApp.swift` already has `import KalamTextEngine` (verified). Nothing else in the file changes — the downstream `cleanupResult.stats.*` logging (line ~1030) reads the same `TextCleanupStats` fields.

- [ ] **Step 3: Update `KalamTestRunner.swift`**

Replace:

```swift
        let cleanupResult = TextCleanupService.shared.clean(text, configuration: config)
```

with:

```swift
        let cleanupResult = TextCleanupEngine().clean(text, configuration: config)
```

(`KalamTestRunner.swift` already imports `KalamTextEngine`.)

- [ ] **Step 4: Delete the service file**

```bash
rm app/Kalam/TextCleanupService.swift
```

Folder-synced groups drop it from the `Kalam` target automatically.

- [ ] **Step 5: Verify build**

```bash
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED. `grep -rn "TextCleanupService" app/Kalam app/KalamTests --include='*.swift'` → no matches (the Xcode test file is deleted in Task 4 — do the grep after Task 4 or expect exactly one hit for the test file).

- [ ] **Step 6: Commit**

```bash
git add -p app/Kalam/KalamApp.swift app/Kalam/KalamTestRunner.swift
git add -u app/Kalam/TextCleanupService.swift    # records the deletion
git commit -m "refactor(K-06): app calls TextCleanupEngine directly; delete TextCleanupService"
```

> The sibling's uncommitted `KalamApp.swift`/`OnboardingFlow.swift` edits may still be in the tree — stage only your hunks (`git add -p`), never `git add -A`.

---

## Task 4: K-06 — Finish the Xcode-side migration (delete the Xcode-only suite)

**Files:**
- Modify: `app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupEngineTests.swift`
- Delete: `app/KalamTests/TextCleanupServiceTests.swift`

(The headless grammar suite itself was created in Task 2 Step 1 — do not create it again here.)

- [ ] **Step 1: Migrate the distinctive backtrack test before deleting its home**

The Xcode suite's `testBareNoIsNotTreatedAsBacktrackCue` ("book me tomorrow no book me Friday") has no engine counterpart (engine has "there is no way…" but not this variant). Append to `TextCleanupEngineTests.swift`:

```swift
@Test func bareNoIsNotTreatedAsBacktrackCue() {
    // Bare "no" is common in normal prose — never a correction cue.
    let result = TextCleanupEngine().clean("book me tomorrow no book me Friday", configuration: config())
    #expect(result.text == "book me tomorrow no book me Friday")
    #expect(result.stats.backtrackEdits == 0)
}
```

(Everything else in `TextCleanupServiceTests.swift` — filler/list/backtrack corpus tests, config round-trips — is already duplicated in the engine suite; verified against both files.)

- [ ] **Step 2: Delete the Xcode-only suite**

```bash
rm app/KalamTests/TextCleanupServiceTests.swift
```

- [ ] **Step 3: Verify — headless grammar coverage is now real**

```bash
./scripts/test-engine.sh
```
Expected: all green — 32 original + 1 (Task 1 decode) + 7 grammar + 1 migrated backtrack ≈ 41 tests, including the grammar pass that previously had zero headless coverage.

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: full suite green (CustomDictionaryManagerTests from Task 1, no more `TextCleanupServiceTests`). If the spell server is absent in the Xcode host too, the tolerant assertions above keep the suite green.

- [ ] **Step 4: Commit**

```bash
git add -p app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupEngineTests.swift
git add -u app/KalamTests/TextCleanupServiceTests.swift
git commit -m "test(K-06): grammar pass now covered headlessly; drop Xcode-only TextCleanupServiceTests"
```

---

## Task 5: K-06 — Docs: pipeline, architecture map, coverage table

**Files:**
- Modify: `app/docs/DEVELOPER_GUIDE.md`
- Modify: `AGENTS.md`
- Modify: `app/docs/IMPROVEMENT_PLAN.md` (final flip)

- [ ] **Step 1: `DEVELOPER_GUIDE.md` — replace the service with the engine**

Apply these string replacements (line numbers drift; search for the quoted text):

1. `- `TextCleanupService.swift`` … block (file-list entry, ~line 80) → replace with:
   ```markdown
   - `Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` / `TextCleanupConfiguration.swift`
     - Deterministic low-latency transcript cleanup pipeline
     - Optional grammar pass (`off` / `light` / `full`) with timeout budget (AppKit-gated)
   ```
2. `2. `TextCleanupService.clean(...)`` → `2. `TextCleanupEngine.clean(...)`` (runtime flow, ~line 106)
3. `` `TextCleanupService` runs deterministic, local-only text transforms with feature flags: `` → `` `TextCleanupEngine` runs deterministic, local-only text transforms with feature flags: `` (~line 126)
4. Coverage table row (~line 462):
   ```
   | Grammar pass (`NSSpellChecker`) | `xcodebuild test` (Xcode only) | `KalamTests/TextCleanupServiceTests.swift` |
   ```
   → `| Grammar pass (`NSSpellChecker`) | `./scripts/test-engine.sh` | `Packages/KalamTextEngine/Tests/TextCleanupGrammarTests.swift` |`
5. ~line 508: "Unit tests are available in `app/KalamTests/TextCleanupServiceTests.swift` and run via the `KalamTests` target." → "Grammar/cleanup unit tests run headlessly via `./scripts/test-engine.sh` (`Packages/KalamTextEngine/Tests/`); the remaining app integration tests run via the `KalamTests` target."
6. Also delete the stale `- `TextCleanupConfiguration.swift`` file-list entry (points at the app-side file deleted earlier — K-17 cleanup, do it while here).

- [ ] **Step 2: `AGENTS.md`** — ⚠️ **BLOCKED at execution time (2026-08-11):** the Hermes runtime refuses agent writes to protected agent-instruction files (`AGENTS.md`), even with consent. The four replacements below are fully specified; apply them by hand (or with explicit human approval) once K-05/K-06 verification is complete. Until then `AGENTS.md` still names `TextCleanupService` (stale but harmless — the code itself is updated).

1. Architecture table row: `| `TextCleanupService.swift` | Wraps `TextCleanupEngine` + grammar pass (`NSSpellChecker`, timeout-bounded, `>1200` chars skipped). |` → `| `Packages/KalamTextEngine` | Cleanup engine incl. AppKit-gated grammar pass (`NSSpellChecker`, timeout-bounded, `>1200` chars skipped); headless-testable. |`
2. Pipeline order line: `ASR → TextCleanupService.clean → ITN (if enabled) → CustomDictionaryManager.apply → PasteService.paste` → `ASR → TextCleanupEngine.clean → ITN (if enabled) → CustomDictionaryManager.apply → PasteService.paste`
3. Common-tasks entry: "**Touch the grammar pass** → `TextCleanupService.swift`; tests are Xcode-only (`KalamTests/TextCleanupServiceTests.swift`); consider moving logic into the engine for headless tests (K-06)." → "**Touch the grammar pass** → `app/Packages/KalamTextEngine/Sources/KalamTextEngine/TextCleanupEngine.swift` (AppKit-gated section); tests are headless via `./scripts/test-engine.sh`."
4. Dictionary note: "**Add a dictionary feature** → … (note: `wholeWord`/`morphological` flags are currently no-ops — K-05)." → drop the parenthetical.

- [ ] **Step 3: `IMPROVEMENT_PLAN.md` — flip K-05/K-06 to ✅ with evidence**

Per the tracker protocol (implement + verify before ✅). Update both rows' Status to `✅` and add one changelog entry:

```markdown
- **K-05 + K-06 (2026-08-11)** — Dead `wholeWord`/`morphological` flags deleted from `DictionaryEntry` (tests rewritten to pin unconditional whole-word + suffix matching; JSON-compat decode test added). Grammar pass moved into `KalamTextEngine` behind `canImport(AppKit)`; `TextCleanupService.swift` and its Xcode-only test file deleted; call sites use `TextCleanupEngine()` directly. Verified: `./scripts/test-engine.sh` (~41 tests incl. grammar, green), `xcodebuild test` full suite green, build green. Plan: `app/docs/dev-design/2026-08-11-k05-k06-dictionary-flags-and-grammar-pass.md`.
```

- [ ] **Step 4: Commit**

```bash
git add -p app/docs/DEVELOPER_GUIDE.md AGENTS.md app/docs/IMPROVEMENT_PLAN.md
git commit -m "docs(K-05,K-06): pipeline and coverage docs point at KalamTextEngine; mark items done"
```

---

## Verification matrix (run before the final tracker flip)

| Check | Command | Pass condition |
|---|---|---|
| Engine incl. grammar (headless) | `./scripts/test-engine.sh` | ~41 tests green |
| Full Xcode suite | `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | green; no `TextCleanupService` references |
| Build | `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| No dead flags remain | `grep -rn "wholeWord\|morphological" app/Packages app/Kalam app/KalamTests` | only README/guide marketing copy about morphological matching (behavior, not the flag) |
| Pipeline order intact | read `AGENTS.md` + `DEVELOPER_GUIDE.md` runtime-flow sections | `TextCleanupEngine.clean` between ASR and ITN |
| Manual smoke (optional) | run app, dictate "hello world. also hi there." with Refine → Full | capitalized; dictate "apples" with `apple → orange` entry → "oranges" pasted |

## Risks & mitigations

- **Spell server unavailable in bare `swift test`** — all grammar tests are assertion-tolerant (invariants, not exact rewrites) and timeout-bounded; the only exact-output test branches on `grammarTimedOut`. Worst case on a broken spell setup: grammar stage times out, output unchanged, tests still green.
- **Concurrent siblings editing `KalamApp.swift`/`OnboardingFlow.swift`** — re-read before editing, `git add -p` only your hunks, verify with `git show HEAD -- <file>`.
- **VirtIOFS transient unreadability** — if a file reads as "not found" but `ls` shows it, read the index copy (`git show :0:./Kalam/<File>.swift`) or wait and retry.
- **Grammar-pass timeouts on first run** — `NSSpellChecker` first use may spawn the spell server; the 25–400 ms bounded budget already absorbs this; behavior identical to today's app path (same code, same thread model).
- **JSON decode of legacy dictionaries** — pinned by the Task 1 decode test; synthesized `Codable` ignores unknown keys.
