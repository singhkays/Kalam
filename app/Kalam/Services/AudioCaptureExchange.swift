import Foundation
import os
import OSLog
@preconcurrency import AVFoundation

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
        var recentWaveformSamples = [Float](repeating: 0, count: AudioCaptureExchange.waveformCapacity)
        var waveformEnd = 0
        var waveformCount = 0
        var converter: AVAudioConverter?
        var converterInputSampleRate: Double = 0
        var converterInputChannelCount: AVAudioChannelCount = 0
    }

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioCaptureExchange")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    /// Drop counter for buffers lost to lock contention. Guarded by its own lock
    /// because the drop path is exactly the path where `lock` is unavailable.
    private let dropCounter = OSAllocatedUnfairLock(initialState: 0)

    private static let waveformCapacity = 4096
    let recentWaveformCapacity = AudioCaptureExchange.waveformCapacity
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
            processLocked(buffer, into: &state)
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
            state.sampleBuffer.secureZero()
            state.sampleBuffer.removeAll(keepingCapacity: true)
            clearWaveform(&state)
            state.converter?.reset()
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
            if let converter = state.converter {
                // A tap callback may already have created the active stream.
                return converter.inputFormat.sampleRate == inputSampleRate &&
                    converter.inputFormat.channelCount == inputChannelCount
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
            var out: [Float] = []
            swap(&out, &state.sampleBuffer)
            clearWaveform(&state)
            return out
        }
    }

    /// Unconditional stop (test seam / legacy): ignores generations.
    func stopCapture() -> [Float] {
        stopCapture(expectedGeneration: nil)
    }

    func waveform(sampleCount: Int) -> [Float] {
        lock.withLock { state in
            let count = min(max(8, sampleCount), state.waveformCount)
            let start = (state.waveformEnd + recentWaveformCapacity - count) % recentWaveformCapacity
            let end = min(start + count, recentWaveformCapacity)
            var result = Array(state.recentWaveformSamples[start..<end])
            result.append(contentsOf: state.recentWaveformSamples.prefix(count - (end - start)))
            return result
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
            guard expectedGeneration == nil || state.sessionGeneration == expectedGeneration else { return [] }
            var leftovers: [Float] = []
            drain(state.converter, into: &leftovers)
            return leftovers
        }
    }

    private func drain(_ converter: AVAudioConverter?, into samples: inout [Float]) {
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 2048) else { return }
        defer { converter.reset() }
        var error: NSError?
        repeat {
            out.frameLength = 0
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            let frames = Int(out.frameLength)
            if frames > 0, let channel = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
                memset(channel, 0, frames * MemoryLayout<Float>.stride)
            }
            if status != .haveData || frames == 0 { break }
        } while true
    }

    func discardCapture(expectedGeneration: Int) {
        lock.withLock { state in
            guard state.sessionGeneration == expectedGeneration else { return }
            state.collecting = false
            state.sampleBuffer.secureZero()
            state.sampleBuffer.removeAll(keepingCapacity: true)
            clearWaveform(&state)
            state.converter?.reset()
        }
    }

    /// Unconditional drain (test seam / legacy): ignores generations.
    func drainConverterRemainder() -> [Float] {
        drainConverterRemainder(expectedGeneration: nil)
    }

    // MARK: - Conversion under the exchange lock

    private func clearWaveform(_ state: inout State) {
        state.recentWaveformSamples.secureZero()
        state.waveformEnd = 0
        state.waveformCount = 0
    }

    private func append(_ samples: UnsafeBufferPointer<Float>, into state: inout State) {
        state.sampleBuffer.append(contentsOf: samples)
        let recent = samples.suffix(recentWaveformCapacity)
        let firstCount = min(recent.count, recentWaveformCapacity - state.waveformEnd)
        state.recentWaveformSamples.replaceSubrange(
            state.waveformEnd..<(state.waveformEnd + firstCount), with: recent.prefix(firstCount))
        state.recentWaveformSamples.replaceSubrange(0..<(recent.count - firstCount), with: recent.dropFirst(firstCount))
        state.waveformEnd = (state.waveformEnd + recent.count) % recentWaveformCapacity
        state.waveformCount = min(state.waveformCount + recent.count, recentWaveformCapacity)
    }

    private func processLocked(_ buffer: AVAudioPCMBuffer, into state: inout State) {
        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, buffer.frameLength > 0 else { return }

        if state.converter?.inputFormat != inputFormat {
            drain(state.converter, into: &state.sampleBuffer)
            state.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            state.converterInputSampleRate = inputFormat.sampleRate
            state.converterInputChannelCount = inputFormat.channelCount
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 256
        guard let converter = state.converter,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            appendPCMBufferFallback(buffer, into: &state)
            return
        }

        var supplied = false
        var error: NSError?
        repeat {
            out.frameLength = 0
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            let frames = Int(out.frameLength)
            if let channel = out.floatChannelData?[0], frames > 0 {
                if status != .error {
                    append(UnsafeBufferPointer(start: channel, count: frames), into: &state)
                }
                memset(channel, 0, frames * MemoryLayout<Float>.stride)
            }
            if status == .error {
                logger.warning("Audio conversion failed")
                converter.reset()
                if !supplied { appendPCMBufferFallback(buffer, into: &state) }
                break
            }
            if status != .haveData || frames == 0 { break }
        } while true
    }

    private func appendPCMBufferFallback(_ buffer: AVAudioPCMBuffer, into state: inout State) {
        var mono = extractMonoFloatSamples(from: buffer)
        var resampled: [Float] = []
        if buffer.format.sampleRate == targetFormat.sampleRate {
            swap(&mono, &resampled)
        } else {
            resampled = resampleLinear(mono, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        }
        mono.secureZero()
        resampled.withUnsafeBufferPointer { append($0, into: &state) }
        resampled.secureZero()
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
