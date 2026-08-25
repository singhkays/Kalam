import XCTest
@testable import Kalam_test

// microphone recovery after sleep or device change: the prepare() early-return was the stale-binding bug — after
// sleep/wake the engine stayed bound to a dead CoreAudio device until the
// user manually reordered microphones.
final class AudioPrepareDecisionTests: XCTestCase {
    func testSkipsWhenFullyPreparedAndNotInvalidated() {
        XCTAssertFalse(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 5, invalidated: false))
    }

    func testReconfiguresWhenDeviceIDChanges() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 6, invalidated: false))
    }

    func testReconfiguresWhenNotPrepared() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: false, lastDeviceID: 5, preferredDeviceID: 5, invalidated: false))
    }

    func testReconfiguresWhenInvalidated() {
        XCTAssertTrue(AudioPrepareDecision.shouldReconfigure(isPrepared: true, lastDeviceID: 5, preferredDeviceID: 5, invalidated: true))
    }

    func testInvalidateFlipsFlagOnRecorder() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isPreparedStateInvalidatedForTesting)
        recorder.invalidatePreparedState()
        XCTAssertTrue(recorder.isPreparedStateInvalidatedForTesting)
    }
}
