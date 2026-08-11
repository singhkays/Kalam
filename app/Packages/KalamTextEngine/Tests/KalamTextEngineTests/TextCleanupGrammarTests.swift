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
