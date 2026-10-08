import Foundation
import os
import OSLog
@preconcurrency import AVFoundation

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

/// Thread-safe exchange between the audio render thread (producer) and Kalam's
/// consumer threads (main thread, transcription task).
///
/// render-thread audio lock fix: the render thread must NEVER block. `publish` acquires the lock with a
/// try-lock (`os_unfair_lock_trylock` behind `OSAllocatedUnfairLock.withLockIfAvailable`):
/// when a consumer holds the lock, the buffer is dropped and counted instead of
/// stalling the render thread (priority-inversion risk). All consumer-side
/// operations may block; they run on non-render threads.
///
/// All state is only ever touched inside `lock` (or `dropCounter`), which is why
/// the `@unchecked Sendable` conformances are sound: `AVAudioConverter` is not
/// `Sendable`, so `State` cannot be a plain `Sendable` struct.
final class AudioCaptureExchange: @unchecked Sendable {

    struct State: @unchecked Sendable {
        var collecting = false
        /// Monotonic capture-session id. `resetForNewSession` bumps it; stop/drain
        /// operations that carry an expected id no-op when it no longer matches,
        /// so a stale teardown can never touch a newer session's buffers.
        var sessionGeneration = 0
        var callbackCount = 0
        var sampleBuffer: [Float] = []
        var recentWaveformSamples: [Float] = []
        var converter: AVAudioConverter?
        var converterInputSampleRate: Double = 0
        var converterInputChannelCount: AVAudioChannelCount = 0
    }

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioCaptureExchange")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    /// Drop counter for buffers lost to lock contention. Guarded by its own lock
    /// because the drop path is exactly the path where `lock` is unavailable.
    private let dropCounter = OSAllocatedUnfairLock(initialState: 0)

    let recentWaveformCapacity = 4096
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Render thread (never blocks)

    /// Render-thread entry point. Never blocks: try-locks and drops (and counts)
    /// the buffer when a consumer currently holds the lock.
    /// - Returns: `false` only for a contention drop. Buffers arriving after
    ///   `collecting == false` are skipped but return `true` (not a drop).
    @discardableResult
    func publish(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard lock.withLockIfAvailable({ state -> Bool in
            guard state.collecting else { return true }
            state.callbackCount += 1
            _ = processLocked(buffer, into: &state)
            return true
        }) ?? false else {
            dropCounter.withLockIfAvailable { $0 += 1 }
            return false
        }
        return true
    }

    // MARK: - Consumer side (may block)

    func withExclusiveAccess<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    func resetForNewSession() {
        lock.withLock { state in
            state.sessionGeneration += 1
            state.collecting = true
            state.callbackCount = 0
            state.sampleBuffer.removeAll(keepingCapacity: true)
            state.recentWaveformSamples.removeAll(keepingCapacity: true)
            // Do not reset the converter here; keep across sessions until
            // stop/drain to preserve internal filter state.
        }
    }

    /// The current capture-session id (captured by callers at session start).
    func currentGeneration() -> Int {
        lock.withLock { $0.sessionGeneration }
    }

    /// K-49 lever (b): build the resample converter eagerly at session start
    /// so the render thread's FIRST buffer does not pay construction on the
    /// critical path. Mirrors the rebuild conditions in `processLocked`; a
    /// mismatched request is ignored (render thread rebuilds lazily exactly
    /// as before). Returns true when a converter is in place for precisely
    /// this input format.
    @discardableResult
    func prebuildConverter(inputSampleRate: Double, inputChannelCount: AVAudioChannelCount) -> Bool {
        lock.withLock { state in
            if state.converter != nil,
               state.converterInputSampleRate == inputSampleRate,
               state.converterInputChannelCount == inputChannelCount {
                return true
            }
            guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: inputSampleRate,
                    channels: inputChannelCount,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: format, to: targetFormat) else {
                return false
            }
            state.converter = converter
            state.converterInputSampleRate = inputSampleRate
            state.converterInputChannelCount = inputChannelCount
            return true
        }
    }

    /// Test seam: the recorded input format of the converter currently in
    /// place, or nil when none exists.
    var converterInfoForTesting: (sampleRate: Double, channelCount: AVAudioChannelCount)? {
        lock.withLock { state in
            guard state.converter != nil else { return nil }
            return (state.converterInputSampleRate, state.converterInputChannelCount)
        }
    }

    /// Stops capture and returns the samples only when `expectedGeneration`
    /// still matches. A stale stop (belonging to an older session) no-ops and
    /// returns empty — it must never drain a newer session's audio.
    func stopCapture(expectedGeneration: Int?) -> [Float] {
        lock.withLock { state in
            guard expectedGeneration == nil || state.sessionGeneration == expectedGeneration else {
                return []
            }
            state.collecting = false
            let out = state.sampleBuffer
            state.sampleBuffer.secureZero()
            state.sampleBuffer.removeAll(keepingCapacity: false)
            state.recentWaveformSamples.secureZero()
            state.recentWaveformSamples.removeAll(keepingCapacity: false)
            return out
        }
    }

    /// Unconditional stop (test seam / legacy): ignores generations.
    func stopCapture() -> [Float] {
        stopCapture(expectedGeneration: nil)
    }

    func waveform(sampleCount: Int) -> [Float] {
        lock.withLock { state in
            guard !state.recentWaveformSamples.isEmpty else { return [] }
            let count = max(8, sampleCount)
            if state.recentWaveformSamples.count <= count {
                return state.recentWaveformSamples
            }
            return Array(state.recentWaveformSamples.suffix(count))
        }
    }

    func stats() -> (callbacks: Int, dropped: Int) {
        let callbacks = lock.withLock { $0.callbackCount }
        let dropped = dropCounter.withLock { $0 }
        return (callbacks, dropped)
    }

    /// Drain residual converter frames at stream end (~10–30 ms of audio).
    /// Stale drains no-op: a newer session already owns the converter state.
    func drainConverterRemainder(expectedGeneration: Int?) -> [Float] {
        lock.withLock { state in
            var leftovers: [Float] = []
            guard expectedGeneration == nil || state.sessionGeneration == expectedGeneration else {
                return []
            }
            guard let converter = state.converter else { return [] }
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: 2048) else { break }
                out.frameLength = 0
                let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
                if status == .haveData {
                    if let ch = out.floatChannelData?[0] {
                        let frames = Int(out.frameLength)
                        leftovers.append(contentsOf: UnsafeBufferPointer(start: ch, count: frames))
                    }
                    continue
                }
                break
            }
            converter.reset()
            return leftovers
        }
    }

    /// Unconditional drain (test seam / legacy): ignores generations.
    func drainConverterRemainder() -> [Float] {
        drainConverterRemainder(expectedGeneration: nil)
    }

    // MARK: - Conversion (moved verbatim from AudioRecorder.process; runs under the lock)

    private func processLocked(_ buffer: AVAudioPCMBuffer, into state: inout State) -> [Float]? {
        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        let needsConverterRebuild =
            state.converter == nil
            || state.converterInputSampleRate != inputFormat.sampleRate
            || state.converterInputChannelCount != inputFormat.channelCount

        if needsConverterRebuild {
            guard let rebuilt = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                logger.warning("Failed to create AVAudioConverter inputSampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
                return nil
            }
            state.converter = rebuilt
            state.converterInputSampleRate = inputFormat.sampleRate
            state.converterInputChannelCount = inputFormat.channelCount
        }
        guard let converter = state.converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64.0)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            logger.warning("Failed to create output buffer")
            return nil
        }

        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)

        if status == .error {
            if let e = convError {
                logger.warning("Conversion error; using PCM fallback errorSummary=\(privacySafeErrorSummary(e), privacy: .public)")
            } else {
                logger.warning("Conversion error unknown; using PCM fallback")
            }
            return appendPCMBufferFallback(buffer, into: &state)
        }

        let frames = Int(outBuffer.frameLength)
        if frames > 0 {
            guard let channel = outBuffer.floatChannelData?[0] else {
                logger.warning("No float channel data available; using PCM fallback")
                return appendPCMBufferFallback(buffer, into: &state)
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
            state.sampleBuffer.append(contentsOf: samples)
            state.recentWaveformSamples.append(contentsOf: samples)
            let overflow = state.recentWaveformSamples.count - recentWaveformCapacity
            if overflow > 0 {
                state.recentWaveformSamples.removeFirst(overflow)
            }
            return samples
        } else {
            return appendPCMBufferFallback(buffer, into: &state)
        }
    }

    @discardableResult
    private func appendPCMBufferFallback(_ buffer: AVAudioPCMBuffer, into state: inout State) -> [Float]? {
        let mono = extractMonoFloatSamples(from: buffer)
        guard !mono.isEmpty else { return nil }
        let resampled = resampleLinear(mono, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        guard !resampled.isEmpty else { return nil }
        state.sampleBuffer.append(contentsOf: resampled)
        state.recentWaveformSamples.append(contentsOf: resampled)
        let overflow = state.recentWaveformSamples.count - recentWaveformCapacity
        if overflow > 0 {
            state.recentWaveformSamples.removeFirst(overflow)
        }
        return resampled
    }

    private func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: frames))

        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int16.max) }

        case .pcmFormatInt32:
            guard let channel = buffer.int32ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int32.max) }

        default:
            return []
        }
    }

    private func resampleLinear(_ input: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard inRate > 0, outRate > 0 else { return [] }
        guard abs(inRate - outRate) > 0.001 else { return input }

        let outputCount = Int(Double(input.count) * outRate / inRate)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let scale = inRate / outRate
        for i in 0..<outputCount {
            let src = Double(i) * scale
            let lo = Int(src)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(src - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }

    deinit {
        lock.withLock { state in
            state.sampleBuffer.secureZero()
            state.recentWaveformSamples.secureZero()
        }
    }
}
