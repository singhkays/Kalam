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
        // Seed keydown at a deterministic reference time instead of mark(.hotkeyReceived):
        // mark() stamps CFAbsoluteTimeGetCurrent() (~8.1e8), and these synthetic offsets
        // would then be REJECTED by the out-of-order guard (earlier than the seed).
        // Base 0 also keeps Int((t - start) * 1000) exact — a large base truncates
        // through the float grid (10 ms -> 9).
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
        probe.mark(.hotkeyReceived)
        probe.markWithTime(.engineStarted, CFAbsoluteTimeGetCurrent())
        // A late reply trying to backfill an earlier stage must not corrupt the sequence.
        probe.markWithTime(.guardsCompleted, Date().timeIntervalSinceReferenceDate - 100)
        XCTAssertNil(probe.summaryLine())            // guardsCompleted mark was ignored
    }

    func testNonContiguousButOrderedMarksAccepted() {
        var probe = RecordingStartLatencyProbe()
        let t0 = CFAbsoluteTimeGetCurrent()
        probe.markWithTime(.hotkeyReceived, t0)
        probe.markWithTime(.indicatorShown, t0 + 0.095)
        probe.markWithTime(.audioPrepared, t0 + 0.097)   // later than indicator: accepted
        XCTAssertNil(probe.summaryLine())                // engineStarted still missing
    }
}
