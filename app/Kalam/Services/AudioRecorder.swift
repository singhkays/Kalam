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
    private var converter: AVAudioConverter?
    private var converterInputSampleRate: Double = 0
    private var converterInputChannelCount: AVAudioChannelCount = 0
    private var callbackCount: Int = 0
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    
    // Thread-safe buffer and converter access
    private let bufferQueue = DispatchQueue(label: "Kalam.AudioBuffer")
    private var collecting = false
    private var sampleBuffer: [Float] = []
    private var recentWaveformSamples: [Float] = []
    private let recentWaveformCapacity = 4096
    
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
        converter = nil
        converterInputSampleRate = 0
        converterInputChannelCount = 0
        
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
        
        bufferQueue.sync {
            collecting = true
            callbackCount = 0
            sampleBuffer.removeAll(keepingCapacity: true)
            recentWaveformSamples.removeAll(keepingCapacity: true)
            // Do not reset converter here; keep across session until stop/drain to preserve internal filter state.
        }
        logger.info("Started collecting audio samples")
    }
    
    // Post-roll capture is applied before stopping and fetching samples.
    func stopAndFetchSamples(postRollMs: Int = 200) async -> [Float] {
        // Keep collecting for a short post-roll to capture trailing phonemes
        let delayMs = max(0, min(500, postRollMs))
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        
        var out: [Float] = []
        bufferQueue.sync {
            collecting = false
            out = sampleBuffer
            sampleBuffer.secureZero()
            sampleBuffer.removeAll(keepingCapacity: false)
            recentWaveformSamples.secureZero()
            recentWaveformSamples.removeAll(keepingCapacity: false)
        }
        
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
        let callbacks = bufferQueue.sync { callbackCount }
        logger.info("Stopped collecting samples=\(out.count, privacy: .public) durationMs=\(durationMs, privacy: .public) callbacks=\(callbacks, privacy: .public)")
        
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
    
    private func process(buffer: AVAudioPCMBuffer) {
        bufferQueue.sync {
            guard self.collecting else { return }
            self.callbackCount += 1
            let inputFormat = buffer.format
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
            let needsConverterRebuild =
                self.converter == nil
                || self.converterInputSampleRate != inputFormat.sampleRate
                || self.converterInputChannelCount != inputFormat.channelCount

            if needsConverterRebuild {
                guard let rebuilt = AVAudioConverter(from: inputFormat, to: self.targetFormat) else {
                    self.logger.warning("Failed to create AVAudioConverter inputSampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
                    return
                }
                self.converter = rebuilt
                self.converterInputSampleRate = inputFormat.sampleRate
                self.converterInputChannelCount = inputFormat.channelCount
            }
            guard let converter = self.converter else { return }
            
            let ratio = self.targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64.0)
            
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else {
                self.logger.warning("Failed to create output buffer")
                return
            }
            
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
            
            if status == .error {
                if let e = convError {
                    self.logger.warning("Conversion error; using PCM fallback errorSummary=\(privacySafeErrorSummary(e), privacy: .public)")
                } else {
                    self.logger.warning("Conversion error unknown; using PCM fallback")
                }
                self.appendPCMBufferFallback(buffer)
                return
            }

            let frames = Int(outBuffer.frameLength)
            if frames > 0 {
                guard let channel = outBuffer.floatChannelData?[0] else {
                    self.logger.warning("No float channel data available; using PCM fallback")
                    self.appendPCMBufferFallback(buffer)
                    return
                }
                let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
                self.sampleBuffer.append(contentsOf: samples)
                self.recentWaveformSamples.append(contentsOf: samples)
                let overflow = self.recentWaveformSamples.count - self.recentWaveformCapacity
                if overflow > 0 {
                    self.recentWaveformSamples.removeFirst(overflow)
                }
            } else {
                self.appendPCMBufferFallback(buffer)
            }
        }
    }

    private func appendPCMBufferFallback(_ buffer: AVAudioPCMBuffer) {
        let mono = extractMonoFloatSamples(from: buffer)
        guard !mono.isEmpty else { return }
        let resampled = resampleLinear(mono, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        guard !resampled.isEmpty else { return }
        sampleBuffer.append(contentsOf: resampled)
        recentWaveformSamples.append(contentsOf: resampled)
        let overflow = recentWaveformSamples.count - recentWaveformCapacity
        if overflow > 0 {
            recentWaveformSamples.removeFirst(overflow)
        }
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

    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        bufferQueue.sync {
            guard !recentWaveformSamples.isEmpty else { return [] }
            let count = max(8, sampleCount)
            if recentWaveformSamples.count <= count {
                return recentWaveformSamples
            }
            return Array(recentWaveformSamples.suffix(count))
        }
    }
    
    // Drain any residual frames from the converter at stream end to avoid losing ~10–30 ms.
    private func drainConverterRemainder() -> [Float] {
        var leftovers: [Float] = []
        bufferQueue.sync {
            guard let converter = self.converter else { return }
            var convError: NSError?
            
            // Provide end-of-stream to flush internal buffers
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
            // Reset converter between sessions to clear state
            converter.reset()
        }
        return leftovers
    }
    
    deinit {
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        sampleBuffer.secureZero()
        recentWaveformSamples.secureZero()
        logger.info("AudioRecorder deinitialized; engine stopped and tap removed")
    }
}
