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

    @MainActor
    func testOldDeadlineCannotAbandonLaterStart() async {
        let recorder = AudioRecorder()
        let first = ControlledAudioStart(released: true)
        let firstOutcome = await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: first.operations) { true }
        XCTAssertEqual(firstOutcome, .started)

        let second = ControlledAudioStart()
        let task = Task { @MainActor in
            await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: second.operations) { true }
        }
        await fulfillment(of: [second.entered], timeout: 2)
        first.fireDeadline()
        second.release.signal()
        let secondOutcome = await task.value
        XCTAssertEqual(secondOutcome, .started)
        XCTAssertEqual(first.discards, 0)
        XCTAssertEqual(second.discards, 0)
        XCTAssertFalse(recorder.isStartInFlight)
    }

    @MainActor
    func testHardwareSuccessAfterDeadlineDiscardsBeforeNextStart() async {
        let recorder = AudioRecorder()
        let start = ControlledAudioStart()
        let task = Task { @MainActor in
            await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: start.operations) {
                XCTFail("A timed-out attempt must never commit")
                return true
            }
        }
        await fulfillment(of: [start.entered], timeout: 2)
        start.fireDeadline()
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(recorder.isStartInFlight)
        start.release.signal()
        let slotAvailable = await recorder.waitForStartSlot(until: .now + .seconds(2))
        XCTAssertTrue(slotAvailable)
        XCTAssertEqual(start.discards, 1)
    }

    @MainActor
    func testUnacceptedHardwareStartIsDiscarded() async {
        let recorder = AudioRecorder()
        let start = ControlledAudioStart(released: true)
        let outcome = await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: start.operations) { false }
        XCTAssertEqual(outcome, .superseded)
        let slotAvailable = await recorder.waitForStartSlot(until: .now + .seconds(2))
        XCTAssertTrue(slotAvailable)
        XCTAssertEqual(start.discards, 1)
    }

    @MainActor
    func testFailedSecondStartLeavesPriorTranscriptSessionAndTarget() async {
        let recorder = AudioRecorder()
        let first = ControlledAudioStart(released: true)
        var sessions = RecordingSessionTracker()
        var target: Int?
        let firstOutcome = await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: first.operations) {
            sessions.beginNewRecording()
            target = 11
            return true
        }
        XCTAssertEqual(firstOutcome, .started)
        let pendingTranscript = sessions.currentSessionID

        let second = ControlledAudioStart(released: true, fails: true)
        let secondOutcome = await recorder.startCollectingBounded(deadline: .now + .seconds(10), operations: second.operations) {
            XCTFail("A failed start cannot promote its destination")
            sessions.beginNewRecording()
            target = 22
            return true
        }
        XCTAssertEqual(secondOutcome, .failed)
        let slotAvailable = await recorder.waitForStartSlot(until: .now + .seconds(2))
        XCTAssertTrue(slotAvailable)
        XCTAssertEqual(second.discards, 1)
        XCTAssertNotNil(pendingTranscript)
        XCTAssertEqual(sessions.currentSessionID, pendingTranscript)
        XCTAssertEqual(target, 11)
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

private final class ControlledAudioStart: @unchecked Sendable {
    let entered = XCTestExpectation(description: "engine start entered")
    let release = DispatchSemaphore(value: 0)
    private let fails: Bool
    private let lock = NSLock()
    private var deadline: (@Sendable () -> Void)?
    private var discardCount = 0

    init(released: Bool = false, fails: Bool = false) {
        self.fails = fails
        if released { release.signal() }
    }

    var discards: Int { lock.withLock { discardCount } }

    var operations: AudioRecorder.StartOperations {
        AudioRecorder.StartOperations(
            start: { [self] in
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success, !fails else {
                    throw AudioRecorderError.invalidInputFormat
                }
            },
            discard: { [self] in lock.withLock { discardCount += 1 } },
            scheduleDeadline: { [self] fire in lock.withLock { deadline = fire } }
        )
    }

    func fireDeadline() {
        let fire = lock.withLock { deadline }
        fire?()
    }
}
