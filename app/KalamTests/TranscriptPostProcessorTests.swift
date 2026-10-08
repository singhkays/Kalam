import XCTest
@testable import Kalam_test
import KalamTextEngine

/// off-main post-processing: the post-ASR text stages (cleanup -> ITN -> dictionary) extracted
/// from the MainActor-inherited transcription task into a Sendable
/// `TranscriptPostProcessor`. These pins cover behavior parity with the old
/// inline pipeline; the off-main hop itself is exercised by
/// `AppDelegate.postProcessTranscript` in production.
final class TranscriptPostProcessorTests: XCTestCase {

    private func makeProcessor(
        entries: [DictionaryEntry] = [],
        config: TextCleanupConfiguration = .defaults
    ) -> TranscriptPostProcessor {
        // Test-only compile is fine; tests are not the perf path. Production
        // snapshots the manager's already-current engine instead.
        TranscriptPostProcessor(
            cleanupConfig: config,
            dictionaryEngine: ReplacementCompiler.compile(entries: entries)
        )
    }

    func testRunsCleanupFillerRemovalAndPunctuation() {
        let out = makeProcessor().process("um hello ,world!!this is fine")
        XCTAssertTrue(out.text.contains("hello, world! this is fine"), "got: \(out.text)")
        XCTAssertGreaterThan(out.stats.punctuationEdits, 0)
    }

    func testAppliesDictionaryReplacementsFromSnapshot() {
        let entry = DictionaryEntry(trigger: "open ai", replacement: "OpenAI")
        let out = makeProcessor(entries: [entry]).process("i use open ai daily")
        XCTAssertEqual(out.text, "i use OpenAI daily")
        XCTAssertEqual(out.replacements, 1)
    }

    func testDecimalSurvivesEndToEnd() {
        // decimal and time punctuation corruption companion: the post-processing path must behave identically to
        // the engine — no decimal splitting may leak through.
        let out = makeProcessor().process("it costs $3.50 today")
        XCTAssertFalse(out.text.contains(". "), "decimal split leaked through: \(out.text)")
    }

    func testEmptyInputPassesThroughWithoutReplacements() {
        let out = makeProcessor().process("")
        XCTAssertEqual(out.replacements, 0)
    }

    // cleanup master toggle gating ITN: the Cleanup master must stop ITN too — "types exactly what it
    // heard" means no hidden number normalization.
    func testCleanupMasterOffSkipsITN() {
        var config = TextCleanupConfiguration.defaults
        config.enabled = false
        let out = makeProcessor(config: config).process("twenty one of us")
        XCTAssertFalse(out.itnEnabled, "ITN ran although the Cleanup master is off")
        XCTAssertFalse(out.itnChanged)
        XCTAssertEqual(out.text, "twenty one of us")
    }

    // Scoped decision (2026-08-24): the dictionary stays independent of the
    // Cleanup master — curated substitutions are wanted even with rules off.
    func testDictionaryStillAppliesWhenCleanupOff() {
        var config = TextCleanupConfiguration.defaults
        config.enabled = false
        let entry = DictionaryEntry(trigger: "open ai", replacement: "OpenAI")
        let out = makeProcessor(entries: [entry], config: config).process("i use open ai daily")
        XCTAssertEqual(out.text, "i use OpenAI daily")
        XCTAssertEqual(out.replacements, 1)
    }

    // currency cents stranding fix: Nemo strands "cents" when the utterance carries sentence-final
    // punctuation ("Five dollars and fifty cents." -> "$5.50 cents.");
    // the pipeline must render the conversion plus the terminator.
    func testTerminalPeriodDoesNotStrandCents() {
        let out = makeProcessor().process("Five dollars and fifty cents.")
        XCTAssertEqual(out.text, "$5.50.", "got: \\(out.text)")
    }

    func testTerminalBangAndQuestionAlsoRestored() {
        XCTAssertEqual(makeProcessor().process("Five dollars and fifty cents!").text, "$5.50!")
        XCTAssertEqual(makeProcessor().process("Five dollars and fifty cents?").text, "$5.50?")
    }

    func testCurrencyWithoutTerminalPunctuationUnchanged() {
        XCTAssertEqual(makeProcessor().process("five dollars and fifty cents").text, "$5.50")
    }

    // 2026-10-02: "Call me at five." pasted live as "Call me at 5". A headless
    // probe of the full pipeline proved the period survives here ("Call me at
    // 5."): the live loss was ASR-level (Parakeet emitted no period), and
    // cleanup never adds terminal periods — it only spaces existing ones. These
    // pins lock the pipeline half so a future period-eater fails loudly.
    func testTerminalPeriodSurvivesSingleWordNumberConversion() {
        XCTAssertEqual(makeProcessor().process("Call me at five.").text, "Call me at 5.")
    }

    func testTerminalPeriodSurvivesTimeAndDecimalConversion() {
        XCTAssertEqual(makeProcessor().process("Meeting at ten thirty.").text, "Meeting at 10:30.")
        XCTAssertEqual(makeProcessor().process("The version is two point five.").text, "The version is 2.5.")
    }

    // Snapshot-engine parity: a once-compiled engine applied by the processor
    // must match per-call compile output across phrase rules, single-word
    // case mimicry, disabled entries, and empty input. (All pre-existing tests
    // above already pin this — their bodies are unchanged and now run on a
    // snapshot — this one covers the disabled/empty corners explicitly.)
    func testSnapshotEngineMatchesFreshCompileOutput() {
        let processor = makeProcessor(entries: [
            DictionaryEntry(trigger: "open ai", replacement: "OpenAI"),
            DictionaryEntry(trigger: "apple", replacement: "orange"),
            DictionaryEntry(trigger: "kalam", replacement: "KALAM", isEnabled: false),
        ])
        XCTAssertEqual(processor.process("i use open ai daily").text, "i use OpenAI daily")
        XCTAssertEqual(processor.process("I want an Apple").text, "I want an Orange")
        XCTAssertEqual(processor.process("kalam rules").text, "kalam rules")
        let empty = processor.process("")
        XCTAssertEqual(empty.replacements, 0)
    }
}
