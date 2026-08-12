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
