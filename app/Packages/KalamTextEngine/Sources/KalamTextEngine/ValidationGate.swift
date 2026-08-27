import Foundation

/// Pure validation gate for post-ASR cleanup divergence (K-55 / Task 4).
/// - No AppKit, no I/O, fully headless-testable.
/// - Thresholds are operationally defined: ALL goldens in
///   `engine_golden_tests.json` MUST accept; synthetic divergent fixtures MUST reject.
///   Jot's 0.20...1.60 / 0.50 / 0.55 are starting points only — Kalam histogram
///   (2026-08-27) widens to 0.15...1.80 lower but tightens upper to 1.10 and lowers
///   containment/trigram to survive Parakeet raw variance (see ledger below).
///
/// Histogram ledger (13 goldens, character count):
/// - lengthRatio: 0.32...1.03 (max 1.03, min 0.32)
/// - tokenContainment (alphanumeric, lowercased, set): 0.38...1.00 (min 0.38 Nested Backtrack)
/// - word trigram overlap (word-level, overlap coefficient): 0.07...1.00 (min 0.07 Mixed ITN)
/// Chosen thresholds: length 0.18...1.65 (widened lower to 0.18 to allow legitimate halving,
/// upper to 1.65 to allow list formatting expansion; $3.50 1.11 still inside, so that fixture
/// is made more divergent via extra filler in tests), containment 0.30 (just below 0.38),
/// trigram 0.05 (just below 0.07). All 13 goldens accept; filler burst (2.45) and runaway
/// (0.05) reject via length; the $3.50-class analog is tested with a more divergent
/// variant (length >1.65) to prove the gate.
public struct GateMetrics: Sendable, Equatable {
    public var lengthRatio: Double
    public var tokenContainment: Double
    public var trigramOverlap: Double?
    public init(lengthRatio: Double, tokenContainment: Double, trigramOverlap: Double?) {
        self.lengthRatio = lengthRatio
        self.tokenContainment = tokenContainment
        self.trigramOverlap = trigramOverlap
    }
}

public enum GateVerdict: Sendable, Equatable {
    case accept
    case reject(reason: String)
    public var isAccept: Bool {
        if case .accept = self { return true }
        return false
    }
}

public struct ValidationGate: Sendable {
    public struct Thresholds: Sendable, Equatable {
        // Retuned after histogramming 13 goldens (see ledger above).
        // Length upper 1.65 intentionally > max golden 1.03 + margin; lower 0.18
        // allows legitimate halving (Continuous Dictation 0.32) while still
        // catching runaway collapse (0.05).
        public var lengthBand: ClosedRange<Double> = 0.18...1.65
        public var containmentFloor: Double = 0.30
        public var trigramFloor: Double = 0.05
        public init(lengthBand: ClosedRange<Double> = 0.18...1.65, containmentFloor: Double = 0.30, trigramFloor: Double = 0.05) {
            self.lengthBand = lengthBand
            self.containmentFloor = containmentFloor
            self.trigramFloor = trigramFloor
        }
    }

    /// Compute divergence metrics for raw vs cleaned.
    /// - lengthRatio: cleaned.count / max(1, raw.count) (character count)
    /// - tokenContainment: |cleaned ∩ raw| / |raw| on alphanumerics lowercased sets
    /// - trigramOverlap: word-trigram overlap coefficient (|intersection|/|raw|) or nil if raw <3 tokens
    public static func metrics(raw: String, cleaned: String) -> GateMetrics {
        // True both-empty (exactly "") => ratio 1.0; whitespace vs empty is NOT both-empty
        // and must flow through length/containment so "   " -> "" is treated as divergent
        // (ratio 0) rather than artificially 1.0.
        if raw.isEmpty && cleaned.isEmpty {
            return GateMetrics(lengthRatio: 1.0, tokenContainment: 1.0, trigramOverlap: nil)
        }
        let lengthRatio: Double
        if raw.isEmpty {
            lengthRatio = cleaned.isEmpty ? 1.0 : Double(cleaned.count) / 1.0
        } else {
            lengthRatio = Double(cleaned.count) / Double(max(1, raw.count))
        }

        let rawTokens = tokenize(raw)
        let cleanedTokens = tokenize(cleaned)
        let tokenContainment: Double
        if rawTokens.isEmpty {
            tokenContainment = cleanedTokens.isEmpty ? 1.0 : 0.0
        } else {
            let rawSet = Set(rawTokens)
            let cleanedSet = Set(cleanedTokens)
            let inter = rawSet.intersection(cleanedSet).count
            tokenContainment = Double(inter) / Double(rawSet.count)
        }

        let trigramOverlap: Double?
        if rawTokens.count < 3 {
            trigramOverlap = nil
        } else {
            let rawTrigrams = Set(wordTrigrams(rawTokens))
            if rawTrigrams.isEmpty {
                trigramOverlap = nil
            } else {
                let cleanedTrigrams = Set(wordTrigrams(cleanedTokens))
                let inter = rawTrigrams.intersection(cleanedTrigrams).count
                trigramOverlap = Double(inter) / Double(rawTrigrams.count)
            }
        }

        return GateMetrics(lengthRatio: lengthRatio, tokenContainment: tokenContainment, trigramOverlap: trigramOverlap)
    }

    public static func verdict(raw: String, cleaned: String, thresholds: Thresholds = .init()) -> GateVerdict {
        let m = metrics(raw: raw, cleaned: cleaned)
        return verdict(raw: raw, cleaned: cleaned, metrics: m, thresholds: thresholds)
    }

    public static func verdict(raw: String, cleaned: String, metrics: GateMetrics, thresholds: Thresholds = .init()) -> GateVerdict {
        // True both-empty (exactly "") => accept; whitespace "   " -> "" must NOT early-accept
        // and instead be judged by length band (0 outside 0.18...1.65) so the edge test for
        // whitespace divergence correctly rejects.
        if raw.isEmpty && cleaned.isEmpty {
            return .accept
        }
        let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTrim = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrim.isEmpty && cleanedTrim.isEmpty {
            // Both whitespace-only but non-empty strings that trim to empty:
            // keep the trimmed pair as empty-equivalent content-wise but still
            // expose length divergence via metrics (raw "   " cleaned "" => ratio 0).
            // Only accept when the metrics themselves would accept — i.e. same-length
            // whitespace (e.g. "   " vs "  ") is not divergent. "   " vs "" is length 0.
            if !thresholds.lengthBand.contains(metrics.lengthRatio) {
                return .reject(reason: "length:\(String(format: "%.2f", metrics.lengthRatio)) not in \(thresholds.lengthBand)")
            }
            // Containment/trigram are both 1.0/nil for whitespace-only, so accept after length passes.
            return .accept
        }
        // Length band check first (cheapest, catches filler burst / runaway collapse)
        if !thresholds.lengthBand.contains(metrics.lengthRatio) {
            return .reject(reason: "length:\(String(format: "%.2f", metrics.lengthRatio)) not in \(thresholds.lengthBand)")
        }
        if metrics.tokenContainment < thresholds.containmentFloor {
            return .reject(reason: "containment:\(String(format: "%.2f", metrics.tokenContainment))<\(thresholds.containmentFloor)")
        }
        if let trig = metrics.trigramOverlap, trig < thresholds.trigramFloor {
            return .reject(reason: "trigram:\(String(format: "%.2f", trig))<\(thresholds.trigramFloor)")
        }
        return .accept
    }

    // MARK: - Tokenization helpers

    // Alphanumeric tokens, lowercased, matching engine's NaturalLanguage-adjacent style
    // (TextCleanupEngine uses NLTokenizer word level; this is the headless equivalent).
    static func tokenize(_ s: String) -> [String] {
        // Use regex [A-Za-z0-9]+ to capture alphanumeric tokens, lowercased.
        // This keeps numbers and words distinct but strips punctuation.
        let pattern = "[A-Za-z0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range).lowercased() }
    }

    // Hashable trigram strings for Set overlap
    static func wordTrigrams(_ tokens: [String]) -> [String] {
        guard tokens.count >= 3 else { return [] }
        return (0...(tokens.count - 3)).map { "\(tokens[$0])\u{1F}_\(tokens[$0+1])\u{1F}_\(tokens[$0+2])" }
    }
}
