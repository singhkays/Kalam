import XCTest
@testable import Kalam_test

final class TextCleanupServiceTests: XCTestCase {
    private let service = TextCleanupService.shared

    private func config(
        enabled: Bool = true,
        removeFillers: Bool = true,
        backtrack: Bool = true,
        listFormatting: Bool = true,
        punctuation: Bool = true,
        grammarMode: TextCleanupGrammarMode = .off,
        grammarTimeoutMs: Int = 100
    ) -> TextCleanupConfiguration {
        TextCleanupConfiguration(
            enabled: enabled,
            removeFillers: removeFillers,
            backtrack: backtrack,
            listFormatting: listFormatting,
            punctuation: punctuation,
            grammarMode: grammarMode,
            grammarTimeoutMs: grammarTimeoutMs
        )
    }

    func testFillerRemovalStandaloneAndMultiWord() {
        let input = "um I think we should, you know, ship this"
        let result = service.clean(input, configuration: config())
        XCTAssertFalse(result.text.lowercased().contains("um"))
        XCTAssertFalse(result.text.lowercased().contains("you know"))
        XCTAssertGreaterThanOrEqual(result.stats.fillerRemovals, 2)
    }

    func testFillerRemovalDoesNotTouchEmbeddedWords() {
        let input = "aluminum forum summary"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "aluminum forum summary")
    }

    func testBacktrackScratchThatRemovesPriorClause() {
        let input = "send this now scratch that send it tomorrow"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "send it tomorrow")
        XCTAssertGreaterThan(result.stats.backtrackEdits, 0)
    }

    func testBacktrackNoCueRemovesPriorClause() {
        let input = "book me tomorrow no book me Friday"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "book me Friday")
    }

    func testNumberedListFormatting() {
        let input = "plan is one gather logs two isolate bug three ship fix"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "plan is\n1. gather logs\n2. isolate bug\n3. ship fix")
        XCTAssertEqual(result.stats.listItemsFormatted, 3)
    }

    func testNumberedListFormattingNumericMarkers() {
        let input = "1 item, 2 item, 3 item."
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "1. item\n2. item\n3. item")
        XCTAssertEqual(result.stats.listItemsFormatted, 3)
    }

    func testNumberedListFormattingPunctuation() {
        let input = "one item. two item. three item."
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "1. item\n2. item\n3. item")
        XCTAssertEqual(result.stats.listItemsFormatted, 3)
    }

    func testNumberedListFormattingNonSequential() {
        let input = "1 item 3 item"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "1 item 3 item") // Shouldn't format
        XCTAssertEqual(result.stats.listItemsFormatted, 0)
    }

    func testNumberedListFormattingShortSequence() {
        let input = "1 short 2 test"
        let result = service.clean(input, configuration: config())
        // Should parse because each item has >=1 word and <=14 words, and starts with 1, seq is valid.
        XCTAssertEqual(result.text, "1. short\n2. test")
        XCTAssertEqual(result.stats.listItemsFormatted, 2)
    }

    func testNumberedListFormattingWithOutofSequenceNumbersAndLongPrefix() {
        let input = "From Hell to 1968 to Siri in 2011 we have come so far 1 computers now ununderstand 2 machines listen to words 3 voice controls the future in 20 thirty."
        let result = service.clean(input, configuration: config())
        let expected = """
From Hell to 1968 to Siri in 2011 we have come so far
1. computers now ununderstand
2. machines listen to words
3. voice controls the future in 20 thirty
"""
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.stats.listItemsFormatted, 3)
    }

    func testNumberedListFormattingFalsePositives() {
        let input = "From Star Trek in 1966 to Siri in 2011 we have come far. One computers now understand. Two machines listen to words. Three voice controls the future in 2030. Four humanity speaks to AI at 5 billion devices worldwide."
        let result = service.clean(input, configuration: config())
        let expected = """
From Star Trek in 1966 to Siri in 2011 we have come far
1. computers now understand
2. machines listen to words
3. voice controls the future in 2030
4. humanity speaks to AI at 5 billion devices worldwide
"""
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.stats.listItemsFormatted, 4)
    }

    func testPunctuationNormalization() {
        let input = "hello ,world!!this is fine"
        let result = service.clean(input, configuration: config())
        XCTAssertEqual(result.text, "hello, world! this is fine")
        XCTAssertGreaterThan(result.stats.punctuationEdits, 0)
    }

    func testProtectedTermsStayUntouchedInGrammarMode() {
        let input = "this APIKey and GPT4o should stay as is"
        let result = service.clean(input, configuration: config(grammarMode: .full, grammarTimeoutMs: 150))
        XCTAssertTrue(result.text.contains("APIKey"))
        XCTAssertTrue(result.text.contains("GPT4o"))
    }

    func testGrammarSkippedForLongTranscripts() {
        let long = String(repeating: "this is a long transcript segment ", count: 80)
        let result = service.clean(long, configuration: config(grammarMode: .light, grammarTimeoutMs: 100))
        XCTAssertTrue(result.stats.grammarAttempted)
        XCTAssertTrue(result.stats.grammarSkippedForLength)
        XCTAssertEqual(result.stats.grammarEdits, 0)
    }

    func testTimeoutNeverReturnsEmpty() {
        let input = "this should always return content"
        let result = service.clean(input, configuration: config(grammarMode: .full, grammarTimeoutMs: 25))
        XCTAssertFalse(result.text.isEmpty)
    }

    func testCorpusSmokeSet() {
        let corpus = sampleCorpus
        XCTAssertGreaterThanOrEqual(corpus.count, 50)

        for transcript in corpus {
            let result = service.clean(transcript, configuration: config(grammarMode: .off))
            XCTAssertFalse(result.text.isEmpty, "Unexpected empty output for: \(transcript)")
        }
    }

    private var sampleCorpus: [String] {
        [
            "um can you send that now",
            "uh please make a note for friday",
            "i mean i think this is fine",
            "you know we should ship today",
            "kind of feels risky",
            "sort of unclear right now",
            "actually update that deadline",
            "no move it to next week",
            "scratch that move it to Monday",
            "ignore that create a new ticket",
            "delete that add a reminder",
            "hello ,world!!this is fine",
            "one gather logs two isolate bug",
            "first draft proposal second review budget",
            "book me a flight to seattle",
            "book me a hotel in sf",
            "add a calendar event tomorrow",
            "reply to the latest email",
            "send status update to team",
            "share the document link",
            "open the pull request",
            "create a branch for fix",
            "run tests and post results",
            "ship the patch after review",
            "we need qa signoff",
            "mark this as blocked",
            "mark this as ready",
            "follow up with legal",
            "prepare the board summary",
            "schedule one on one",
            "queue release for tonight",
            "check logs for payment service",
            "check logs for auth service",
            "triage the incident quickly",
            "write a retro note",
            "capture action items",
            "capture open questions",
            "close stale issues",
            "update changelog now",
            "document the rollout steps",
            "run migration plan",
            "confirm rollback strategy",
            "alert support channel",
            "notify stakeholders",
            "publish release notes",
            "send invoice reminder",
            "confirm customer meeting",
            "follow up on proposal",
            "track weekly metrics",
            "summarize weekly metrics",
            "prepare demo script",
            "record product walkthrough",
            "send contract revision",
            "review security checklist",
            "validate backup restore",
            "update runbook entry",
            "move ticket to in progress",
            "move ticket to done",
            "create onboarding checklist",
            "draft hiring plan"
        ]
    }
}
