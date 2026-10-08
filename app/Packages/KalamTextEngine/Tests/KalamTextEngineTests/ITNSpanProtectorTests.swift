import Testing
import Foundation
@testable import KalamTextEngine

// ITN span protection: ITN span protection. Every test documents a real library behavior
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

// MARK: digit-shaped ITN protection (probed against the real library, 2026-08-24):
// separator variants + mixed word/digit runs

@Test func commaSeparatedRunIsMasked() {
    // Raw ITN: "five, five, five, one, two, three, four" -> "... three, 4"
    #expect(masked("five, five, five, one, two, three, four").contains("XXKALAMSPAN0XX"))
}

@Test func periodSeparatedRunIsMasked() {
    #expect(masked("Five. Five. Five. One. Two. Three. Four.").contains("XXKALAMSPAN0XX"))
}

@Test func mixedWordDigitRunIsMasked() {
    // Raw ITN: "five 5 five 1 two three 4" -> "5 5 5 1 02:03 4"
    #expect(masked("five 5 five 1 two three 4").contains("XXKALAMSPAN0XX"))
}

@Test func shortDigitPairsStayUnmasked() {
    // Fewer than 3 tokens never mask; Nemo leaves short digit pairs alone.
    #expect(masked("see 5 7 tomorrow") == "see 5 7 tomorrow")
}

// MARK: spoken-time ITN composition misfire (probed 2026-08-24): spoken-time sum composition ("40")

@Test func temporalSpanRendersClockTime() {
    let p = ITNSpanProtector()
    let result = p.protect("meeting at ten thirty")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].original == "at ten thirty")
    #expect(result.spans[0].rendered == "at 10:30")
    #expect(p.restore(result.text, spans: result.spans) == "meeting at 10:30")
}

@Test func teensTimeRendersWithPrefix() {
    let result = ITNSpanProtector().protect("leave around twelve fifteen")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].rendered == "around 12:15")
}

@Test func yearShapesAreNotTemporal() {
    // Hours are restricted to one..twelve, so "by twenty twenty six" stays
    // unmasked and Nemo renders the year (2026) natively.
    #expect(masked("done by twenty twenty six") == "done by twenty twenty six")
}

@Test func threeTokenTimeStaysUnmasked() {
    // Probe boundary: Nemo renders hour+tens+UNIT correctly ("02:53"), so
    // only the two-token sum-broken shape ("ten thirty" -> "40") is masked.
    #expect(masked("I'll meet you at two fifty three") == "I'll meet you at two fifty three")
}

// MARK: bare-conjunction sums (2026-10-08): Nemo SUMS "one and four" -> "5"

@Test func oneAndFourIsMasked() {
    // Raw ITN: "one and four" -> "5"
    #expect(masked("one and four").contains("XXKALAMSPAN0XX"))
}

@Test func twoAndThreeIsMasked() {
    // Raw ITN: "two and three" -> "5"
    #expect(masked("I said two and three today").contains("XXKALAMSPAN0XX"))
}

@Test func betweenAndIsMasked() {
    // Raw ITN: "between five and ten" -> "between 15"
    let result = ITNSpanProtector().protect("between five and ten")
    #expect(result.spans.count == 1)
    #expect(result.spans[0].original == "five and ten")
}

@Test func largerAndIsMasked() {
    // Raw ITN concatenates instead of summing here ("twenty and five" ->
    // "2005"), still garbage — mask it verbatim.
    #expect(masked("twenty and five").contains("XXKALAMSPAN0XX"))
}

@Test func hundredAndFiveIsNotMasked() {
    // Nemo-correct quantity ("one hundred and five" -> "105") must still
    // normalize: the multiplier exclusion keeps it unmasked.
    #expect(masked("one hundred and five") == "one hundred and five")
}

@Test func currencyAndIsNotMasked() {
    // Nemo-correct currency ("five dollars and fifty cents" -> "$5.50"):
    // "dollars" sits between the number and "and", so no match.
    #expect(masked("five dollars and fifty cents") == "five dollars and fifty cents")
}

@Test func andRestoreRoundTrips() {
    #expect(restored("one and four") == "one and four")
    #expect(restored("between five and ten") == "between five and ten")
}

// MARK: digit/mixed ranges (2026-10-08): pin "5 to 10" verbatim

@Test func digitRangeIsMasked() {
    #expect(masked("count from 5 to 10").contains("XXKALAMSPAN0XX"))
}

@Test func mixedRangeIsMasked() {
    #expect(masked("five to 10").contains("XXKALAMSPAN0XX"))
    #expect(masked("5 to ten").contains("XXKALAMSPAN0XX"))
}

@Test func digitThroughIsMasked() {
    #expect(masked("5 through 10").contains("XXKALAMSPAN0XX"))
}

@Test func mixedAndIsMasked() {
    // Raw ITN drops "and" ("one and 4" -> "1 4") — mask it verbatim.
    #expect(masked("one and 4").contains("XXKALAMSPAN0XX"))
}
