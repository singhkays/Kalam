import XCTest
@testable import Kalam_test
import KalamTextEngine

/// K-38: the post-ASR text stages (cleanup -> ITN -> dictionary) extracted
/// from the MainActor-inherited transcription task into a Sendable
/// `TranscriptPostProcessor`. These pins cover behavior parity with the old
/// inline pipeline; the off-main hop itself is exercised by
/// `AppDelegate.postProcessTranscript` in production.
final class TranscriptPostProcessorTests: XCTestCase {

    private func makeProcessor(entries: [DictionaryEntry] = []) -> TranscriptPostProcessor {
        TranscriptPostProcessor(
            cleanupConfig: TextCleanupConfiguration.defaults,
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
}
