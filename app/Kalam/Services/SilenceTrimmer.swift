import Foundation
import OSLog

// MARK: - Silence Trimmer (robust energy-based endpointer with hysteresis)

enum SilenceTrimmer {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "SilenceTrimmer")

    // Main entry. Defaults tuned for dense speech with very little silence.
    static func trim(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        padMs: Int = 300,              // Increased for conservative padding
        startMarginDb: Float = 10,     // Lowered for tighter adaptation
        stopMarginDb: Float = 6,       // Lowered for tighter adaptation
        hangoverMs: Int = 300,         // Increased for longer speech tails
        fallbackMinSeconds: Double = 4.0,  // Baseline guardrail for short clips
        fallbackMinKeepRatio: Double = 0.8  // Baseline guardrail for short clips
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        
        let maxAmplitude = samples.map { abs($0) }.max() ?? 0
        logger.info("Trimming audio maxAmplitude=\(maxAmplitude, privacy: .public)")
        
        if maxAmplitude < 0.00001 {
            logger.info("Audio is silent below amplitude threshold")
            return []
        }
        
        let winSamples = max(1, (sampleRate * windowMs) / 1000)
        var energiesDb: [Float] = []
        energiesDb.reserveCapacity(samples.count / winSamples + 1)
        
        // Compute per-window RMS energy, then convert to dB (20*log10 for amplitude scale)
        let eps: Float = 1e-6  // Epsilon for RMS to avoid log(0); yields ~ -120 dB floor before clamp
        var i = 0
        while i < samples.count {
            let end = min(i + winSamples, samples.count)
            var sum: Float = 0
            var j = i
            while j < end {
                let s = samples[j]
                sum += s * s
                j += 1
            }
            let count = Float(end - i)
            let meanSquare = sum / count
            let rms = sqrt(meanSquare)
            let db = 20.0 * log10(max(rms, eps))
            // Clamp to [-60, 0] dB: -60 floor avoids overestimating silence in low-level speech; 0 caps peaks
            let clampedDb = max(-60.0, min(0.0, db))
            energiesDb.append(clampedDb)
            i = end
        }
        
        guard !energiesDb.isEmpty else { return samples }
        
        // Estimate noise floor using 5th percentile (more conservative for dense speech with less noise variability)
        let noiseFloorDb = percentile(energiesDb, p: 0.05)
        let startThresholdDb = noiseFloorDb + startMarginDb
        let stopThresholdDb = noiseFloorDb + stopMarginDb
        logger.info("Silence thresholds noiseFloorDb=\(noiseFloorDb, privacy: .public) startThresholdDb=\(startThresholdDb, privacy: .public) stopThresholdDb=\(stopThresholdDb, privacy: .public)")
        
        // Scan the buffer to extract multiple speech segments, dropping long silences
        let padWins = max(0, (padMs + windowMs - 1) / windowMs)
        let hangoverWins = max(1, (hangoverMs + windowMs - 1) / windowMs)
        
        var segments: [(start: Int, end: Int)] = []
        
        var inSpeech = false
        var startWin = 0
        var belowCount = 0
        var lastSpeechWin = -1
        
        for (idx, db) in energiesDb.enumerated() {
            if !inSpeech {
                if db >= startThresholdDb {
                    inSpeech = true
                    startWin = idx
                    lastSpeechWin = idx
                    belowCount = 0
                }
            } else {
                if db >= stopThresholdDb {
                    lastSpeechWin = idx
                    belowCount = 0
                } else {
                    belowCount += 1
                    if belowCount >= hangoverWins {
                        segments.append((start: startWin, end: lastSpeechWin))
                        inSpeech = false
                    }
                }
            }
        }
        
        if inSpeech {
            segments.append((start: startWin, end: lastSpeechWin))
        }
        
        if segments.isEmpty {
            logger.info("No speech detected after endpointing")
            // Conservative fallback: send full audio if it looks speech-y
            if maxAmplitude > 0.001 {
                logger.info("Returning full audio for ASR fallback")
                return samples
            }
            return []
        }
        
        // Pad and merge overlapping segments
        var paddedSegments: [(start: Int, end: Int)] = []
        for seg in segments {
            let paddedStart = max(0, seg.start - padWins)
            let paddedEnd = min(energiesDb.count - 1, seg.end + padWins)
            
            if let last = paddedSegments.last, last.end >= paddedStart {
                paddedSegments[paddedSegments.count - 1] = (start: last.start, end: max(last.end, paddedEnd))
            } else {
                paddedSegments.append((start: paddedStart, end: paddedEnd))
            }
        }
        
        var outSamples: [Float] = []
        var trimmedCount = 0
        
        for seg in paddedSegments {
            let startIndex = seg.start * winSamples
            let endIndex = min(samples.count, (seg.end + 1) * winSamples)
            if endIndex > startIndex {
                outSamples.append(contentsOf: samples[startIndex..<endIndex])
                trimmedCount += (endIndex - startIndex)
            }
        }
        
        // Fallback policy if the trim looks too aggressive
        let originalDur = Double(samples.count) / Double(sampleRate)
        let trimmedDur = Double(trimmedCount) / Double(sampleRate)
        let keepRatio = Double(trimmedCount) / Double(samples.count)
        
        // Duration-aware fallback:
        // - Short clips remain conservative to avoid clipped utterances.
        // - Long clips allow more aggressive trimming to reduce ASR latency on trailing silence.
        let dynamicMinSeconds: Double
        let dynamicMinKeepRatio: Double
        if originalDur >= 12.0 {
            dynamicMinSeconds = 0.7
            dynamicMinKeepRatio = 0.08
        } else if originalDur >= 8.0 {
            dynamicMinSeconds = 0.9
            dynamicMinKeepRatio = 0.12
        } else if originalDur >= 5.0 {
            dynamicMinSeconds = 1.1
            dynamicMinKeepRatio = 0.18
        } else if originalDur >= 2.5 {
            dynamicMinSeconds = 1.2
            dynamicMinKeepRatio = 0.35
        } else {
            dynamicMinSeconds = fallbackMinSeconds
            dynamicMinKeepRatio = fallbackMinKeepRatio
        }
        
        logger.info("Trim decision segments=\(segments.count, privacy: .public) padWins=\(padWins, privacy: .public) keptSamples=\(trimmedCount, privacy: .public) trimmedMs=\(Int(trimmedDur * 1000), privacy: .public) originalMs=\(Int(originalDur * 1000), privacy: .public) keepRatioPercent=\(Int(keepRatio * 100), privacy: .public)")
        logger.info("Trim fallback thresholds minMs=\(Int(dynamicMinSeconds * 1000), privacy: .public) minKeepRatioPercent=\(Int(dynamicMinKeepRatio * 100), privacy: .public)")
        
        let shouldFallback =
        (originalDur >= 1.2 && trimmedDur < dynamicMinSeconds) ||
        (keepRatio < dynamicMinKeepRatio)
        
        if trimmedCount <= 0 || shouldFallback {
            logger.info("Falling back to full audio clip")
            return samples
        }
        
        return outSamples
    }
    
    // Peak normalize to target dBFS (default -3 dBFS), clamped to [-1, 1].
    static func normalizePeak(_ samples: [Float], targetDbFS: Float = -3.0) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        if maxAbs < 1e-6 { return samples }
        let targetAmp = pow(10.0, targetDbFS / 20.0) // -3 dBFS ≈ 0.7079
        // Only scale if we would not clip badly; allow small attenuation or boost.
        let scale = targetAmp / maxAbs
        if abs(scale - 1.0) < 0.05 { // within 5%, skip
            return samples
        }
        return samples.map { min(max($0 * scale, -1.0), 1.0) }
    }
    
    private static func percentile(_ xs: [Float], p: Float) -> Float {
        if xs.isEmpty { return -120.0 }
        let pClamped = max(0.0, min(1.0, p))
        let sorted = xs.sorted()
        let idx = Int(round(pClamped * Float(sorted.count - 1)))
        return sorted[idx]
    }
}
