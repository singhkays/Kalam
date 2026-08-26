import XCTest
import AVFoundation
@testable import Kalam_test

/// render-thread audio lock fix regression pin. The render-thread publish path (`process`) must never
/// block behind a consumer holding the capture state. RED on the pre-fix code:
/// `process` does `bufferQueue.sync`, so every producer iteration colliding
/// with the (multi-ms) stop critical section stalls for its remainder —
/// hundreds of iterations per run. GREEN after Task 2: `publish` try-locks and
/// drops instead (µs per iteration, zero stalls).
///
/// Timing-based by necessity (the "never blocks" property is a latency bound),
/// but the assertion statistic is noise-robust: we count iterations exceeding a
/// 5 ms threshold rather than asserting on the max. A single VM scheduling
/// hiccup (~15 ms observed under full-suite load) is tolerated; a blocking
/// design produces hundreds of stalled iterations and fails by an order of
/// magnitude. The structural guarantee (publish under a held lock drops, never
/// waits) is pinned deterministically by `testPublishIsNonBlockingWhileConsumerHoldsLock`.
final class AudioCaptureExchangeTests: XCTestCase {

    func testProducerDoesNotStallWhileStopRuns() async throws {
        let recorder = AudioRecorder()
        // Activate capture state without the audio engine: the test host has no
        // input device, so AVAudioEngine input-graph access asserts. The engine
        // is not needed — the render-thread entry (`process`) and the stop path
        // are driven directly.
        recorder.beginCollectingForTesting()

        // Preload ~480 s of 48 kHz audio so the stop critical section (COW copy
        // + secureZero + dealloc of ~92 MB) is long enough to measure reliably.
        recorder.process(buffer: makeSyntheticBuffer(frames: AVAudioFrameCount(48_000 * 480)))

        // Producer hammering the render-thread entry; signals after its first
        // iteration so the consumer's stop section provably overlaps the loop.
        let producerStarted = DispatchSemaphore(value: 0)
        let producerDone = DispatchGroup()
        let meter = StallMeter()
        producerDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.process(buffer: makeSyntheticBuffer(frames: 1024)) // warm-up
            producerStarted.signal()
            for _ in 0..<10_000 {
                let start = CFAbsoluteTimeGetCurrent()
                recorder.process(buffer: makeSyntheticBuffer(frames: 1024))
                meter.record(CFAbsoluteTimeGetCurrent() - start)
            }
            producerDone.leave()
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 5), .success)
        let samples = await recorder.stopAndFetchSamples(postRollMs: 0)
        XCTAssertEqual(producerDone.wait(timeout: .now() + 30), .success)

        let maxStall = meter.maxStall
        XCTAssertLessThan(
            meter.stallCount, 10,
            "render-thread audio lock fix: \(meter.stallCount) render-thread publishes stalled >5 ms (max \(Int(maxStall * 1000)) ms) — a blocking capture lock would stall hundreds"
        )
        // The preload must be fully captured (480 s × 16 kHz = 7,680,000 samples;
        // the resampler tail adds a little, and a live mic adds more — lower
        // bound only, to stay deterministic).
        XCTAssertGreaterThanOrEqual(samples.count, 7_680_000, "preload must be fully captured")
    }

    // MARK: - AudioCaptureExchange unit pins (GREEN-on-arrival; render-thread audio lock fix)

    func testPublishAndDrainPreserveOrderAndContent() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        for _ in 0..<3 {
            XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        }
        let drained = exchange.stopCapture()
        // Every published frame must arrive; AVAudioConverter pads each call up
        // to capacity (1024 in → 1088 out observed; verbatim pre-render-thread audio lock fix behavior),
        // so bound between no-loss (3072) and fully-padded (3264).
        XCTAssertGreaterThanOrEqual(drained.count, 3072, "no published samples may be lost")
        XCTAssertLessThanOrEqual(drained.count, 3264)
        XCTAssertFalse(drained.allSatisfy { $0 == 0 }, "content must not be silent")
    }

    func testPublishIsNonBlockingWhileConsumerHoldsLock() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        let lockAcquired = expectation(description: "consumer holds the lock")
        let hog = Thread {
            exchange.withExclusiveAccess { _ in
                lockAcquired.fulfill()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        hog.start()
        wait(for: [lockAcquired], timeout: 2)

        let start = CFAbsoluteTimeGetCurrent()
        let accepted = exchange.publish(makeSyntheticBuffer(frames: 1024))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(accepted, "publish must drop while the lock is held")
        XCTAssertLessThan(elapsed, 0.05, "publish must never block (stalled \(Int(elapsed * 1000)) ms)")
        let stats = exchange.stats()
        XCTAssertEqual(stats.dropped, 1)
        XCTAssertEqual(stats.callbacks, 0)
    }

    func testPublishAfterStopIsSkippedNotDropped() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        _ = exchange.stopCapture()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(frames: 1024)), "post-stop publishes are skipped, not dropped")
        XCTAssertEqual(exchange.stats().dropped, 0)
        XCTAssertEqual(exchange.stopCapture().count, 0)
    }

    func testStopCaptureIncludesPublishInFlight() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        let drained = exchange.stopCapture()
        XCTAssertGreaterThanOrEqual(drained.count, 1024, "no published samples may be lost")
        XCTAssertLessThanOrEqual(drained.count, 1088) // converter padding (see testPublishAndDrain...)
        // A publish after stop is skipped: nothing more to drain.
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        XCTAssertEqual(exchange.stopCapture().count, 0)
    }

    func testConverterRebuildsWhenSampleRateChanges() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 48_000)))   // 1 s @48 kHz → ~16 k out
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 44_100, frames: 44_100)))   // 1 s @44.1 kHz → ~16 k out
        let drained = exchange.stopCapture()
        // 1 s + 1 s of 16 kHz mono; converter priming allows a small tolerance.
        XCTAssertEqual(Double(drained.count), 32_000, accuracy: 256)
    }

    func testDrainConverterRemainderFlushesTail() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 4_800))) // 0.1 s
        _ = exchange.stopCapture()
        let tail = exchange.drainConverterRemainder()
        XCTAssertFalse(tail.isEmpty, "resampler tail must be flushed at stream end")
    }

    func testWaveformReturnsRecentSamples() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 4096)))
        let wave = exchange.waveform(sampleCount: 512)
        XCTAssertEqual(wave.count, 512)
        XCTAssertFalse(wave.allSatisfy { $0 == 0 })
    }

    // MARK: - Session-generation guard (rapid re-record; 2026-08-15)

    func testStaleStopDoesNotDrainNewerSession() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        let firstGen = exchange.currentGeneration()

        // A newer session starts before the old stop runs.
        exchange.resetForNewSession()
        let secondGen = exchange.currentGeneration()
        XCTAssertGreaterThan(secondGen, firstGen)

        // The stale stop must no-op; the new session keeps its samples.
        let stale = exchange.stopCapture(expectedGeneration: firstGen)
        XCTAssertTrue(stale.isEmpty)
        let current = exchange.stopCapture(expectedGeneration: secondGen)
        XCTAssertTrue(current.isEmpty, "new session has no samples yet")
    }

    func testStaleStopLeavesNewSessionSamplesIntact() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        let firstGen = exchange.currentGeneration()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))

        exchange.resetForNewSession()
        let secondGen = exchange.currentGeneration()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))

        // Old stop must not touch the new session's buffer.
        XCTAssertTrue(exchange.stopCapture(expectedGeneration: firstGen).isEmpty)

        let drained = exchange.stopCapture(expectedGeneration: secondGen)
        XCTAssertGreaterThanOrEqual(drained.count, 1024, "new session samples must survive a stale stop")
    }

    func testUnconditionalStopStillWorks() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        let drained = exchange.stopCapture()
        XCTAssertGreaterThanOrEqual(drained.count, 1024)
    }

    func testStaleDrainDoesNotResetNewSessionConverter() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        let firstGen = exchange.currentGeneration()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 4_800)))

        exchange.resetForNewSession()
        XCTAssertTrue(exchange.drainConverterRemainder(expectedGeneration: firstGen).isEmpty,
                      "a stale drain must not flush the new session's converter")
        // The new session's tail is still flushable.
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 4_800)))
        XCTAssertFalse(exchange.drainConverterRemainder().isEmpty)
    }

    // MARK: K-49 lever (b): eager converter construction

    func testPrebuildConverterCreatesConverterForRequestedFormat() {
        let exchange = AudioCaptureExchange()
        XCTAssertNil(exchange.converterInfoForTesting)
        let ok = exchange.prebuildConverter(inputSampleRate: 48_000, inputChannelCount: 2)
        XCTAssertTrue(ok)
        let info = exchange.converterInfoForTesting
        XCTAssertEqual(info?.sampleRate, 48_000)
        XCTAssertEqual(info?.channelCount, 2)
    }

    func testFirstPublishedBufferReusesPrebuiltConverter() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.prebuildConverter(inputSampleRate: 48_000, inputChannelCount: 2))
        // 0.01 s @ 48 kHz stereo. AVAudioConverter batches small inputs, so a
        // single tiny publish may yield 0 output frames (fallback path) — the
        // assertions below only pin that the PRE-BUILT converter stayed in
        // place, not on produced sample counts.
        let buffer = makeSyntheticBuffer(sampleRate: 48_000, channels: 2, frames: 480)
        let before = exchange.stats().callbacks
        XCTAssertTrue(exchange.publish(buffer))
        // Same rate/channel pair after publish proves processLocked did NOT
        // rebuild (a rebuild would rewrite the recorded input format — and a
        // failed conversion would have taken the PCM-fallback path instead).
        let info = exchange.converterInfoForTesting
        XCTAssertEqual(info?.sampleRate, 48_000)
        XCTAssertEqual(info?.channelCount, 2)
        XCTAssertEqual(exchange.stats().callbacks, before + 1)
    }

    func testMismatchedFormatStillRebuildsLazily() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.prebuildConverter(inputSampleRate: 44_100, inputChannelCount: 1))
        let buffer = makeSyntheticBuffer(sampleRate: 48_000, channels: 1, frames: 480)
        XCTAssertTrue(exchange.publish(buffer))
        let info = exchange.converterInfoForTesting
        XCTAssertEqual(info?.sampleRate, 48_000)  // lazy path intact
        XCTAssertEqual(info?.channelCount, 1)
    }
}

// MARK: - Helpers

/// Deterministic non-silent PCM buffer at the given format (sine wave).
private func makeSyntheticBuffer(sampleRate: Double = 48_000, channels: Int = 1, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] {
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.01)
        }
    }
    return buffer
}

/// Swift-6-safe stall accumulator (mutating a captured var across threads is a
/// compile error in Swift 6). Counts iterations over the threshold in addition
/// to tracking the max — the count is the noise-robust assertion statistic.
private final class StallMeter: @unchecked Sendable {
    /// Iterations longer than this count as stalls: ~100× the post-fix publish
    /// (µs), occasionally exceeded by VM scheduling noise (tolerated as a
    /// single count), massively exceeded by a blocking lock (hundreds of hits).
    static let stallThreshold: TimeInterval = 0.005
    private let lock = NSLock()
    private var _max: TimeInterval = 0
    private var _stallCount = 0
    func record(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _max = Swift.max(_max, value)
        if value > Self.stallThreshold { _stallCount += 1 }
    }
    var maxStall: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _max
    }
    var stallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stallCount
    }
}
