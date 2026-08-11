import Testing
import Foundation
@testable import KalamTextEngine

@Test func fillerRemovalStandaloneAndMultiWord() {
    let result = TextCleanupEngine().clean("um I think we should, you know, ship this", configuration: config())
    #expect(!result.text.lowercased().contains("um"))
    #expect(!result.text.lowercased().contains("you know"))
    #expect(result.stats.fillerRemovals >= 2)
}

@Test func fillerRemovalDoesNotTouchEmbeddedWords() {
    let result = TextCleanupEngine().clean("aluminum forum summary", configuration: config())
    #expect(result.text == "aluminum forum summary")
}

@Test func fillerHeuristicDoesNotDeleteMum() {
    // "mum" was previously deleted because the old character-set heuristic
    // treated any token made only of {u,m} as a filler. "mum" is a real word.
    let result = TextCleanupEngine().clean("send it to mum", configuration: config())
    #expect(result.text == "send it to mum")
    #expect(result.stats.fillerRemovals == 0)
}

@Test func fillerHeuristicDoesNotDeleteHuh() {
    // "huh" was previously deleted by the same heuristic ({u,h} variant).
    let result = TextCleanupEngine().clean("huh that works", configuration: config())
    #expect(result.text == "huh that works")
    #expect(result.stats.fillerRemovals == 0)
}

@Test func fillerHeuristicStillDeletesRealFillers() {
    // Regression: ensure the allow-list still catches real fillers.
    let result = TextCleanupEngine().clean("um I think uh we should", configuration: config())
    #expect(result.text == "I think we should")
    #expect(result.stats.fillerRemovals >= 2)
}

@Test func backtrackScratchThatRemovesPriorClause() {
    let result = TextCleanupEngine().clean("send this now scratch that send it tomorrow", configuration: config())
    #expect(result.text == "send it tomorrow")
    #expect(result.stats.backtrackEdits > 0)
}

@Test func backtrackNoCueDoesNotDestroyNormalSentence() {
    // "no" is a common word in normal prose, not a correction cue.
    // Previously "no" was treated as a backtrack cue, which deleted the
    // preceding clause: "there is no way to do this" -> "way to do this".
    let result = TextCleanupEngine().clean("there is no way to do this", configuration: config())
    #expect(result.text == "there is no way to do this")
    #expect(result.stats.backtrackEdits == 0)
}

@Test func backtrackActuallyDoesNotDestroyNormalSentence() {
    // "actually" is also common in normal prose.
    let result = TextCleanupEngine().clean("actually that is correct", configuration: config())
    #expect(result.text == "actually that is correct")
    #expect(result.stats.backtrackEdits == 0)
}

@Test func numberedListFormatting() {
    let result = TextCleanupEngine().clean("plan is one gather logs two isolate bug three ship fix", configuration: config())
    #expect(result.text == "plan is:\n1. gather logs\n2. isolate bug\n3. ship fix")
    #expect(result.stats.listItemsFormatted == 3)
}

@Test func numberedListFormattingNumericMarkers() {
    let result = TextCleanupEngine().clean("1 item, 2 item, 3 item.", configuration: config())
    #expect(result.text == "1. item\n2. item\n3. item")
    #expect(result.stats.listItemsFormatted == 3)
}

@Test func numberedListFormattingPunctuation() {
    let result = TextCleanupEngine().clean("one item. two item. three item.", configuration: config())
    #expect(result.text == "1. item\n2. item\n3. item")
    #expect(result.stats.listItemsFormatted == 3)
}

@Test func numberedListFormattingNonSequential() {
    let result = TextCleanupEngine().clean("1 item 3 item", configuration: config())
    #expect(result.text == "1 item 3 item")
    #expect(result.stats.listItemsFormatted == 0)
}

@Test func numberedListFormattingTruncatesOnBadItem() {
    // Previously, one invalid item (too long) caused the entire list to be
    // aborted (listItemsFormatted == 0). Now the list is truncated at the
    // first bad item, preserving valid items collected before it.
    let longItem = "this item has way too many words to be a valid list item because it exceeds the twenty word limit set by the code"
    let input = "plan is one first valid item two second valid item three \(longItem) four fourth valid item"
    let result = TextCleanupEngine().clean(input, configuration: config())
    // Items 1 and 2 are valid and should be formatted; item 3 is too long
    // and causes truncation, so item 4 is never reached.
    #expect(result.stats.listItemsFormatted == 2)
    #expect(result.text.contains("1. first valid item"))
    #expect(result.text.contains("2. second valid item"))
}

@Test func numberedListFormattingShortSequence() {
    let result = TextCleanupEngine().clean("1 short 2 test", configuration: config())
    #expect(result.text == "1. short\n2. test")
    #expect(result.stats.listItemsFormatted == 2)
}

@Test func numberedListFormattingWithOutofSequenceNumbersAndLongPrefix() {
    let input = "From Hell to 1968 to Siri in 2011 we have come so far 1 computers now ununderstand 2 machines listen to words 3 voice controls the future in 20 thirty."
    let result = TextCleanupEngine().clean(input, configuration: config())
    let expected = """
From Hell to 1968 to Siri in 2011 we have come so far
1. computers now ununderstand
2. machines listen to words
3. voice controls the future in 20 thirty
"""
    #expect(result.text == expected)
    #expect(result.stats.listItemsFormatted == 3)
}

@Test func numberedListFormattingFalsePositives() {
    let input = "From Star Trek in 1966 to Siri in 2011 we have come far. One computers now understand. Two machines listen to words. Three voice controls the future in 2030. Four humanity speaks to AI at 5 billion devices worldwide."
    let result = TextCleanupEngine().clean(input, configuration: config())
    let expected = """
From Star Trek in 1966 to Siri in 2011 we have come far.
1. computers now understand
2. machines listen to words
3. voice controls the future in 2030
4. humanity speaks to AI at 5 billion devices worldwide
"""
    #expect(result.text == expected)
    #expect(result.stats.listItemsFormatted == 4)
}

@Test func numberedListFormattingDoesNotSplitCardinalNumbersInSentence() {
    let result = TextCleanupEngine().clean("I have one apple and two Apples and even three apple's", configuration: config())
    #expect(result.text == "I have one apple and two Apples and even three apple's")
    #expect(result.stats.listItemsFormatted == 0)
}

@Test func backtrackWithinListPreservesEarlierItems() {
    let input = "plan is one get the logs two check the scratch that two investigate the crash three ship the fix"
    let result = TextCleanupEngine().clean(input, configuration: config())
    #expect(result.text == "plan is:\n1. get the logs\n2. investigate the crash\n3. ship the fix")
    #expect(result.stats.backtrackEdits > 0)
    #expect(result.stats.listItemsFormatted == 3)
}

@Test func bareNoIsNotTreatedAsBacktrackCue() {
    // Bare "no" is common in normal prose — never a correction cue.
    let result = TextCleanupEngine().clean("book me tomorrow no book me Friday", configuration: config())
    #expect(result.text == "book me tomorrow no book me Friday")
    #expect(result.stats.backtrackEdits == 0)
}

@Test func punctuationNormalization() {
    let result = TextCleanupEngine().clean("hello ,world!!this is fine", configuration: config())
    #expect(result.text == "hello, world! this is fine")
    #expect(result.stats.punctuationEdits > 0)
}

@Test func corpusSmokeSet() {
    for transcript in sampleCorpus {
        let result = TextCleanupEngine().clean(transcript, configuration: config())
        #expect(!result.text.isEmpty, "Unexpected empty output for: \(transcript)")
    }
}

@Test func configurationBoundedTimeout() {
    var config = TextCleanupConfiguration.defaults
    config.grammarTimeoutMs = 1_000
    #expect(config.boundedGrammarTimeoutMs == 400)

    config.grammarTimeoutMs = 10
    #expect(config.boundedGrammarTimeoutMs == 25)

    config.grammarTimeoutMs = 175
    #expect(config.boundedGrammarTimeoutMs == 175)
}

@Test func configurationDefaultsGrammarMode() {
    #expect(TextCleanupConfiguration.defaults.grammarMode == .light)

    var explicitFull = TextCleanupConfiguration.defaults
    explicitFull.grammarMode = .full
    #expect(explicitFull.grammarMode == .full)
}

@Test func configurationPersistenceRoundTrip() {
    let suiteName = "TextCleanupEngineTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Unable to create isolated defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var configuration = TextCleanupConfiguration.defaults
    configuration.grammarMode = .full
    configuration.grammarTimeoutMs = 175
    configuration.save(to: defaults)

    let loaded = TextCleanupConfiguration.load(from: defaults)
    #expect(loaded.grammarMode == .full)
    #expect(loaded.grammarTimeoutMs == 175)
}

@Test func configurationSavesBoundedTimeout() {
    let suiteName = "TextCleanupEngineTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Unable to create isolated defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var configuration = TextCleanupConfiguration.defaults
    configuration.grammarTimeoutMs = 1_000
    configuration.save(to: defaults)

    let loaded = TextCleanupConfiguration.load(from: defaults)
    #expect(loaded.grammarTimeoutMs == 400)
}

// MARK: - Helpers

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

private let sampleCorpus: [String] = [
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
