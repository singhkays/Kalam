# K-26..K-29 — Dictation Reliability & ITN Span Protection — Implementation Plan

> **For agentic workers:** Execute this plan task-by-task in order. Steps use checkbox (`- [ ]`) syntax. Run every test command from the repo root (`/Volumes/My Shared Files/GitHub/Kalam`). Follow `concurrent-session-git-workflow` (shared VirtIOFS mount): re-read files before overwriting, stage only your own hunks, prove commits with `git show`.

**Goal:** Fix five user-reported dictation bugs: stale-build "no"-backtrack text deletion (K-29), ITN corruption of ranges/idioms/digit-sequences (K-28), hallucinated junk paste on first dictation after idle (K-27 + K-26), and dead microphone after sleep/wake until manual mic reorder (K-26).

**Architecture:** Three independent workstreams plus a release. (1) **K-28**: a pure `ITNSpanProtector` in `KalamTextEngine` masks spoken-number spans the ITN tagger mis-normalizes (placeholder tokens), so `normalizeSentence` runs on safe text and the originals are restored after; wired around every `NemoTextProcessing.normalizeSentence` call. (2) **K-27**: a `SpeechQualityGuard` rejects noise-only clips before ASR (the Parakeet TDT hallucination path: trimmer fallback → `normalizePeak` boost → zero-pad → "yeah"). (3) **K-26**: an `AudioDeviceMonitor` (CoreAudio property listeners + `didWake`) invalidates the stale audio-graph binding, re-resolves the priority mic list, resets phantom PTT state after sleep, and makes `startCollecting()` fail loudly instead of silently capturing nothing.

**Tech Stack:** Swift 6, macOS 14.6, AppKit/SwiftUI, CoreAudio, AVFoundation, FluidAudio 0.15.5 (Parakeet TDT), NemoTextProcessing.xcframework, Swift Testing (engine) + XCTest (app).

## Global Constraints

- No network entitlement; no new network code, no new permissions, sandbox + hardened runtime unchanged.
- Never log transcript/audio content — counts/timings only with `privacy: .public`; **no device UIDs in logs** (K-16 convention; names/counts only).
- Audio buffers stay `secureZero()`'d; the render-thread tap callback must never block (K-10 invariants — do not touch `AudioCaptureExchange` locking).
- Deterministic text logic lives in `app/Packages/KalamTextEngine/` with headless Swift Testing; grammar stays behind `canImport(AppKit)`.
- Pipeline order unchanged: ASR → cleanup → ITN (protector-wrapped) → dictionary → paste.
- Folder-synchronized groups: new `.swift` files in `app/Kalam/`, `app/KalamTests/`, or the engine package need no pbxproj edits.
- Tests must never touch `AVAudioEngine.inputNode` in the test host (asserts; no input device) — use the existing seams (`beginCollectingForTesting`, internal accessors, pure decision helpers).
- Test commands: engine `./scripts/test-engine.sh` (brew swift); Xcode suite `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (targeted: add `-only-testing:KalamTests/<ClassName>`).
- `xcodebuild` output filtering: use `grep -Fq "** BUILD SUCCEEDED **"`, never `rg -E` (that's `--encoding`; kills the pipeline).

---

## Task 1: `ITNSpanProtector` in KalamTextEngine (K-28 core) — TDD

**Files:**
- Create: `app/Packages/KalamTextEngine/Sources/KalamTextEngine/ITNSpanProtector.swift`
- Create: `app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/ITNSpanProtectorTests.swift`
- Test: engine suite via `./scripts/test-engine.sh`

**Interfaces:**
- Produces: `public struct ITNSpanProtector: Sendable` with `public struct ProtectedSpan: Equatable, Sendable { token, original }`, `public init()`, `public func protect(_ text: String) -> (text: String, spans: [ProtectedSpan])`, `public func restore(_ text: String, spans: [ProtectedSpan]) -> String`.

**Why these patterns exist (verified against the real NemoTextProcessing library, 2026-08-12):** raw `nemo_normalize_sentence` output — `"two to three pager"` → `"02:58 pager"`; `"twelve to fourteen people"` → `"13:48 people"`; `"fifteen to twenty minutes"` → `"19:45 minutes"`; `"one of us"` → `"1 of us"`; `"first of all"` → `"1st of all"`; `"five five five one two three four"` → `"16 9"`; `"one two three four five six"` → `"10 05:06"`; `"two to three of us"` → `"02:58 of us"`. Custom identity rules (`nemo_add_rule("one of", "one of")`) do **not** block the built-in taggers — placeholder masking is the only working mechanism. Digit forms (`"2 - 3 pager"`, `"2 to 3 people"`) pass through ITN untouched — no digit patterns needed.

- [ ] **Step 1: Write the failing tests** (`ITNSpanProtectorTests.swift`)

```swift
import Testing
import Foundation
@testable import KalamTextEngine

// K-28: ITN span protection. Every test documents a real library behavior
// verified against NemoTextProcessing (raw ITN outputs in the plan header).

private func masked(_ text: String) -> String {
    ITNSpanProtector().protect(text).text
}

private func restored(_ text: String) -> String {
    let protector = ITNSpanProtector()
    let result = protector.protect(text)
    return protector.restore(result.text, spans: result.spans)
}

@Test func rangeTwoToThreeIsMasked() {
    #expect(masked("I'm writing a two to three pager").contains("XXKALAMSPAN0XX"))
}

@Test func rangeThroughIsMasked() {
    #expect(masked("twelve through fourteen people").contains("XXKALAMSPAN0XX"))
}

@Test func rangeWithLargeNumberWordsIsMasked() {
    // Raw ITN: "twelve to fourteen people" -> "13:48 people"
    #expect(masked("twelve to fourteen people are coming").contains("XXKALAMSPAN0XX"))
}

@Test func rangeWithCompoundLeftIsMasked() {
    // Raw ITN: "twenty two to three dollars" -> "02:38 dollars"
    let result = ITNSpanProtector().protect("twenty two to three dollars")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].original == "two to three")
}

@Test func quarterToThreeIsNotMasked() {
    // "quarter" is not a number word; ITN's "02:45" is correct time-speak.
    #expect(masked("see you at quarter to three") == "see you at quarter to three")
}

@Test func twoFiftyThreeIsNotMasked() {
    // "fifty" is not a simple number word; ITN's "02:53" is correct time-speak.
    #expect(masked("I'll meet you at two fifty three") == "I'll meet you at two fifty three")
}

@Test func idiomOneOfIsMasked() {
    // Raw ITN: "one of us" -> "1 of us"
    let result = ITNSpanProtector().protect("we consider you as one of us")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].original == "one of")
}

@Test func idiomTwoOfIsMasked() {
    let result = ITNSpanProtector().protect("there are two of us")
    #expect(result.spans[0].original == "two of")
}

@Test func idiomFirstOfAllIsMasked() {
    // Raw ITN: "first of all" -> "1st of all"
    #expect(masked("first of all, this is a test").contains("XXKALAMSPAN0XX"))
}

@Test func compoundNumberBeforeOfIsNotMasked() {
    // "twenty one of us" must still normalize to "21 of us" — the tens-word
    // lookbehind excludes compound numbers.
    #expect(masked("twenty one of us") == "twenty one of us")
}

@Test func digitRunIsMasked() {
    // Raw ITN: "five five five one two three four" -> "16 9"
    #expect(masked("call me at five five five one two three four").contains("XXKALAMSPAN0XX"))
}

@Test func countingRunIsMasked() {
    // Raw ITN: "one two three four five six" -> "10 05:06"
    #expect(masked("one two three four five six").contains("XXKALAMSPAN0XX"))
}

@Test func twentyTwentyFiveIsNotMasked() {
    // Compound years must still normalize to digits ("twenty" is not a simple
    // number word, so the run pattern cannot fire).
    #expect(masked("the year twenty twenty five") == "the year twenty twenty five")
}

@Test func twoHundredIsNotMasked() {
    #expect(masked("a two hundred page report") == "a two hundred page report")
}

@Test func overlappingRangeAndIdiomMergeIntoSingleSpan() {
    // Raw ITN: "two to three of us" -> "02:58 of us"
    let result = ITNSpanProtector().protect("two to three of us are coming")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].original == "two to three of")
}

@Test func restoreRoundTripsAllSpans() {
    let samples = [
        "I'm writing a two to three pager",
        "Don't worry, we consider you as one of us",
        "call me at five five five one two three four",
    ]
    for sample in samples {
        #expect(restored(sample) == sample)
    }
}

@Test func restoreIsCasePreserving() {
    #expect(restored("One of us") == "One of us")
}
```

- [ ] **Step 2: Run the tests — expect RED (compile failure)**

```bash
./scripts/test-engine.sh
```
Expected: build fails with `cannot find 'ITNSpanProtector' in scope` (the documented compile-failure RED shape — the type does not exist yet).

- [ ] **Step 3: Implement `ITNSpanProtector.swift`**

```swift
import Foundation

/// Protects spoken-number spans that the ITN tagger mis-normalizes, so that
/// natural dictation like "one of us" or "a two to three pager" survives
/// inverse text normalization unchanged.
///
/// ITN (NemoTextProcessing) converts number words to digits, and its taggers
/// misfire on:
/// - numeric ranges:   "two to three pager" -> "02:58 pager"
/// - partitive idioms: "one of us"          -> "1 of us"
/// - digit sequences:  "five five five..."  -> "16 9"
///
/// The pipeline masks protectable spans with unique placeholder tokens before
/// ITN runs, then restores the original spoken forms afterwards. Tokens are
/// letters-only so ITN never treats them as normalizable input. Custom
/// `nemo_add_rule` identity rules were verified NOT to block the built-in
/// taggers — masking is the only reliable mechanism.
public struct ITNSpanProtector: Sendable {
    public struct ProtectedSpan: Equatable, Sendable {
        public let token: String
        public let original: String

        public init(token: String, original: String) {
            self.token = token
            self.original = original
        }
    }

    public init() {}

    /// Replaces every protectable span with a unique placeholder token.
    /// Spans are returned in text order; `restore(_:spans:)` works regardless
    /// of order because tokens are unique.
    public func protect(_ text: String) -> (text: String, spans: [ProtectedSpan]) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [NSRange] = []
        for pattern in Self.protectionPatterns {
            matches.append(contentsOf: pattern.matches(in: text, options: [], range: nsRange))
        }
        guard !matches.isEmpty else { return (text, []) }

        matches.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for match in matches {
            if let last = merged.last, match.location <= last.location + last.length {
                let end = max(last.location + last.length, match.location + match.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(match)
            }
        }

        var spans: [ProtectedSpan] = []
        var masked = ""
        var cursor = text.startIndex
        for (index, range) in merged.enumerated() {
            guard let swiftRange = Range(range, in: text) else { continue }
            masked += text[cursor..<swiftRange.lowerBound]
            let token = "XXKALAMSPAN\(index)XX"
            spans.append(ProtectedSpan(token: token, original: String(text[swiftRange])))
            masked += token
            cursor = swiftRange.upperBound
        }
        masked += text[cursor...]
        return (masked, spans)
    }

    /// Restores the original span text in a normalized (masked) string.
    public func restore(_ text: String, spans: [ProtectedSpan]) -> String {
        var out = text
        for span in spans {
            out = out.replacingOccurrences(of: span.token, with: span.original)
        }
        return out
    }

    // MARK: - Patterns

    private static let numberWord =
        "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|" +
        "thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|" +
        "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|" +
        "hundred|thousand|million|billion)"
    private static let simpleNumberWord =
        "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let ordinalWord =
        "(?:first|second|third|fourth|fifth)"
    private static let tensWord =
        "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"

    /// "two to three", "twelve through fourteen" — ITN reads these as times
    /// ("02:58", "13:48"). Word separators only; digit ranges ("2 to 3")
    /// pass through untouched (verified against the real library).
    private static let rangePattern = try! NSRegularExpression(
        pattern: "(?i)\\b\(numberWord)\\s+(?:to|through)\\s+\(numberWord)\\b",
        options: []
    )

    /// "one of us", "two of the team", "first of all" — ITN digitizes the
    /// number word ("1 of us", "1st of all"). The fixed-width tens-word
    /// lookbehind keeps compound numbers like "twenty one of us" out (those
    /// SHOULD normalize to "21 of us").
    private static let idiomPattern = try! NSRegularExpression(
        pattern: "(?i)(?<!\\b\(tensWord)\\s)\\b(?:\(simpleNumberWord)|\(ordinalWord))\\s+of\\b",
        options: []
    )

    /// "five five five one two three four", "one two three" — digit-by-digit
    /// sequences ITN turns into arithmetic ("16 9", "10 05:06"). Runs of
    /// simple number words only, so "twenty twenty five" (-> 2025) and
    /// "two hundred" (-> 200) are unaffected.
    private static let runPattern = try! NSRegularExpression(
        pattern: "(?i)\\b\(simpleNumberWord)(?:\\s+\(simpleNumberWord))+\\b",
        options: []
    )

    private static let protectionPatterns: [NSRegularExpression] = [
        rangePattern, idiomPattern, runPattern
    ]
}
```

- [ ] **Step 4: Run the tests — expect GREEN**

```bash
./scripts/test-engine.sh
```
Expected: 41 existing + 17 new tests pass (58 total). Any failure = pattern bug — debug against the raw ITN outputs in the plan header.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/KalamTextEngine/Sources/KalamTextEngine/ITNSpanProtector.swift app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/ITNSpanProtectorTests.swift
git commit -m "feat(K-28): ITNSpanProtector masks spoken-number spans from ITN mis-normalization"
git show --stat HEAD | head -8   # prove the commit landed
```

**Documented trade-offs (do not "fix" without a product decision):** "nine eleven" no longer becomes "911" (run pattern); time-speak "ten to two" (1:50) stays words (range pattern) — users can dictate "one fifty" for times.

---

## Task 2: Wire the protector around every ITN call + real-library integration tests (K-28 wiring)

**Files:**
- Modify: `app/Kalam/KalamApp.swift` — `applyITNIfEnabled` (~:634-654)
- Modify: `app/Kalam/KalamTestRunner.swift` — `applyITN` (~:61-83)
- Create: `app/KalamTests/ITNSpanProtectorIntegrationTests.swift`
- Test: targeted Xcode tests, then full suite

**Interfaces:**
- Consumes: `ITNSpanProtector` from Task 1 (public API).
- Produces: end-to-end guarantee that the real Nemo library + protector round-trip the user's sentences.

- [ ] **Step 1: Rewrite `applyITNIfEnabled` in `KalamApp.swift`** (replace the `lines.map` body)

```swift
        let span = UInt32(spanTokens)
        let started = CFAbsoluteTimeGetCurrent()
        let protector = ITNSpanProtector()
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            // K-28: mask spoken-number spans ITN mis-normalizes (ranges,
            // idioms, digit sequences), normalize, then restore.
            let masked = protector.protect(trimmed)
            let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: span)
            return protector.restore(normalized, spans: masked.spans)
        }
```

- [ ] **Step 2: Rewrite `applyITN` in `KalamTestRunner.swift`** (same wrapping, exact signature preserved)

```swift
        let span = UInt32(max(4, itnSpan))
        let protector = ITNSpanProtector()
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            let masked = protector.protect(trimmed)
            let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: span)
            return protector.restore(normalized, spans: masked.spans)
        }
```

- [ ] **Step 3: Write the integration tests** (`ITNSpanProtectorIntegrationTests.swift`, mirrors the `KalamEngineIntegrationTests` XCTSkip pattern)

```swift
import XCTest
@testable import Kalam_test

// K-28: end-to-end protector + real NemoTextProcessing library. Skips when
// the framework is not linked in the test environment.
final class ITNSpanProtectorIntegrationTests: XCTestCase {
    private func runPipeline(_ text: String) -> String {
        let protector = ITNSpanProtector()
        let masked = protector.protect(text)
        let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: 16)
        return protector.restore(normalized, spans: masked.spans)
    }

    func testRangeSurvivesITN() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("I'm writing a two to three pager"), "I'm writing a two to three pager")
    }

    func testLargeRangeSurvivesITN() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("twelve to fourteen people are coming"), "twelve to fourteen people are coming")
    }

    func testIdiomSurvivesITN() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("Don't worry, we consider you as one of us"), "Don't worry, we consider you as one of us")
    }

    func testFirstOfAllSurvivesITN() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("first of all, this is a test"), "first of all, this is a test")
    }

    func testPhoneDigitsSurviveITN() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("call me at five five five one two three four"), "call me at five five five one two three four")
    }

    func testCompoundNumberStillNormalizes() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("twenty one of us"), "21 of us")
    }

    func testTimeSpeechStillNormalizes() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("I'll meet you at two fifty three"), "I'll meet you at 02:53")
    }

    func testCurrencyStillNormalizes() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("five dollars and fifty cents"), "$5.50")
    }

    func testYearStillNormalizes() throws {
        try XCTSkipUnless(NemoTextProcessing.isAvailable, "NemoTextProcessing is not linked in this test environment.")
        XCTAssertEqual(runPipeline("the year twenty twenty five"), "the year 2025")
    }
}
```

- [ ] **Step 4: Run the integration tests**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/ITNSpanProtectorIntegrationTests 2>&1 | grep -Fq "** TEST SUCCEEDED **"
```
Expected: 9/9 pass (framework is linked in the test host). If a test fails, the failing expectation IS the raw library output — adjust the protector pattern, not the test.

- [ ] **Step 5: Full suite + commit**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -Fq "** TEST SUCCEEDED **"
git add app/Kalam/KalamApp.swift app/Kalam/KalamTestRunner.swift app/KalamTests/ITNSpanProtectorIntegrationTests.swift
git commit -m "feat(K-28): wrap ITN calls with ITNSpanProtector; real-library integration tests"
```

---

## Task 3: `SpeechQualityGuard` + `SilenceTrimmer` helper extraction (K-27)

**Files:**
- Modify: `app/Kalam/Services/SilenceTrimmer.swift` — extract `windowedEnergiesDb` (verbatim code motion from `trim`), make `percentile` internal
- Create: `app/Kalam/Services/SpeechQualityGuard.swift`
- Create: `app/KalamTests/SpeechQualityGuardTests.swift`
- Modify: `app/Kalam/KalamApp.swift` — transcription task wiring (~:928-936)
- Test: targeted + full suite

**Interfaces:**
- Consumes: `SilenceTrimmer.windowedEnergiesDb(samples:sampleRate:windowMs:)` and `SilenceTrimmer.percentile(_:p:)` (internal).
- Produces: `enum SpeechQualityGuard { static func isSpeechLike(samples: [Float], sampleRate: Int, windowMs: Int = 20, minActiveSpeechMs: Int = 120, speechMarginDb: Float = 6) -> Bool }`.

- [ ] **Step 1: Extract the energy-windowing helper in `SilenceTrimmer.swift`** — replace the inline loop in `trim` (currently lines ~31-55) with a call, and add the shared functions:

```swift
    // MARK: - Energy analysis (shared with SpeechQualityGuard, K-27)

    /// Per-window RMS energy in clamped dB ([-60, 0]). Extracted verbatim
    /// from `trim` so the speech-quality guard and the endpointer agree.
    static func windowedEnergiesDb(samples: [Float], sampleRate: Int, windowMs: Int = 20) -> [Float] {
        let winSamples = max(1, (sampleRate * windowMs) / 1000)
        var energiesDb: [Float] = []
        energiesDb.reserveCapacity(samples.count / winSamples + 1)

        // Compute per-window RMS energy, then convert to dB (20*log10 for amplitude scale)
        let eps: Float = 1e-6  // Epsilon for RMS to avoid log(0); yields ~ -120 dB floor before clamp
        var i = 0
        while i < samples.count {
            let end = min(i + winSamples, samples.count)
            var sum: Float = 0
            var j = i
            while j < end {
                let s = samples[j]
                sum += s * s
                j += 1
            }
            let count = Float(end - i)
            let meanSquare = sum / count
            let rms = sqrt(meanSquare)
            let db = 20.0 * log10(max(rms, eps))
            // Clamp to [-60, 0] dB: -60 floor avoids overestimating silence in low-level speech; 0 caps peaks
            let clampedDb = max(-60.0, min(0.0, db))
            energiesDb.append(clampedDb)
            i = end
        }
        return energiesDb
    }

    static func percentile(_ xs: [Float], p: Float) -> Float {
        if xs.isEmpty { return -120.0 }
        let pClamped = max(0.0, min(1.0, p))
        let sorted = xs.sorted()
        let idx = Int(round(pClamped * Float(sorted.count - 1)))
        return sorted[idx]
    }
```
In `trim`: delete the old inline loop + `winSamples`/`eps` locals, and call `let energiesDb = windowedEnergiesDb(samples: samples, sampleRate: sampleRate, windowMs: windowMs)` before the `guard !energiesDb.isEmpty` line. Existing trimmer behavior must be byte-identical (existing tests pin it).

- [ ] **Step 2: Write the guard tests** (`SpeechQualityGuardTests.swift`)

```swift
import XCTest
@testable import Kalam_test

// K-27: noise-only clips must never reach ASR — Parakeet TDT hallucinates
// filler words ("yeah") on boosted room tone.
final class SpeechQualityGuardTests: XCTestCase {
    private func sine(amplitude: Float, frequency: Float = 220, durationMs: Int, sampleRate: Int = 16_000) -> [Float] {
        let count = sampleRate * durationMs / 1000
        return (0..<count).map { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    private func whiteNoise(amplitude: Float, durationMs: Int, sampleRate: Int = 16_000, seed: UInt32 = 7) -> [Float] {
        var rng = seed
        let count = sampleRate * durationMs / 1000
        return (0..<count).map { _ in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let unit = Float(rng >> 24) / Float(0xFF)
            return (unit * 2 - 1) * amplitude
        }
    }

    func testPureSilenceIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
    }

    func testRoomToneNoiseIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: whiteNoise(amplitude: 0.001, durationMs: 800), sampleRate: 16_000))
    }

    func testLouderNoiseIsRejected() {
        // Uniform noise has no windows 6 dB above its own floor.
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: whiteNoise(amplitude: 0.01, durationMs: 800), sampleRate: 16_000))
    }

    func testToneBurstOverNoiseIsAccepted() {
        var clip = whiteNoise(amplitude: 0.001, durationMs: 500)
        clip.append(contentsOf: sine(amplitude: 0.1, durationMs: 300))
        clip.append(contentsOf: whiteNoise(amplitude: 0.001, durationMs: 200))
        XCTAssertTrue(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testShortToneBurstIsRejected() {
        // 60 ms of tone is below the 120 ms minimum speech run.
        var clip = whiteNoise(amplitude: 0.001, durationMs: 300)
        clip.append(contentsOf: sine(amplitude: 0.1, durationMs: 60))
        clip.append(contentsOf: whiteNoise(amplitude: 0.001, durationMs: 300))
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testSingleImpulseIsRejected() {
        var clip = [Float](repeating: 0, count: 16_000)
        clip[8000] = 0.5
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testEmptyIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: [], sampleRate: 16_000))
    }
}
```

- [ ] **Step 3: Run — expect RED (compile failure, `SpeechQualityGuard` missing)**
- [ ] **Step 4: Implement `SpeechQualityGuard.swift`**

```swift
import Foundation

/// Rejects clips that are noise or near-silence before they reach ASR.
///
/// Parakeet TDT hallucinates filler words ("yeah") on boosted room tone —
/// the pipeline's trimmer fallback + peak normalization + zero-padding turn
/// noise into model input. The guard requires a sustained run of windows
/// at least `speechMarginDb` above the clip's own noise floor.
enum SpeechQualityGuard {
    /// - Parameters:
    ///   - samples: 16 kHz mono Float32 (post-trim).
    ///   - sampleRate: sample rate of `samples`.
    ///   - windowMs: energy window size (must match the trimmer).
    ///   - minActiveSpeechMs: minimum CONSECUTIVE speech-level duration.
    ///   - speechMarginDb: windows must exceed the noise floor by this much.
    static func isSpeechLike(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        minActiveSpeechMs: Int = 120,
        speechMarginDb: Float = 6
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        let energiesDb = SilenceTrimmer.windowedEnergiesDb(samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energiesDb.isEmpty else { return false }
        let noiseFloorDb = SilenceTrimmer.percentile(energiesDb, p: 0.05)
        let speechThresholdDb = noiseFloorDb + speechMarginDb
        let requiredWindows = max(1, (minActiveSpeechMs + windowMs - 1) / windowMs)
        var run = 0
        for db in energiesDb {
            if db >= speechThresholdDb {
                run += 1
                if run >= requiredWindows { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
```

- [ ] **Step 5: Wire into the transcription task (`KalamApp.swift`)** — insert after the existing `guard !trimmed.isEmpty` block (~:930-936):

```swift
            // K-27: never feed noise-only clips to ASR — Parakeet TDT
            // hallucinates filler words ("yeah") on boosted room tone.
            guard SpeechQualityGuard.isSpeechLike(samples: trimmed, sampleRate: 16_000) else {
                self.logger.info("Clip rejected by speech-quality guard")
                await MainActor.run {
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }
```

- [ ] **Step 6: Run targeted + full suite, then commit**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/SpeechQualityGuardTests 2>&1 | grep -Fq "** TEST SUCCEEDED **"
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -Fq "** TEST SUCCEEDED **"
git add app/Kalam/Services/SilenceTrimmer.swift app/Kalam/Services/SpeechQualityGuard.swift app/KalamTests/SpeechQualityGuardTests.swift app/Kalam/KalamApp.swift
git commit -m "feat(K-27): speech-quality guard rejects noise-only clips before ASR"
```

---

## Task 4: `AudioRecorder` hardening — invalidation, loud failures, safe ordering (K-26a)

**Files:**
- Modify: `app/Kalam/Services/AudioRecorder.swift`
- Create: `app/KalamTests/AudioPrepareDecisionTests.swift`
- Modify: `app/Kalam/KalamApp.swift` — `startRecording` (~:826-864)
- Test: targeted + full suite

**Interfaces:**
- Consumes: nothing new.
- Produces: `AudioPrepareDecision.shouldReconfigure(isPrepared:lastDeviceID:preferredDeviceID:invalidated:) -> Bool`; `AudioRecorder.invalidatePreparedState()`; `AudioRecorder.startCollecting() throws`; internal test accessors `isPreparedForTesting`, `preparedDeviceIDForTesting`, `isPreparedStateInvalidatedForTesting`.

- [ ] **Step 1: Write the decision tests** (`AudioPrepareDecisionTests.swift`)

```swift
import XCTest
@testable import Kalam_test

// K-26: the prepare() early-return was the stale-binding bug — after
// sleep/wake the engine stayed bound to a dead CoreAudio device until the
// user manually reordered microphones.
final class AudioPrepareDecisionTests: XCTestCase {
    func testSkipsWhenFullyPreparedAndNotInvalidated() {
        XCTAssertFalse(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 5, invalidated: false))
    }

    func testReconfiguresWhenDeviceIDChanges() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 6, invalidated: false))
    }

    func testReconfiguresWhenNotPrepared() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: false, lastDeviceID: 5, preferredDeviceID: 5, invalidated: false))
    }

    func testReconfiguresWhenInvalidated() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 5, invalidated: true))
    }

    func testInvalidateFlipsFlagOnRecorder() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isPreparedStateInvalidatedForTesting)
        recorder.invalidatePreparedState()
        XCTAssertTrue(recorder.isPreparedStateInvalidatedForTesting)
    }
}
```
Note: `prepare()` itself cannot run in the test host (inputNode asserts, K-10) — the flag-consumption line inside `prepare()` is exercised in production and by the 🧑 gate.

- [ ] **Step 2: Run — expect RED (compile failure, `AudioPrepareDecision` missing)**
- [ ] **Step 3: Implement in `AudioRecorder.swift`**

Add the pure decision helper:

```swift
/// Decides whether `prepare()` must rebuild the audio graph. Extracted from
/// `AudioRecorder.prepare` so the early-return logic is headless-testable
/// (K-26; the test host cannot touch `engine.inputNode`).
enum AudioPrepareDecision {
    static func shouldReconfigure(
        isPrepared: Bool,
        lastDeviceID: AudioDeviceID?,
        preferredDeviceID: AudioDeviceID?,
        invalidated: Bool
    ) -> Bool {
        !(isPrepared && lastDeviceID == preferredDeviceID && !invalidated)
    }
}
```

Add the invalidation state + accessors to `AudioRecorder`:

```swift
    private var preparedStateInvalidated = false

    /// Forces the next `prepare()` call to fully rebuild the audio graph
    /// (engine stop, tap removal, device re-bind). Called on CoreAudio device
    /// changes and system wake (K-26) — without it, prepare() early-returns
    /// on an unchanged device ID and stays bound to a stale device.
    func invalidatePreparedState() {
        preparedStateInvalidated = true
    }

    var isPreparedForTesting: Bool { isPrepared }
    var preparedDeviceIDForTesting: AudioDeviceID? { preparedInputDeviceID }
    var isPreparedStateInvalidatedForTesting: Bool { preparedStateInvalidated }
```

Replace the `prepare()` early-return head (currently `if isPrepared && preparedInputDeviceID == preferredInputDeviceID { return }`):

```swift
        if !AudioPrepareDecision.shouldReconfigure(
            isPrepared: isPrepared,
            lastDeviceID: preparedInputDeviceID,
            preferredDeviceID: preferredInputDeviceID,
            invalidated: preparedStateInvalidated
        ) {
            return
        }
        preparedStateInvalidated = false
```

- [ ] **Step 4: Harden `startCollecting()`** — change signature to `func startCollecting() throws`, reset the exchange FIRST, and retry once with a fresh graph on engine-start failure:

```swift
    func startCollecting() throws {
        // K-26: reset capture state BEFORE touching the engine — the old
        // order (reset at the end) left stale state when engine.start()
        // failed, and the failure was silently swallowed.
        exchange.resetForNewSession()

        if !engine.isRunning {
            do {
                try engine.start()
                logger.info("Audio engine started for recording")
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                logger.info("Live input output format sampleRate=\(liveOutputFormat.sampleRate, privacy: .public) channels=\(liveOutputFormat.channelCount, privacy: .public)")
                logger.info("Live input bus format sampleRate=\(liveInputBusFormat.sampleRate, privacy: .public) channels=\(liveInputBusFormat.channelCount, privacy: .public)")
            } catch {
                // One recovery attempt: invalidate the stale graph binding
                // (sleep/wake, dock reconnect) and retry from a fresh prepare.
                logger.warning("Audio engine start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public); attempting re-prepare")
                invalidatePreparedState()
                do {
                    try prepare(preferredInputDeviceID: preparedInputDeviceID)
                    try engine.start()
                    logger.info("Audio engine started after re-prepare")
                } catch {
                    throw AudioRecorderError.engineStartFailed(error)
                }
            }
        }

        if !tapInstalled {
            // For input node taps, AVAudioEngine expects the input bus hardware format.
            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            logger.info("Installing tap sampleRate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)")
            engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSizeFrames, format: tapFormat) { [weak self] (buffer, _) in
                self?.process(buffer: buffer)
            }
            tapInstalled = true
        }

        logger.info("Started collecting audio samples")
    }
```

- [ ] **Step 5: Update the `startRecording` call site (`KalamApp.swift`)** — move the state sync after a successful start so a failed start leaves the PTT machine idle (K-14 invariant "failed starts leave the machine idle"). Currently: `_ = recordingSessions.beginNewRecording()` + `pttState.recordingDidStart(triggerMode)` sit at ~:826-827, `audio.startCollecting()` at ~:862. New tail of `startRecording`:

```swift
        do {
            try audio.startCollecting()
        } catch {
            logger.warning("Audio collection start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            dictationTargetPID = nil
            dictationTargetElement = nil
            overlay.showError("Microphone unavailable", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }
        _ = recordingSessions.beginNewRecording()
        pttState.recordingDidStart(triggerMode)
        overlay.showRecording(isHoldMode: triggerMode == .hold)
        return true
```
(Delete the old `beginNewRecording`/`recordingDidStart` lines at ~:826-827 and the old `audio.startCollecting()` + `overlay.showRecording` lines at ~:862-863.)

- [ ] **Step 6: Targeted tests + full suite + commit**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/AudioPrepareDecisionTests 2>&1 | grep -Fq "** TEST SUCCEEDED **"
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -Fq "** TEST SUCCEEDED **"
git add app/Kalam/Services/AudioRecorder.swift app/KalamTests/AudioPrepareDecisionTests.swift app/Kalam/KalamApp.swift
git commit -m "fix(K-26): AudioRecorder invalidation, loud start failures, exchange reset before engine start"
```

---

## Task 5: `AudioDeviceMonitor` + wake/device wiring (K-26b)

**Files:**
- Create: `app/Kalam/Services/AudioDeviceMonitor.swift`
- Create: `app/KalamTests/AudioDeviceMonitorTests.swift`
- Modify: `app/Kalam/KalamApp.swift` — monitor lifecycle, `refreshAudioInputAfterDeviceChange`, `handleSystemWake`, `applicationWillTerminate`
- Test: targeted + full suite

**Interfaces:**
- Consumes: `AudioRecorder.invalidatePreparedState()` + `prepare(preferredInputDeviceID:)` from Task 4.
- Produces: `@MainActor final class AudioDeviceMonitor` with `init(debounceInterval: TimeInterval = 0.5)`, `start(onDeviceChange:onWake:)`, `stop()`, internal test hooks `fireDevicesChangedForTesting()` / `fireWakeForTesting()`.

- [ ] **Step 1: Write the monitor tests** (`AudioDeviceMonitorTests.swift`)

```swift
import XCTest
@testable import Kalam_test

// K-26: device-change bursts (dock reconnect churn) must coalesce into one
// refresh; wake must fire immediately, NOT debounced. @MainActor: the
// monitor is MainActor-isolated (K-20 pattern).
@MainActor
final class AudioDeviceMonitorTests: XCTestCase {
    func testDebounceCoalescesBurstOfDeviceEvents() async throws {
        let monitor = AudioDeviceMonitor(debounceInterval: 0.05)
        let fired = expectation(description: "device change fired")
        fired.assertForOverFulfill = false
        var count = 0
        monitor.start(onDeviceChange: { count += 1; fired.fulfill() }, onWake: {})
        monitor.fireDevicesChangedForTesting()
        monitor.fireDevicesChangedForTesting()
        monitor.fireDevicesChangedForTesting()
        await fulfillment(of: [fired], timeout: 1.0)
        XCTAssertEqual(count, 1)
        monitor.stop()
    }

    func testWakeFiresImmediately() async throws {
        let monitor = AudioDeviceMonitor(debounceInterval: 10) // long debounce: wake must NOT wait
        let fired = expectation(description: "wake fired")
        monitor.start(onDeviceChange: {}, onWake: { fired.fulfill() })
        monitor.fireWakeForTesting()
        await fulfillment(of: [fired], timeout: 1.0)
        monitor.stop()
    }

    func testStopCancelsPendingDebounce() {
        let monitor = AudioDeviceMonitor(debounceInterval: 0.05)
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        monitor.start(onDeviceChange: { fired.fulfill() }, onWake: {})
        monitor.fireDevicesChangedForTesting()
        monitor.stop()
        wait(for: [fired], timeout: 0.2)
    }
}
```

- [ ] **Step 2: Run — expect RED (compile failure)**
- [ ] **Step 3: Implement `AudioDeviceMonitor.swift`**

```swift
import CoreAudio
import Foundation
import OSLog

/// Watches for audio input topology changes (device plug/unplug, default-input
/// switches, device death) and system wake events. Kalam uses it to re-prepare
/// the AVAudioEngine input graph after sleep/wake and dock reconnects — without
/// it the engine stays bound to a stale CoreAudio device until the user
/// manually reorders microphones (K-26).
@MainActor
final class AudioDeviceMonitor {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioDevice")

    private var onDeviceChange: (() -> Void)?
    private var onWake: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private var wakeObserver: NSObjectProtocol?
    private var registeredListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var aliveListener: (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    func start(onDeviceChange: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onDeviceChange = onDeviceChange
        self.onWake = onWake
        registerHardwareListeners()
        registerWakeObserver()
        updateAliveListener()
    }

    func stop() {
        for listener in registeredListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        registeredListeners.removeAll()
        if let aliveListener {
            var address = aliveListener.address
            AudioObjectRemovePropertyListenerBlock(aliveListener.object, &address, DispatchQueue.main, aliveListener.block)
            self.aliveListener = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Test hooks (bypass CoreAudio registration)

    func fireDevicesChangedForTesting() {
        scheduleRefresh()
    }

    func fireWakeForTesting() {
        handleWake()
    }

    // MARK: - Events

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDeviceChange()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func handleDeviceChange() {
        updateAliveListener()
        onDeviceChange?()
    }

    private func handleWake() {
        onWake?()
    }

    // MARK: - CoreAudio registration

    private func registerHardwareListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDeviceChanged,
            kAudioHardwarePropertyDevices
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
            if status == noErr {
                registeredListeners.append((systemObject, address, block))
            } else {
                logger.warning("Failed to register audio property listener status=\(status, privacy: .public)")
            }
        }
    }

    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    /// Re-arms the device-alive listener on the current default input device
    /// (the one Kalam would record from when no explicit mic is chosen).
    private func updateAliveListener() {
        let deviceID = Self.defaultInputDeviceID()
        if let aliveListener, aliveListener.object == deviceID {
            return
        }
        if let aliveListener {
            var address = aliveListener.address
            AudioObjectRemovePropertyListenerBlock(aliveListener.object, &address, DispatchQueue.main, aliveListener.block)
            self.aliveListener = nil
        }
        guard deviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAliveChanged,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status == noErr {
            aliveListener = (deviceID, address, block)
        } else {
            logger.warning("Failed to register device-alive listener status=\(status, privacy: .public)")
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return kAudioObjectUnknown
        }
        return deviceID
    }
}
```

- [ ] **Step 4: Wire into `AppDelegate` (`KalamApp.swift`)**

Add property near the other observers (~:104):

```swift
    private var audioMonitor: AudioDeviceMonitor?
```

In `applicationDidFinishLaunching` (after the `appDidBecomeActiveObserver` block, ~:257):

```swift
        let monitor = AudioDeviceMonitor()
        monitor.start(
            onDeviceChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshAudioInputAfterDeviceChange()
                }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleSystemWake()
                }
            }
        )
        audioMonitor = monitor
```

In `applicationWillTerminate` (first line of the body):

```swift
        audioMonitor?.stop()
```

Add the two new methods (place near `performRuntimePreparation`):

```swift
    /// K-26: CoreAudio device changed (plug/unplug, default-input switch,
    /// device death, dock reconnect) — rebuild the audio graph against the
    /// fresh topology and re-select the priority-ordered microphone.
    private func refreshAudioInputAfterDeviceChange() {
        audio.invalidatePreparedState()
        do {
            _ = try prepareAudioForRecording()
            isAudioReady = true
        } catch {
            isAudioReady = false
            logger.warning("Audio refresh after device change failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }
        refreshOnboardingState(reopenIfNeeded: false)
    }

    /// K-26: system woke. Two failure modes to clear:
    /// 1. A phantom PTT session (toggle started before sleep, key-up lost) —
    ///    the first post-wake keypress would otherwise act as a STOP and
    ///    instantly "transcribe" a junk clip. Reset the machine silently
    ///    (no chime, no toast — wake should not beep).
    /// 2. A stale audio-graph binding — same refresh as a device change.
    private func handleSystemWake() {
        logger.info("System wake: resetting PTT state and refreshing audio input")
        if isRecording {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            dictationTargetPID = nil
            dictationTargetElement = nil
            heldTranscript = nil
            let audio = self.audio
            Task { await audio.cancelCapture() }
            overlay.hide()
        }
        pttState.resetForConfigurationChange()
        refreshAudioInputAfterDeviceChange()
    }
```

- [ ] **Step 5: Targeted tests + full suite + commit**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:KalamTests/AudioDeviceMonitorTests 2>&1 | grep -Fq "** TEST SUCCEEDED **"
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -Fq "** TEST SUCCEEDED **"
git add app/Kalam/Services/AudioDeviceMonitor.swift app/KalamTests/AudioDeviceMonitorTests.swift app/Kalam/KalamApp.swift
git commit -m "feat(K-26): AudioDeviceMonitor re-prepares audio graph on device change and system wake"
```

**Pitfall watch:** the test host runs the real `AppDelegate` (applicationDidFinishLaunching), so `monitor.start()` registers real system-object listeners during tests. System-object property listeners do not require mic permission and were verified safe in the host (only `engine.inputNode` asserts). If the suite ever crashes in CoreAudio registration, gate `registerHardwareListeners` behind a `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil` check and re-run.

---

## Task 6: K-29 regression pins + docs + tracker

**Files:**
- Modify: `app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupEngineTests.swift` (append 2 pins after `backtrackActuallyDoesNotDestroyNormalSentence`)
- Modify: `app/docs/DEVELOPER_GUIDE.md` (pipeline list, ~:104-108)
- Modify: `app/docs/IMPROVEMENT_PLAN.md` (K-26..K-29 rows + status flips + notes — see tracker edits below)
- Test: engine suite + full Xcode suite

- [ ] **Step 1: Append the regression pins**

```swift
@Test func backtrackNoCueDoesNotCancelNoProblemSentence() {
    // K-29 (user-reported on the v1.1 build): "no problem" at the end of a
    // sentence must not cancel the preceding clause.
    let result = TextCleanupEngine().clean("Yep, there is a roadmap meeting, so no problem", configuration: config())
    #expect(result.text.contains("no problem"))
    #expect(result.text.contains("roadmap meeting"))
    #expect(result.stats.backtrackEdits == 0)
}

@Test func backtrackNoCueDoesNotCancelContractedNoWay() {
    // K-29: contraction variant of the existing "there is no way" pin.
    let result = TextCleanupEngine().clean("there's no way to do this for them", configuration: config())
    #expect(result.text.contains("no way to do this for them"))
    #expect(result.stats.backtrackEdits == 0)
}
```
(These pin CURRENT behavior — they pass immediately; that is expected for regression pins. The contains-based assertions keep the grammar pass's locale-dependent corrections from flaking.)

- [ ] **Step 2: Run engine suite — expect 60/60 green**
- [ ] **Step 3: Update `DEVELOPER_GUIDE.md` pipeline list** — change step 3 (~:106) to:

```markdown
3. `NemoTextProcessing.normalizeSentence(...)` (if ITN enabled + available), wrapped by `ITNSpanProtector` so ranges ("two to three"), idioms ("one of us"), and digit-by-digit sequences survive normalization (K-28)
```

- [ ] **Step 4: Update `IMPROVEMENT_PLAN.md`** — see the "Tracker edits" block at the end of this plan; flip K-26..K-29 to `🔄` and add the notes AFTER the full table of each priority section (K-26/K-27/K-28 → Priority 1; K-29 → Priority 4).
- [ ] **Step 5: Full suite + commit**

```bash
cd app && xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -Fq "** TEST SUCCEEDED **"
git add app/Packages/KalamTextEngine/Tests/KalamTextEngineTests/TextCleanupEngineTests.swift app/docs/DEVELOPER_GUIDE.md
git commit -m "test(K-29): pin user-reported no-backtrack sentences; sync DEVELOPER_GUIDE ITN pipeline note"
```
Commit the tracker edits separately (shared file — stage only the new rows/notes hunks, verify `git diff --cached` shows ONLY them; if sibling hunks merge into one diff region, commit the other files and leave the tracker edit unstaged, flagging it in the reply).

---

## Task 7: Release v1.2 + 🧑 user verification

- [ ] **Step 1: Tag and push**

```bash
git tag -a v1.2 -m "K-26..K-29: dictation reliability & ITN span protection"
git push origin v1.2
```
The release workflow (`release.yml`, tag-gated) builds, tests, packages the DMG, and creates the GitHub release. Watch the run; confirm the release asset exists before telling the user.

- [ ] **Step 2: 🧑 User verification checklist** (user runs the installed v1.2 app)

1. **Bug 1 (K-29):** dictate "Yep, there is a roadmap meeting, so no problem" → the FULL sentence is pasted.
2. **Bug 2 (K-28):** dictate "Don't worry, we consider you as one of us" → "one of us" stays words; "twenty one of us" → "21 of us"; "five dollars and fifty cents" → "$5.50".
3. **Bug 4 (K-28):** dictate "I'm writing a two to three pager" → "I'm writing a two to three pager" (or "2 - 3 pager"); "twelve to fourteen people are coming" stays words.
4. **Bug 3 (K-26+K-27):** sleep 10+ minutes (or overnight) → first dictation works normally — no instant exit, no "yeah"/random-word paste. Toggle mode specifically: press the hotkey, let the Mac sleep BEFORE pressing again, wake → first press must NOT end a phantom session.
5. **Bug 5 (K-26):** sleep with the webcam mic attached via dock → wake → dictate: the webcam mic is used immediately (no reorder needed). Unplug/replug the webcam → next dictation recovers without touching Settings.
6. **Short utterances:** "yes" and "no" still dictate (guard boundary).
7. Optional: `log stream --predicate 'subsystem == "singhkays.Kalam"'` during wake — expect "System wake: resetting PTT state and refreshing audio input" (counts only, no content).

- [ ] **Step 3: Close out the tracker** — flip K-26..K-29 to `✅` only after the checklist passes; report evidence.

---

## Tracker edits (IMPROVEMENT_PLAN.md)

**Priority 1 table — append after the K-23 row:**

| K-26 | 🔄 | **High** | Microphone unusable after sleep/wake (webcam on dock) until the user manually reorders mics; first dictation after idle/sleep can end instantly and paste an ASR hallucination ("yeah"). No audio-device/wake observation exists anywhere; `AudioRecorder.prepare()` early-returns on an unchanged device ID (stale CoreAudio binding after wake); `startCollecting()` silently no-ops when `engine.start()` fails (tap never installed, exchange not reset); the PTT state machine can stay "recording" across sleep (first post-wake press = phantom stop). | New `AudioDeviceMonitor` (CoreAudio default-input/devices/alive listeners + `didWake`) → invalidate prepared state, re-resolve priority mics, re-prepare, refresh `isAudioReady`; `startCollecting()` resets the exchange first and throws on failure (one re-prepare retry); on wake: reset PTT state + silent phantom-session cancel; `startRecording` moves the state sync after a successful `startCollecting`. | 🧑 sleep/wake cycle with docked webcam: dictation works without reordering; first post-wake dictation never pastes junk. Unit: `AudioPrepareDecisionTests` (5), `AudioDeviceMonitorTests` (3). |
| K-27 | 🔄 | Medium | Noise-only clips reach ASR: `SilenceTrimmer`'s "send full audio" fallback + `normalizePeak` boost + zero-padding turn room tone into model input → Parakeet TDT hallucinates fillers ("yeah") that get pasted. | New `SpeechQualityGuard.isSpeechLike` (windowed energy, ≥120 ms consecutive run ≥6 dB above the noise floor) gating ASR; pipeline order: trim → guard → normalizePeak → pad → ASR. | `SpeechQualityGuardTests` (7, synthetic silence/noise/tone/impulse); 🧑 short "yes"/"no" still dictate; first post-wake dictation shows "No speech detected" (or works) — never pastes junk. |
| K-28 | 🔄 | **High** | ITN corrupts natural dictation: "two to three pager" → "02:58 pager" (user-observed; verified against the real library, incl. "twelve to fourteen people" → "13:48 people", "fifteen to twenty minutes" → "19:45 minutes", "five five five one two three four" → "16 9"), "one of us" → "1 of us", "first of all" → "1st of all". Custom `nemo_add_rule` identity rules do NOT block the built-in taggers (verified). | New `ITNSpanProtector` in KalamTextEngine (placeholder mask/restore): ranges `numword (to|through) numword`, idioms `one..twelve/first..fifth + of` (fixed-width tens-lookbehind), consecutive simple-number-word runs (≥2); wrapped around every `normalizeSentence` call (`applyITNIfEnabled`, KalamTestRunner). | Engine tests (17 pins incl. non-interference: "two fifty three" → 02:53, "quarter to three" → 02:45, "twenty twenty five" → 2025, "$5.50"); 9 real-library integration tests; 🧑 dictation of the user sentences. |

**Priority 4 table — append after the K-22 row:**

| K-29 | 🔄 | Low | v1.1 (2026-05-19) ships the bare-"no" backtrack rule: "no problem" / "there's no way…" deletes the preceding clause (user-observed). Current engine already fixed and pinned ("there is no way to do this", `TextCleanupEngineTests.swift:48-50`) — the installed build is stale. | Add 2 regression pins for the user's exact sentences; ship a release (v1.2) carrying K-26..K-29. | `./scripts/test-engine.sh` green; user verifies bug 1 gone on v1.2. |

**Notes (AFTER the full table of each section — never mid-table):**

> **K-26..K-28 (2026-08-12):** dev plan authored → `app/docs/dev-design/2026-08-12-k26-k29-dictation-reliability-and-itn-protection.md`. Statuses flipped to `🔄` pending execution. User confirmed running the v1.1 May build — bug 1 (bare-"no" backtrack) is already fixed in current code (K-29). ITN misfires verified against the real Nemo library binary with a standalone probe; placeholder masking is the only working protection (identity rules fail); digit ranges pass through ITN untouched.

> **K-29 (2026-08-12):** dev plan authored → `app/docs/dev-design/2026-08-12-k26-k29-dictation-reliability-and-itn-protection.md`. Status flipped to `🔄` pending execution. Root cause: stale installed build (v1.1, tagged 2026-05-19, predates the engine extraction where bare "no" was removed from backtrack cues); current code + existing pin (`TextCleanupEngineTests.swift:48-50`) already cover the fix.

---

## Execution-notes appendix: raw ITN probe evidence (2026-08-12)

Standalone C probe linked against `NemoTextProcessing.xcframework/macos-arm64_x86_64/libnemo_text_processing.a` (`nemo_normalize_sentence`):

| Input | Raw ITN output | Protector verdict |
|---|---|---|
| "I'm writing a two to three pager" | "I'm writing 02:58 pager" | masked → words survive |
| "I'm writing a two three pager" | "I'm writing 5 pager" | run pattern (≥2 simple words) |
| "I'm writing a 2 - 3 pager" / "2-3 pager" | unchanged | no pattern needed (digits safe) |
| "twelve to fourteen people are coming" | "13:48 people are coming" | masked |
| "fifteen to twenty minutes" | "19:45 minutes" | masked |
| "twenty two to three dollars" | "02:38 dollars" | masked ("two to three") |
| "two to three of us are coming" | "02:58 of us are coming" | merged span |
| "Don't worry, we consider you as one of us" | "…as 1 of us" | masked ("one of") |
| "there are two of us" | "there are 2 of us" | masked ("two of") |
| "one of the best engineers" | "1 of the best engineers" | masked |
| "first of all, this is a test" | "1st of all, this is a test" | masked (ordinal idiom) |
| "third of the month" | "the 3rd of the month" | masked (documented trade: stays words) |
| "twenty one of us" | "21 of us" | NOT masked (lookbehind) — still normalizes |
| "call me at five five five one two three four" | "call me at 16 9" | masked (run) |
| "one two three four five six" | "10 05:06" | masked (run) |
| "I'll meet you at two fifty three" | "I'll meet you at 02:53" | NOT masked — still normalizes |
| "see you at quarter to three" | "see you at 02:45" | NOT masked — still normalizes |
| "the year twenty twenty five" | "the year 2025" | NOT masked — still normalizes |
| "a two hundred page report" | "200 page report" | NOT masked — still normalizes |
| "five dollars and fifty cents" | "$5.50" | NOT masked — still normalizes |
| "hundreds of people came" | unchanged | no pattern fires |

Also verified: `nemo_add_rule("one of", "one of")` does NOT prevent "1 of us" (custom rules do not block built-in taggers); the `XXKALAMSPAN<n>XX` token passes through `nemo_normalize_sentence` untouched, even adjacent to digits.

**Bug-1 engine probe (current tree, `TextCleanupEngine.clean` with default config):** "Yep, there is a roadmap meeting, so no problem" → unchanged, 0 edits; "there's no way to do this for them" → unchanged, 0 edits; "scratch that, I meant something else" → "I meant something else" (backtrack still works). v1.1 tag predates the engine extraction commit that removed bare "no" from the backtrack cues (`TextCleanupEngine.swift:584-592` comment documents the removal).
