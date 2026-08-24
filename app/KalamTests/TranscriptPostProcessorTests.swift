import XCTest
@testable import Kalam_test
import KalamTextEngine

/// K-38: the post-ASR text stages (cleanup -> ITN -> dictionary) extracted
/// from the MainActor-inherited transcription task into a Sendable
/// `TranscriptPostProcessor`. These pins cover behavior parity with the old
/// inline pipeline; the off-main hop itself is exercised by
/// `AppDelegate.postProcessTranscript` in production.
final class TranscriptPostProcessorTests: XCTestCase {

    private func makeProcessor(
        entries: [DictionaryEntry] = [],
        config: TextCleanupConfiguration = .defaults
    ) -> TranscriptPostProcessor {
        TranscriptPostProcessor(
            cleanupConfig: config,
            dictionaryEntries: entries
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
        // K-34 companion: the post-processing path must behave identically to
        // the engine — no decimal splitting may leak through.
        let out = makeProcessor().process("it costs $3.50 today")
        XCTAssertFalse(out.text.contains(". "), "decimal split leaked through: \(out.text)")
    }

    func testEmptyInputPassesThroughWithoutReplacements() {
        let out = makeProcessor().process("")
        XCTAssertEqual(out.replacements, 0)
    }

    // K-44: the Cleanup master must stop ITN too — "types exactly what it
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

    // K-45: Nemo strands "cents" when the utterance carries sentence-final
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
}
