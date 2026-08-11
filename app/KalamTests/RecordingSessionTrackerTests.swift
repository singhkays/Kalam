import XCTest
@testable import Kalam_test

final class RecordingSessionTrackerTests: XCTestCase {
    func testBeginNewRecordingAdvancesGeneration() {
        var tracker = RecordingSessionTracker()
        let first = tracker.beginNewRecording()
        XCTAssertEqual(first, 1)
        XCTAssertTrue(tracker.isCurrent(first))

        let second = tracker.beginNewRecording()
        XCTAssertEqual(second, 2)
        XCTAssertFalse(
            tracker.isCurrent(first),
            "K-01: a superseded recording's generation must no longer be current"
        )
        XCTAssertTrue(tracker.isCurrent(second))
    }

    func testCurrentGenerationReturnsLatest() {
        var tracker = RecordingSessionTracker()
        _ = tracker.beginNewRecording()
        _ = tracker.beginNewRecording()
        XCTAssertEqual(tracker.currentGeneration(), 2)
    }
}
