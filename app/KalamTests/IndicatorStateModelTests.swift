import XCTest
@testable import Kalam_test

final class IndicatorStateModelTests: XCTestCase {

    // MARK: - Presentations (one per canonical state)

    func testListeningPresentation() {
        let p = IndicatorStateModel.presentation(state: .listening, targetApp: "Notes")
        XCTAssertEqual(p.message, "")
        XCTAssertNil(p.primaryActionTitle)
        XCTAssertNil(p.secondaryActionTitle)
        XCTAssertTrue(p.showsWaveform, "listening shows the live waveform")
        XCTAssertFalse(p.showsShimmer)
    }

    func testPausingPresentation() {
        let p = IndicatorStateModel.presentation(state: .pausing, targetApp: "Notes")
        XCTAssertEqual(p.message, "")
        XCTAssertNil(p.primaryActionTitle)
        XCTAssertNil(p.secondaryActionTitle)
        XCTAssertTrue(p.showsWaveform, "pausing keeps the waveform visible")
        XCTAssertFalse(p.showsShimmer)
    }

    func testTranscribingPresentation() {
        let p = IndicatorStateModel.presentation(state: .transcribing, targetApp: "Notes")
        XCTAssertEqual(p.message, "Transcribing")
        XCTAssertNil(p.primaryActionTitle)
        XCTAssertNil(p.secondaryActionTitle)
        XCTAssertFalse(p.showsWaveform)
        XCTAssertTrue(p.showsShimmer, "transcribing shimmers while it works")
    }

    func testHeldPresentation() {
        let p = IndicatorStateModel.presentation(state: .held, targetApp: "Notes")
        XCTAssertEqual(p.message, "Transcript ready, paste into Notes?")
        XCTAssertEqual(p.primaryActionTitle, "Paste")
        XCTAssertEqual(p.secondaryActionTitle, "Discard")
        XCTAssertFalse(p.showsWaveform)
        XCTAssertFalse(p.showsShimmer)

        let other = IndicatorStateModel.presentation(state: .held, targetApp: "TextEdit")
        XCTAssertEqual(other.message, "Transcript ready, paste into TextEdit?",
                       "held message must interpolate the target app")
    }

    func testBlockedPresentation() {
        let p = IndicatorStateModel.presentation(state: .blocked, targetApp: "Notes")
        XCTAssertEqual(p.message, "Microphone not available")
        XCTAssertNil(p.primaryActionTitle)
        XCTAssertEqual(p.secondaryActionTitle, "Open Settings")
        XCTAssertFalse(p.showsWaveform)
        XCTAssertFalse(p.showsShimmer)
    }

    // MARK: - Fallback law (5 states x 3 styles, pinned explicitly)

    func testFallbackLawMatrix() {
        // held/blocked ALWAYS present machined regardless of style;
        // transient states go compact only for whisper/caret.
        let expected: [IndicatorState: [IndicatorStyle: Bool]] = [
            .listening: [.machined: false, .whisper: true, .caret: true],
            .pausing: [.machined: false, .whisper: true, .caret: true],
            .transcribing: [.machined: false, .whisper: true, .caret: true],
            .held: [.machined: false, .whisper: false, .caret: false],
            .blocked: [.machined: false, .whisper: false, .caret: false],
        ]

        for state in [IndicatorState.listening, .pausing, .transcribing, .held, .blocked] {
            for style in IndicatorStyle.allCases {
                XCTAssertEqual(
                    IndicatorStateModel.usesCompactSurface(style: style, state: state),
                    expected[state]?[style],
                    "usesCompactSurface(style: \(style), state: \(state)) violates the fallback law"
                )
            }
        }
    }

    // MARK: - Compact widths

    func testCompactWidthListening() {
        XCTAssertEqual(IndicatorStateModel.compactWidth(state: .listening), 200)
    }

    func testCompactWidthPausing() {
        XCTAssertEqual(IndicatorStateModel.compactWidth(state: .pausing), 200)
    }

    func testCompactWidthTranscribing() {
        XCTAssertEqual(IndicatorStateModel.compactWidth(state: .transcribing), 150)
    }

    func testCompactWidthHeldUsesMachinedFormWidth() {
        XCTAssertEqual(IndicatorStateModel.compactWidth(state: .held), 290)
    }

    func testCompactWidthBlockedUsesMachinedFormWidth() {
        XCTAssertEqual(IndicatorStateModel.compactWidth(state: .blocked), 290)
    }

    func testMachinedFormWidthMatchesControllerMetric() {
        XCTAssertEqual(IndicatorStateModel.machinedFormWidth, 290)
    }
}
