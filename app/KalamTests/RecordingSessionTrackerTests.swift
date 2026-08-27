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
            "stale-recording paste guard: a superseded recording's generation must no longer be current"
        )
        XCTAssertTrue(tracker.isCurrent(second))
    }

    func testCurrentGenerationReturnsLatest() {
        var tracker = RecordingSessionTracker()
        _ = tracker.beginNewRecording()
        _ = tracker.beginNewRecording()
        XCTAssertEqual(tracker.currentGeneration(), 2)
    }

    // MARK: - K-52: session UUID fan-out

    func testSessionIDIsNilBeforeAnyRecording() {
        let tracker = RecordingSessionTracker()
        XCTAssertNil(tracker.currentSessionID)
        XCTAssertFalse(tracker.isCurrentSession(UUID()))
    }

    func testSessionIDFanOutAndStaleness() throws {
        var tracker = RecordingSessionTracker()
        _ = tracker.beginNewRecording()
        let first = try XCTUnwrap(tracker.currentSessionID)
        XCTAssertTrue(tracker.isCurrentSession(first))

        _ = tracker.beginNewRecording()
        let second = try XCTUnwrap(tracker.currentSessionID)
        XCTAssertNotEqual(first, second, "each session mints a fresh UUID")
        XCTAssertFalse(tracker.isCurrentSession(first),
                       "stale-recording policy: a superseded session's UUID is no longer current")
        XCTAssertTrue(tracker.isCurrentSession(second))
    }

    func testSessionIDsAreUniqueAcrossManySessions() throws {
        var tracker = RecordingSessionTracker()
        var seen = Set<UUID>()
        for _ in 0..<100 {
            _ = tracker.beginNewRecording()
            let id = try XCTUnwrap(tracker.currentSessionID)
            XCTAssertTrue(seen.insert(id).inserted, "UUID collision across sessions")
        }
        XCTAssertEqual(seen.count, 100)
    }
}
