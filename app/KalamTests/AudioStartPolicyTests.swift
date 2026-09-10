import XCTest
@testable import Kalam_test

/// Pins the bounded-start policy (engine-start freeze hardening): deadline
/// value, outcome classification precedence, and the self-clean contract.
/// Pure types — no AVFoundation, no engine, fully headless.
final class AudioStartPolicyTests: XCTestCase {

    // MARK: - Classification

    func testClassifyStarted() {
        // A completed attempt inside the budget that neither threw nor was
        // abandoned is a committed start.
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: 40, didThrow: false, wasAbandoned: false),
                       .started)
        // Just under the deadline still counts as started.
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: AudioStartPolicy.timeoutMs - 1, didThrow: false, wasAbandoned: false),
                       .started)
    }

    func testClassifyFailsOnThrow() {
        // A thrown error (device gone, permission, bind failure) is a failure
        // even when it returned quickly.
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: 50, didThrow: true, wasAbandoned: false),
                       .failed)
    }

    func testClassifyTimeoutAtAndBeyondDeadline() {
        // Exactly at the deadline the attempt is treated as timed out — the
        // boundary belongs to the deadline branch, not to success.
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: AudioStartPolicy.timeoutMs, didThrow: false, wasAbandoned: false),
                       .timedOut)
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: AudioStartPolicy.timeoutMs + 5000, didThrow: false, wasAbandoned: false),
                       .timedOut)
    }

    func testAbandonmentWinsOverEveryOtherOutcome() {
        // Precedence contract: if the press was abandoned, the outcome is
        // superseded REGARDLESS of how the attempt ended — a late-successful
        // engine start must never be classified as committable, and a late
        // failure must not be double-reported.
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: 10, didThrow: false, wasAbandoned: true),
                       .superseded)
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: 10, didThrow: true, wasAbandoned: true),
                       .superseded)
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: AudioStartPolicy.timeoutMs + 1000, didThrow: false, wasAbandoned: true),
                       .superseded)
        XCTAssertEqual(AudioStartPolicy.classify(elapsedMs: AudioStartPolicy.timeoutMs + 1000, didThrow: true, wasAbandoned: true),
                       .superseded)
    }

    // MARK: - Self-clean contract

    func testSelfCleanOnlyWhenAbandoned() {
        // Abandoned attempts always clean up (engine stop + graph
        // invalidation) — a late-starting engine must never run unattended.
        XCTAssertTrue(AudioStartPolicy.shouldSelfClean(wasAbandoned: true))
        // Normal completions own their engine state through the regular
        // lifecycle (commit or error path) — no extra cleanup.
        XCTAssertFalse(AudioStartPolicy.shouldSelfClean(wasAbandoned: false))
    }

    // MARK: - Deadline sanity

    func testTimeoutCoversWorstObservedStartsWithMargin() {
        // The deadline must sit well above the worst measured engine start
        // (Bluetooth ~450 ms — the same budget MicStallMonitor.graceMs covers)
        // so slow-but-healthy devices never trip it, yet low enough that a
        // wedged HAL feels like an error, not a hang.
        XCTAssertGreaterThan(AudioStartPolicy.timeoutMs, 450 * 2,
                             "deadline must exceed worst observed Bluetooth start with margin")
        XCTAssertLessThan(AudioStartPolicy.timeoutMs, 5000,
                          "deadline must keep the perceived hang under a few seconds")
    }

    func testInFlightWaitPollIsSubFrame() {
        // Supersede-wait polling must be imperceptible.
        XCTAssertLessThan(AudioStartPolicy.inFlightWaitPollMs, 100)
        XCTAssertGreaterThan(AudioStartPolicy.inFlightWaitPollMs, 0)
    }
}
