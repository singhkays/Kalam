import XCTest
@testable import Kalam_test

final class RecordingStartLatencyTests: XCTestCase {
    func testSummaryNilUntilAllStagesMarked() {
        var probe = RecordingStartLatencyProbe()
        probe.mark(.hotkeyReceived)
        XCTAssertFalse(probe.isComplete)
        XCTAssertNil(probe.summaryLine())
    }

    func testDeltasAreCumulativeFromHotkeyReceived() throws {
        var probe = RecordingStartLatencyProbe()
        // Base-0 seed: offsets smaller than a real-time seed would be rejected by the ordering guard.
        probe.markWithTime(.hotkeyReceived, 0)
        probe.markWithTime(.guardsCompleted, 0.010)   // 10 ms after keydown
        probe.markWithTime(.audioPrepared, 0.030)     // 30 ms
        probe.markWithTime(.engineStarted, 0.090)     // 90 ms
        probe.markWithTime(.indicatorShown, 0.095)    // 95 ms
        let line = try XCTUnwrap(probe.summaryLine())
        XCTAssertTrue(line.contains("toGuardsMs=10"))
        XCTAssertTrue(line.contains("toPreparedMs=30"))
        XCTAssertTrue(line.contains("toEngineMs=90"))
        XCTAssertTrue(line.contains("toIndicatorMs=95"))
    }

    func testOutOfOrderMarkIgnored() {
        var probe = RecordingStartLatencyProbe()
        let t0 = CFAbsoluteTimeGetCurrent()
        probe.markWithTime(.hotkeyReceived, t0)
        probe.markWithTime(.engineStarted, t0 + 0.090)
        // Late reply trying to backfill an earlier stage: must be ignored...
        probe.markWithTime(.guardsCompleted, t0 - 100)
        // ...so even completing every remaining stage leaves a permanent hole.
        probe.markWithTime(.audioPrepared, t0 + 0.097)
        probe.markWithTime(.indicatorShown, t0 + 0.099)
        XCTAssertFalse(probe.isComplete)
        XCTAssertNil(probe.summaryLine())
    }

    func testNonContiguousButOrderedMarksAccepted() throws {
        var probe = RecordingStartLatencyProbe()
        let t0 = CFAbsoluteTimeGetCurrent()
        // Marks arrive out of ORDER (skipping stages) but each is later than its
        // predecessor: acceptance means the late fills complete the sequence.
        probe.markWithTime(.hotkeyReceived, t0)
        probe.markWithTime(.indicatorShown, t0 + 0.095)
        probe.markWithTime(.audioPrepared, t0 + 0.097)
        probe.markWithTime(.engineStarted, t0 + 0.120)
        probe.markWithTime(.guardsCompleted, t0 + 0.005)   // backward fill, still > hotkeyReceived
        let line = try XCTUnwrap(probe.summaryLine())
        XCTAssertTrue(line.contains("toGuardsMs=5"))
        XCTAssertTrue(line.contains("toPreparedMs=97"))
        XCTAssertTrue(line.contains("toEngineMs=120"))
        XCTAssertTrue(line.contains("toIndicatorMs=95"))
    }
}
