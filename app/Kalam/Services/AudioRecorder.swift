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

/// Decides whether `prepare()` must rebuild the audio graph. Extracted from
/// `AudioRecorder.prepare` so the early-return logic is headless-testable
/// (microphone recovery after sleep or device change; the test host cannot touch `engine.inputNode`).
enum AudioPrepareDecision {
    static func shouldReconfigure(
        isPrepared: Bool,
        lastDeviceID: AudioDeviceID?,
        preferredDeviceID: AudioDeviceID?,
        invalidated: Bool
    ) -> Bool {
        !(isPrepared && lastDeviceID == preferredDeviceID && !invalidated)
    }
}

final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?
    private var preparedStateInvalidated = false

    // render-thread audio lock fix: all capture state (buffers, converter, counters) lives behind
    // AudioCaptureExchange; the render thread publishes non-blockingly
    // (try-lock), consumers use exclusive access.
    private let exchange = AudioCaptureExchange()
    /// Generation of the capture session this recorder most recently started.
    private var currentCaptureGeneration = 0
    
    // Tap buffer size reduced to lower tail latency at key-up
    private let tapBufferSizeFrames: AVAudioFrameCount = 1024

    /// The generation of the capture session this recorder most recently
    /// started. Callers capture this synchronously at stop-decision time and
    /// pass it into `stopAndFetchSamples` — the stop must never adopt a newer
    /// session's id (rapid re-record).
    var captureGeneration: Int { currentCaptureGeneration }

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
        if !AudioPrepareDecision.shouldReconfigure(
            isPrepared: isPrepared,
            lastDeviceID: preparedInputDeviceID,
            preferredDeviceID: preferredInputDeviceID,
            invalidated: preparedStateInvalidated
        ) {
            logger.debug("Audio graph already prepared; skipping reconfigure")
            return
        }
        preparedStateInvalidated = false

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

    /// Forces the next `prepare()` call to fully rebuild the audio graph
    /// (engine stop, tap removal, device re-bind). Called on CoreAudio device
    /// changes and system wake (microphone recovery after sleep or device change) — without it, prepare() early-returns
    /// on an unchanged device ID and stays bound to a stale device.
    func invalidatePreparedState() {
        preparedStateInvalidated = true
    }

    var isPreparedForTesting: Bool { isPrepared }
    var preparedDeviceIDForTesting: AudioDeviceID? { preparedInputDeviceID }
    var isPreparedStateInvalidatedForTesting: Bool { preparedStateInvalidated }
    
    func startCollecting() throws {
        // microphone recovery after sleep or device change: reset capture state BEFORE touching the engine — the old
        // order (reset at the end) left stale state when engine.start()
        // failed, and the failure was silently swallowed.
        exchange.resetForNewSession()
        currentCaptureGeneration = exchange.currentGeneration()

        if !engine.isRunning {
            do {
                try engine.start()
                logger.info("Audio engine started for recording")
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                logger.info("Live input output format sampleRate=\(liveOutputFormat.sampleRate, privacy: .public) channels=\(liveOutputFormat.channelCount, privacy: .public)")
                logger.info("Live input bus format sampleRate=\(liveInputBusFormat.sampleRate, privacy: .public) channels=\(liveInputBusFormat.channelCount, privacy: .public)")
            } catch {
                // One recovery attempt: invalidate the stale graph binding
                // (sleep/wake, dock reconnect) and retry from a fresh prepare.
                logger.warning("Audio engine start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public); attempting re-prepare")
                invalidatePreparedState()
                do {
                    try prepare(preferredInputDeviceID: preparedInputDeviceID)
                    try engine.start()
                    logger.info("Audio engine started after re-prepare")
                } catch {
                    throw AudioRecorderError.engineStartFailed(error)
                }
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

        logger.info("Started collecting audio samples")
    }
    
    // Post-roll capture is applied before stopping and fetching samples.
    // Convenience async wrapper (test seam): pins the generation at call time,
    // sleeps the post-roll, then finishes THAT session. Production callers
    // capture the generation before any suspension and call `finishStop`.
    func stopAndFetchSamples(postRollMs: Int = 200) async -> [Float] {
        let generation = currentCaptureGeneration
        let delayMs = max(0, min(500, postRollMs))
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        return finishStop(expectedGeneration: generation)
    }

    /// Synchronous stop critical section. Call on the main thread (production
    /// callers are MainActor-inherited tasks). Contains NO suspension points,
    /// so a newer session cannot start between the staleness check and the
    /// engine stop — a stop that was superseded by a rapid re-record returns
    /// empty WITHOUT touching the newer session's buffers or engine.
    func finishStop(expectedGeneration: Int) -> [Float] {
        guard exchange.currentGeneration() == expectedGeneration else {
            logger.info("Stop superseded by a newer capture session; skipping teardown")
            return []
        }

        var out = exchange.stopCapture(expectedGeneration: expectedGeneration)

        // Stop the engine on the main thread to turn off the microphone indicator.
        if engine.isRunning {
            let stopStart = CFAbsoluteTimeGetCurrent()
            engine.stop()
            let stopElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            logger.info("Audio engine stopped stopMs=\(Int(stopElapsed), privacy: .public)")
        }

        // Drain any residual frames from the converter (resampler tail) and reset it
        let drainedTail = exchange.drainConverterRemainder(expectedGeneration: expectedGeneration)
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

    /// Trailing capture samples for post-roll polling (consumer side; may
    /// block). Reads the waveform ring, which mirrors everything published
    /// this session — capacity 4096 samples (256 ms at 16 kHz) covers the
    /// three 20 ms analysis windows the tail verdict needs.
    func recentCaptureSamples(count: Int) -> [Float] {
        exchange.waveform(sampleCount: count)
    }

    /// K-49: adaptive post-roll with energy-polled early exit. Polls the
    /// trailing buffer every `config.pollIntervalMs`; finishes as soon as the
    /// tail reads silent for `requiredSilentPolls` consecutive polls AND the
    /// minimum elapsed, or at the ceiling, whichever comes first. The
    /// generation was pinned by the CALLER before the first suspension; the
    /// final teardown is the same `finishStop` critical section the fixed
    /// sleep used, so rapid-re-record staleness semantics are unchanged.
    func stopWithEarlyExit(pinnedGeneration: Int, config: PostRollDecision.Config) async -> [Float] {
        let start = CFAbsoluteTimeGetCurrent()
        var consecutiveSilent = 0
        // ~60 ms slice = three 20 ms analysis windows for the tail verdict.
        while true {
            try? await Task.sleep(nanoseconds: config.minIntervalNanos)
            if Task.isCancelled { break }
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if PostRollDecision.tailIsSilent(
                samples: recentCaptureSamples(count: 960),
                sampleRate: 16_000
            ) {
                consecutiveSilent += 1
            } else {
                consecutiveSilent = 0
            }
            if PostRollDecision.shouldFinish(
                config: config,
                elapsedMs: elapsedMs,
                consecutiveSilentPolls: consecutiveSilent
            ) {
                break
            }
        }
        return finishStop(expectedGeneration: pinnedGeneration)
    }

    func cancelCapture() async {
        _ = finishStop(expectedGeneration: currentCaptureGeneration)
    }

    /// Test-only: activate capture state without touching the audio engine
    /// (the test host has no microphone input device, so AVAudioEngine input
    /// graph construction asserts — the app's onboarding guarantees one in
    /// production). Mirrors the state portion of `startCollecting()`.
    func beginCollectingForTesting() {
        exchange.resetForNewSession()
        currentCaptureGeneration = exchange.currentGeneration()
    }
    
    /// Render-thread entry point (installTap callback). Never blocks — the
    /// publish path try-locks and drops (and counts) on contention (render-thread audio lock fix).
    /// Internal for testability (KalamTests drives it with synthetic buffers).
    @discardableResult
    func process(buffer: AVAudioPCMBuffer) -> Bool {
        exchange.publish(buffer)
    }

    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        exchange.waveform(sampleCount: sampleCount)
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
