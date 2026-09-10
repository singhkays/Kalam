import XCTest
@testable import Kalam_test

/// Phase 2 probe: the published presentation state must replace its whole value
/// exactly once per transition and keep timer ticks out of the revision count.
@MainActor
final class IndicatorPresentationStateTests: XCTestCase {

    func testPublishReplacesTheWholePresentationAndBumpsRevisionOnce() {
        let state = IndicatorPresentationState()
        let before = state.revision

        var presentation = IndicatorPresentationState.Presentation()
        presentation.message = "Transcribing…"
        presentation.canonicalState = .transcribing
        state.publish(
            presentation: presentation,
            session: IndicatorPresentationState.Session(style: .whisper, usesDarkAppearance: true, reduceMotion: false)
        )

        XCTAssertEqual(state.revision, before + 1, "exactly one publish per transition")
        XCTAssertEqual(state.presentation.message, "Transcribing…")
        XCTAssertEqual(state.session.style, .whisper)
        XCTAssertEqual(state.presentation.canonicalState, .transcribing)
    }

    func testPublishElapsedMovesOnlyTheClock() {
        let state = IndicatorPresentationState()
        let before = state.revision

        state.publishElapsed("00:07")

        XCTAssertEqual(state.elapsed, "00:07")
        XCTAssertEqual(state.revision, before, "timer ticks never count as transitions")
    }

    func testWaveformIngestPushesOneBarThroughThePureMath() {
        let state = IndicatorPresentationState()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]

        for _ in 0..<3 {
            state.waveform.ingest(samples: loud, active: true)
        }

        XCTAssertEqual(state.waveform.envelope.history.count, 3)
    }

    func testWaveformResetReturnsToSilence() {
        let state = IndicatorPresentationState()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]
        state.waveform.ingest(samples: loud, active: true)

        state.waveform.reset()

        XCTAssertTrue(state.waveform.envelope.history.isEmpty)
        XCTAssertEqual(state.waveform.glyph.gain, 1.0)
    }
}