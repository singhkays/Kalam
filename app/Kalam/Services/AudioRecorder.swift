import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import OSLog

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

// MARK: - Secure Memory Zeroing
extension Array where Element == Float {
    mutating func secureZero() {
        self.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                memset(baseAddress, 0, buffer.count * MemoryLayout<Float>.size)
            }
        }
    }
}

// MARK: - Audio Recorder (AVAudioEngine + resample to 16kHz mono Float32)

enum AudioRecorderError: LocalizedError {
    case micPermissionDenied
    case invalidInputFormat
    case converterCreationFailed
    case engineStartFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone permission denied."
        case .invalidInputFormat:
            return "Invalid input format."
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter."
        case .engineStartFailed(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        }
    }
}

final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?

    // K-10: all capture state (buffers, converter, counters) lives behind
    // AudioCaptureExchange; the render thread publishes non-blockingly
    // (try-lock), consumers use exclusive access.
    private let exchange = AudioCaptureExchange()
    
    // Tap buffer size reduced to lower tail latency at key-up
    private let tapBufferSizeFrames: AVAudioFrameCount = 1024

    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    func prepare(preferredInputDeviceID: AudioDeviceID?) throws {
        if isPrepared && preparedInputDeviceID == preferredInputDeviceID {
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw AudioRecorderError.micPermissionDenied
        @unknown default:
            throw AudioRecorderError.micPermissionDenied
        }

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        exchange.withExclusiveAccess { state in
            state.converter = nil
            state.converterInputSampleRate = 0
            state.converterInputChannelCount = 0
        }
        
        // Log current default input device details (to confirm e.g. Logitech C920)
        AudioDeviceDebug.logDefaultInputDeviceSummary()
        
        let input = engine.inputNode
        if let preferredInputDeviceID, let audioUnit = input.audioUnit {
            var id = preferredInputDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioRecorderError.engineStartFailed(
                    NSError(
                        domain: "Kalam.AudioRecorder",
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to bind input device (OSStatus \(status))"]
                    )
                )
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }
        
        logger.info("Input format sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
        
        // Prepare engine but don't start it yet - we'll start it when recording begins
        engine.prepare()
        logger.info("Audio engine prepared tapBufferSize=\(self.tapBufferSizeFrames, privacy: .public)")
        isPrepared = true
        preparedInputDeviceID = preferredInputDeviceID
    }
    
    func startCollecting() {
        // Start engine when we begin collecting
        if !engine.isRunning {
            do {
                try engine.start()
                logger.info("Audio engine started for recording")
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                logger.info("Live input output format sampleRate=\(liveOutputFormat.sampleRate, privacy: .public) channels=\(liveOutputFormat.channelCount, privacy: .public)")
                logger.info("Live input bus format sampleRate=\(liveInputBusFormat.sampleRate, privacy: .public) channels=\(liveInputBusFormat.channelCount, privacy: .public)")
            } catch {
                logger.warning("Failed to start audio engine errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                return
            }
        }

        if !tapInstalled {
            // For input node taps, AVAudioEngine expects the input bus hardware format.
            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            logger.info("Installing tap sampleRate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)")
            engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSizeFrames, format: tapFormat) { [weak self] (buffer, _) in
                self?.process(buffer: buffer)
            }
            tapInstalled = true
        }
        
        exchange.resetForNewSession()
        logger.info("Started collecting audio samples")
    }
    
    // Post-roll capture is applied before stopping and fetching samples.
    func stopAndFetchSamples(postRollMs: Int = 200) async -> [Float] {
        // Keep collecting for a short post-roll to capture trailing phonemes
        let delayMs = max(0, min(500, postRollMs))
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        
        var out = exchange.stopCapture()
        
        // Stop the engine on the main thread to turn off the microphone indicator
        if engine.isRunning {
            let stopStart = CFAbsoluteTimeGetCurrent()
            let engine = self.engine
            // Ensure engine.stop is done on main to avoid CoreAudio surprises
            await MainActor.run {
                engine.stop()
            }
            let stopElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            logger.info("Audio engine stopped stopMs=\(Int(stopElapsed), privacy: .public)")
        }
        
        // Drain any residual frames from the converter (resampler tail) and reset it
        let drainedTail = drainConverterRemainder()
        if !drainedTail.isEmpty {
            logger.info("Drained converter tail samples=\(drainedTail.count, privacy: .public) durationMs=\(Int(Double(drainedTail.count) / 16_000.0 * 1000), privacy: .public)")
        }
        
        out.append(contentsOf: drainedTail)
        
        let durationMs = out.isEmpty ? 0 : Int(Double(out.count) / 16_000.0 * 1000)
        let (callbacks, dropped) = exchange.stats()
        logger.info("Stopped collecting samples=\(out.count, privacy: .public) durationMs=\(durationMs, privacy: .public) callbacks=\(callbacks, privacy: .public) dropped=\(dropped, privacy: .public)")
        
        // Debug: Check non-zero and max amplitude
        let nonZeroCount = out.lazy.filter { abs($0) > 0.0001 }.count
        logger.info("Audio sample summary nonZeroSamples=\(nonZeroCount, privacy: .public) totalSamples=\(out.count, privacy: .public)")
        if let maxAmplitude = out.map({ abs($0) }).max() {
            logger.info("Audio sample maxAmplitude=\(maxAmplitude, privacy: .public)")
        }
        return out
    }

    func cancelCapture() async {
        _ = await stopAndFetchSamples(postRollMs: 0)
    }

    /// Test-only: activate capture state without touching the audio engine
    /// (the test host has no microphone input device, so AVAudioEngine input
    /// graph construction asserts — the app's onboarding guarantees one in
    /// production). Mirrors the state portion of `startCollecting()`.
    func beginCollectingForTesting() {
        exchange.resetForNewSession()
    }
    
    /// Render-thread entry point (installTap callback). Never blocks — the
    /// publish path try-locks and drops (and counts) on contention (K-10).
    /// Internal for testability (KalamTests drives it with synthetic buffers).
    @discardableResult
    func process(buffer: AVAudioPCMBuffer) -> Bool {
        exchange.publish(buffer)
    }

    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        exchange.waveform(sampleCount: sampleCount)
    }
    
    // Drain any residual frames from the converter at stream end to avoid losing ~10–30 ms.
    private func drainConverterRemainder() -> [Float] {
        exchange.drainConverterRemainder()
    }
    
    deinit {
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        logger.info("AudioRecorder deinitialized; engine stopped and tap removed")
    }
}
