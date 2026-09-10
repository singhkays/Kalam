import XCTest
@testable import Kalam_test

// Capture-pathology gate (Bluetooth-dropout hardening): the mic delivered
// unusable bytes, so the pipeline must refuse to paste rather than
// transcribe garbage. Pure counts/levels — no audio needed.
final class CaptureHealthGuardTests: XCTestCase {
    private func stats(capturedMs: Int, nonZeroRatio: Float, callbacks: Int = 100, dropped: Int = 0) -> CaptureStats {
        let sampleCount = capturedMs * 16 // 16 samples per ms at 16 kHz
        return CaptureStats(
            sampleCount: sampleCount,
            durationMs: capturedMs,
            callbacks: callbacks,
            dropped: dropped,
            nonZeroCount: Int(Float(sampleCount) * nonZeroRatio),
            maxAmplitude: nonZeroRatio > 0 ? 0.4 : 0)
    }

    func testHealthyNormalCapture() {
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 6000, nonZeroRatio: 0.5), holdMs: 6000)
        XCTAssertTrue(assessment.healthy)
        XCTAssertNil(assessment.reason)
    }

    func testShortHoldAlwaysHealthy() {
        // Quick taps and engine-start overhead must never trip the gate,
        // even when the buffer is short and empty (downstream owns it).
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 300, nonZeroRatio: 0), holdMs: 1500)
        XCTAssertTrue(assessment.healthy)
    }

    func testAllZeroShortHoldHealthy() {
        // 3 s hold of pure zeros stays healthy: below the hold gate, the
        // trimmer's empty-clip path reports "No speech detected" instead.
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 3000, nonZeroRatio: 0), holdMs: 3000)
        XCTAssertTrue(assessment.healthy)
    }

    func testShortfallFires() {
        // 16 s hold, only 2 s captured (stalled engine / dropped stream).
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 2000, nonZeroRatio: 0.5), holdMs: 16000)
        XCTAssertFalse(assessment.healthy)
        XCTAssertEqual(assessment.reason, .shortfall)
    }

    func testShortfallBoundary() {
        // Exactly half the hold is kept (boundary holds, not less-than).
        let kept = CaptureHealthGuard.assess(stats: stats(capturedMs: 2000, nonZeroRatio: 0.5), holdMs: 4000)
        XCTAssertTrue(kept.healthy)
        let lost = CaptureHealthGuard.assess(stats: stats(capturedMs: 1999, nonZeroRatio: 0.5), holdMs: 4000)
        XCTAssertFalse(lost.healthy)
        XCTAssertEqual(lost.reason, .shortfall)
    }

    func testSlowEngineStartDoesNotTripShortfall() {
        // Worst observed BT engine start (~370 ms) on a 6 s hold: ratio 0.94.
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 5630, nonZeroRatio: 0.4), holdMs: 6000)
        XCTAssertTrue(assessment.healthy)
    }

    func testSilenceFires() {
        // 5 s captured, 0.1% non-zero: a dead stream, not quiet speech.
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 5000, nonZeroRatio: 0.001), holdMs: 6000)
        XCTAssertFalse(assessment.healthy)
        XCTAssertEqual(assessment.reason, .silence)
    }

    func testSilenceHealthyWhenSpeechPresent() {
        let assessment = CaptureHealthGuard.assess(stats: stats(capturedMs: 5000, nonZeroRatio: 0.05), holdMs: 6000)
        XCTAssertTrue(assessment.healthy)
    }

    func testEmptyStatsHealthy() {
        XCTAssertTrue(CaptureHealthGuard.assess(stats: .empty, holdMs: 0).healthy)
    }
}

// Mid-hold stall watchdog state: pure poll logic behind AppDelegate's
// 1 s polling loop (grace 2.5 s, warn after 2 s stalled).
final class MicStallMonitorTests: XCTestCase {
    func testFirstObserveBaselinesWithoutWarning() {
        var monitor = MicStallMonitor()
        XCTAssertEqual(monitor.observe(count: 10), .ok)
    }

    func testAdvancingCountsStayOk() {
        var monitor = MicStallMonitor()
        XCTAssertEqual(monitor.observe(count: 10), .ok)
        XCTAssertEqual(monitor.observe(count: 11), .ok)
        XCTAssertEqual(monitor.observe(count: 25), .ok)
    }

    func testTwoConsecutiveStalledPollsWarnOnce() {
        var monitor = MicStallMonitor()
        XCTAssertEqual(monitor.observe(count: 10), .ok)
        XCTAssertEqual(monitor.observe(count: 10), .ok) // 1 s stalled: quiet
        XCTAssertEqual(monitor.observe(count: 10), .warn) // 2 s stalled: warn
        XCTAssertEqual(monitor.observe(count: 10), .ok) // still stalled: no repeat
    }

    func testRecoveryRearmsNextEpisode() {
        var monitor = MicStallMonitor()
        XCTAssertEqual(monitor.observe(count: 10), .ok)
        XCTAssertEqual(monitor.observe(count: 10), .ok)
        XCTAssertEqual(monitor.observe(count: 10), .warn)
        XCTAssertEqual(monitor.observe(count: 11), .recovered)
        XCTAssertEqual(monitor.observe(count: 11), .ok)
        XCTAssertEqual(monitor.observe(count: 11), .warn)
    }

    func testThresholdMatchesPollCadence() {
        // Warn threshold must be an exact multiple of the poll interval so
        // the count of stalled polls is deterministic.
        XCTAssertEqual(MicStallMonitor.stallThresholdMs % MicStallMonitor.pollIntervalMs, 0)
        XCTAssertGreaterThan(MicStallMonitor.graceMs, MicStallMonitor.stallThresholdMs)
    }
}
