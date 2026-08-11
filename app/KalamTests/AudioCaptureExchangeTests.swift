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
