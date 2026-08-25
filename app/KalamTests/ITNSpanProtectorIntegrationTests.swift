import XCTest
import KalamTextEngine
@testable import Kalam_test

// ITN span protection: end-to-end protector + real NemoTextProcessing library. Skips when
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
