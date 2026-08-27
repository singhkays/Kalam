import XCTest
import CoreAudio
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

// MARK: - Session timing marks + transport tag (Task 0)

final class SessionTimingMarksTests: XCTestCase {
    func testBeginSessionClearsTimestampsButKeepsTransport() {
        let marks = SessionTimingMarks()
        marks.setTransportTag("bluetooth")
        marks.markEngineStart(at: 10.0)
        marks.markFirstBufferIfNeeded(at: 10.05)

        marks.beginSession()
        let snap = marks.snapshot()
        XCTAssertNil(snap.engineStartAt)
        XCTAssertNil(snap.firstBufferAt)
        XCTAssertEqual(snap.transportTag, "bluetooth")
    }

    func testFirstBufferMarkIsIdempotentWithinSession() {
        let marks = SessionTimingMarks()
        marks.beginSession()
        marks.markFirstBufferIfNeeded(at: 5.0)
        marks.markFirstBufferIfNeeded(at: 5.5)
        marks.markFirstBufferIfNeeded(at: 6.0)
        XCTAssertEqual(marks.snapshot().firstBufferAt, 5.0)
    }

    func testEngineStartLatestWins() {
        let marks = SessionTimingMarks()
        marks.beginSession()
        marks.markEngineStart(at: 1.0)
        // Recovery path re-starts the engine: the later start supersedes.
        marks.markEngineStart(at: 2.0)
        XCTAssertEqual(marks.snapshot().engineStartAt, 2.0)
    }

    func testSnapshotIsValueCopyNotLiveView() {
        let marks = SessionTimingMarks()
        marks.setTransportTag("builtin")
        marks.markEngineStart(at: 1.0)
        let snap = marks.snapshot()
        marks.markEngineStart(at: 9.0)
        XCTAssertEqual(snap.engineStartAt, 1.0)      // stale copy unaffected
        XCTAssertEqual(marks.snapshot().engineStartAt, 9.0)
    }

    func testUnmarkedSessionYieldsNilStamps() {
        let marks = SessionTimingMarks(initialTransportTag: "usb")
        let snap = marks.snapshot()
        XCTAssertNil(snap.engineStartAt)
        XCTAssertNil(snap.firstBufferAt)
        XCTAssertEqual(snap.transportTag, "usb")
    }
}

final class AudioTransportTagTests: XCTestCase {
    private func assertLabel(_ raw: UInt32?, _ expected: String, line: UInt = #line) {
        XCTAssertEqual(AudioTransportTag.label(forTransportType: raw), expected, line: line)
    }

    func testKnownTransportsMapToBaselineBuckets() {
        assertLabel(kAudioDeviceTransportTypeBuiltIn, "builtin")
        assertLabel(kAudioDeviceTransportTypeUSB, "usb")
        assertLabel(kAudioDeviceTransportTypeBluetooth, "bluetooth")
        assertLabel(kAudioDeviceTransportTypeBluetoothLE, "bluetooth")
        assertLabel(kAudioDeviceTransportTypeAggregate, "aggregate")
        assertLabel(kAudioDeviceTransportTypeVirtual, "virtual")
        assertLabel(kAudioDeviceTransportTypeAutoAggregate, "virtual")
    }

    func testAbsentAndUnknownInputsClassifyHonesty() {
        assertLabel(nil, "unknown")                       // query unavailable
        assertLabel(0x9999_9999, "other")                // reserved/unmapped value
        XCTAssertEqual(AudioTransportTag.label(forDeviceID: nil), "unknown")
        XCTAssertEqual(AudioTransportTag.label(forDeviceID: 0), "unknown")  // kAudioObjectUnknown
    }
}
