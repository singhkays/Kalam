import XCTest
import AVFoundation
@testable import Kalam_test

/// K-10 regression pin. The render-thread publish path (`process`) must never
/// block behind a consumer holding the capture state. RED on the pre-fix code:
/// `process` does `bufferQueue.sync`, so the producer iteration colliding with
/// the (multi-ms) stop critical section stalls for its full duration. GREEN
/// after Task 2: `publish` try-locks and drops instead.
///
/// Timing-based by necessity (the "never blocks" property is a latency bound),
/// but the margins are wide: the preload makes the stop section ~8–20 ms on any
/// hardware, while the bound (5 ms) is ~100× the post-fix publish (~50 µs).
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
            maxStall, 0.005,
            "K-10: render-thread publish stalled \(Int(maxStall * 1000)) ms — must never block on the capture lock"
        )
        // The preload must be fully captured (480 s × 16 kHz = 7,680,000 samples;
        // the resampler tail adds a little, and a live mic adds more — lower
        // bound only, to stay deterministic).
        XCTAssertGreaterThanOrEqual(samples.count, 7_680_000, "preload must be fully captured")
    }

    // MARK: - AudioCaptureExchange unit pins (GREEN-on-arrival; K-10)

    func testPublishAndDrainPreserveOrderAndContent() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        for _ in 0..<3 {
            XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        }
        let drained = exchange.stopCapture()
        // Every published frame must arrive; AVAudioConverter pads each call up
        // to capacity (1024 in → 1088 out observed; verbatim pre-K-10 behavior),
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

/// Swift-6-safe max-of-durations accumulator (mutating a captured var across
/// threads is a compile error in Swift 6).
private final class StallMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _max: TimeInterval = 0
    func record(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _max = Swift.max(_max, value)
    }
    var maxStall: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _max
    }
}
