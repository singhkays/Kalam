import CoreGraphics
import Foundation

/// Pure audio-envelope math behind the recording indicator (Phase 1 extraction;
/// provenance: the AppKit WaveformView/PillLevelGlyphView call sites, deleted
/// at the Phase 4 cutover). Framework-free and deterministic so it stays
/// unit-testable; views translate
/// these values into pixels. The constants are the tuned spec moved verbatim
/// from the WaveformView and PillLevelGlyphView call sites. Do not retune here.
enum IndicatorWaveformMath {

    // MARK: - Waveform envelope (machined deck bars)

    /// Maximum stored history bars; matches the deck's on-screen bar capacity.
    static let maxHistory = 150

    /// AGC gain, smoothed amplitude, and bar history carried between waveform ticks.
    struct Envelope {
        var gain: CGFloat = 1.0
        var smoothedAmp: CGFloat = 0.0
        var history: [CGFloat] = []
    }

    /// Ingests one buffer and pushes exactly one history bar. Inactive ticks and
    /// empty buffers decay toward silence instead of tracking audio.
    static func ingest(samples: [Float], active: Bool, into envelope: inout Envelope) {
        guard active, !samples.isEmpty else {
            envelope.smoothedAmp *= 0.4
            push(into: &envelope, amp: envelope.smoothedAmp)
            return
        }

        // Compute envelope peak
        let peak = samples.reduce(0.0) { max($0, abs($1)) }
        let peakCG = CGFloat(peak)

        // AGC
        let targetGain = peakCG > 0.00001 ? min(90.0, 1.50 / peakCG) : 1.0
        envelope.gain += (targetGain - envelope.gain) * 0.35

        let avg = samples.reduce(0, { $0 + abs($1) }) / Float(max(1, samples.count))

        // Balanced noise gate floor (0.5% full-scale)
        guard peakCG > 0.005 else {
            envelope.smoothedAmp *= 0.5
            push(into: &envelope, amp: envelope.smoothedAmp)
            return
        }
        // Slightly more restrictive noise gate tracking
        let noiseGate = CGFloat(max(0.003, min(0.018, Double(avg) * 2.0)))
        let boosted = max(0.0, min(1.0, (peakCG - noiseGate) * envelope.gain * 3.5))
        let eased = boosted > 0 ? pow(boosted, 0.38) : 0
        let target = eased * 0.96

        // Smooth toward target
        envelope.smoothedAmp += (target - envelope.smoothedAmp) * 0.50

        push(into: &envelope, amp: envelope.smoothedAmp)
    }

    /// Clears the envelope so the next recording starts from silence.
    static func reset(_ envelope: inout Envelope) {
        envelope = Envelope()
    }

    /// Gain and per-bar smoothing carried between glyph ticks. One glyph surface
    /// is live at a time (whisper pill XOR caret chip), so one carrier suffices.
    struct GlyphEnvelope {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0.0, 0.0, 0.0]

        mutating func ingest(_ samples: [Float]) {
            glyphLevels(samples: samples, gain: &gain, smoothed: &smoothed)
        }
    }

    private static func push(into envelope: inout Envelope, amp: CGFloat) {
        envelope.history.append(max(0.0, min(1.0, amp)))
        if envelope.history.count > maxHistory {
            envelope.history.removeFirst(envelope.history.count - maxHistory)
        }
    }

    // MARK: - Level glyph (three-bar whisper/caret glyph)

    /// Computes 3 normalized levels [0.0...1.0] from PCM audio samples with AGC
    /// gain and attack/release smoothing. `gain` and `smoothed` carry state
    /// between ticks and are mutated in place.
    static func glyphLevels(
        samples: [Float],
        gain: inout CGFloat,
        smoothed: inout [CGFloat]
    ) -> [CGFloat] {
        guard !samples.isEmpty else {
            for i in 0..<3 {
                smoothed[i] *= 0.75
            }
            return smoothed
        }

        // Divide 512 samples into 3 time slices
        let count = samples.count
        let chunkSize = max(1, count / 3)
        var slicePeaks: [CGFloat] = []
        for i in 0..<3 {
            let start = i * chunkSize
            let end = (i == 2) ? count : min(count, (i + 1) * chunkSize)
            var slicePeak: Float = 0.0
            for j in start..<end {
                let mag = abs(samples[j])
                if mag > slicePeak { slicePeak = mag }
            }
            slicePeaks.append(CGFloat(slicePeak))
        }

        let framePeak = slicePeaks.reduce(0.0, max)
        let frameAvg = CGFloat(samples.reduce(0.0) { $0 + abs($1) }) / CGFloat(count)

        // Adaptive AGC: boosts quiet speech up to 60x, scales down for loud speech
        let targetGain = framePeak > 0.0001 ? min(60.0, 1.50 / framePeak) : 1.0
        gain += (targetGain - gain) * 0.25

        // Noise gate tracking (0.3% - 1.5%)
        let noiseGate = max(0.003, min(0.015, frameAvg * 1.8))

        for i in 0..<3 {
            let peak = slicePeaks[i]
            let target: CGFloat
            if framePeak < noiseGate {
                target = 0.0
            } else {
                let rawAmp = max(0.0, peak - noiseGate) * gain
                let boosted = min(1.0, rawAmp * 1.8)
                target = boosted > 0.0 ? pow(boosted, 0.40) : 0.0
            }

            // Fast attack (0.65), smooth decay (0.22)
            let coeff: CGFloat = target > smoothed[i] ? 0.65 : 0.22
            smoothed[i] += (target - smoothed[i]) * coeff
        }

        return smoothed
    }
}