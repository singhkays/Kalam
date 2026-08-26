import XCTest
import AVFoundation
@testable import Kalam_test

final class PostRollEarlyExitIntegrationTests: XCTestCase {
    private func buffer(seconds: Double, amplitude: Float, sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let rateF = Float(sampleRate)
        for i in 0..<Int(frames) {
            // All-Float arithmetic: mixed Double/Float literals time out the
            // Swift 6 type checker in this toolchain (known repo pitfall).
            let phase = (Float(i) / rateF) * (2 * Float.pi) * 220
            buf.floatChannelData![0][i] = amplitude * sin(phase)
        }
        return buf
    }

    @MainActor
    func testSilentTailFinishesBeforeTheOldFixedSleepWould() async throws {
        let recorder = AudioRecorder()
        recorder.beginCollectingForTesting()
        let generation = recorder.captureGeneration
        // Speech-like level fills the ring, mirroring a just-ended utterance.
        recorder.process(buffer: buffer(seconds: 1.0, amplitude: 0.4))
        // Trailing silence arrives as a CONTINUOUS stream from the mic tap in
        // production, so mirror that: feed zeros on a timer instead of one
        // synthetic buffer (a lone follow-up buffer can be swallowed by
        // AVAudioConverter inter-buffer priming, which never happens on a
        // live stream).
        let feeder = Task { [weak recorder] in
            for _ in 0..<400 {
                recorder?.process(buffer: buffer(seconds: 0.03, amplitude: 0.0))
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        defer { feeder.cancel() }
        // Give the feeder enough beats for the ring's 960-sample tail to be
        // genuinely zeros: AVAudioConverter batches small inputs and can
        // withhold converted output for many calls before releasing it in a
        // burst (observed live: zeros surfaced only after ~250 ms of feeding).
        try await Task.sleep(nanoseconds: 300_000_000)

        let config = PostRollDecision.Config(minMs: 60, maxMs: 150)
        let start = CFAbsoluteTimeGetCurrent()
        let samples = await recorder.stopWithEarlyExit(pinnedGeneration: generation, config: config)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertFalse(samples.isEmpty)
        // Early exit must finish at/below the old fixed-sleep ceiling (150)
        // with generous margin for VM scheduling noise.
        XCTAssertLessThan(elapsedMs, 145)
    }

    @MainActor
    func testActiveSpeechWaitsToTheCeiling() async throws {
        let recorder = AudioRecorder()
        recorder.beginCollectingForTesting()
        let generation = recorder.captureGeneration

        // Keep the tail loud for longer than the ceiling.
        let feeder = Task { [weak recorder] in
            for _ in 0..<40 {
                recorder?.process(buffer: buffer(seconds: 0.06, amplitude: 0.4))
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        defer { feeder.cancel() }

        let config = PostRollDecision.Config(minMs: 40, maxMs: 150)
        let start = CFAbsoluteTimeGetCurrent()
        _ = await recorder.stopWithEarlyExit(pinnedGeneration: generation, config: config)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // Ceiling honored (plus generous scheduling slack); never EARLY.
        XCTAssertGreaterThanOrEqual(elapsedMs, 130)
    }

    @MainActor
    func testSupersededStopStillReturnsEmptyWithoutTouchingNewerSession() async throws {
        let recorder = AudioRecorder()
        recorder.beginCollectingForTesting()          // session A
        recorder.process(buffer: buffer(seconds: 0.2, amplitude: 0.4))
        let staleGeneration = recorder.captureGeneration
        recorder.beginCollectingForTesting()          // rapid re-record bumps the session
        recorder.process(buffer: buffer(seconds: 0.2, amplitude: 0.4))
        let currentGeneration = recorder.captureGeneration
        XCTAssertNotEqual(staleGeneration, currentGeneration)

        let config = PostRollDecision.Config(minMs: 10, maxMs: 40)
        let staleResult = await recorder.stopWithEarlyExit(pinnedGeneration: staleGeneration, config: config)
        XCTAssertTrue(staleResult.isEmpty)

        let currentResult = await recorder.finishStop(expectedGeneration: currentGeneration)
        XCTAssertFalse(currentResult.isEmpty)
    }
}
