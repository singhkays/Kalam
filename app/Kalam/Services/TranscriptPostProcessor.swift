import Foundation
import OSLog
import KalamTextEngine

/// off-main post-processing: the pure post-ASR text stages (cleanup -> ITN -> dictionary),
/// extracted from the MainActor-inherited transcription task so they run
/// off-main. Holds only Sendable snapshots; the caller captures them on the
/// main actor and hops via a nonisolated static async call. Never logs
/// transcript text (privacy invariant) — callers log counts/timings only.
struct TranscriptPostProcessor: Sendable {
    struct Output: Sendable {
        let text: String
        let replacements: Int
        let stats: TextCleanupStats
        let itnEnabled: Bool
        let itnAvailable: Bool
        let itnChanged: Bool
        let itnSpansMasked: Int
        let itnMs: Int
        // K-55 ValidationGate: raw vs cleaned divergence
        let gateVerdict: GateVerdict
        let gateMetrics: GateMetrics
        let gateRawFallback: Bool
    }

    private let cleanupConfig: TextCleanupConfiguration
    private let dictionaryEngine: CompiledReplacementEngine

    init(cleanupConfig: TextCleanupConfiguration, dictionaryEngine: CompiledReplacementEngine) {
        self.cleanupConfig = cleanupConfig
        self.dictionaryEngine = dictionaryEngine
    }

    func process(_ input: String) -> Output {
        let rawInput = input
        let cleanupResult = TextCleanupEngine().clean(input, configuration: cleanupConfig)
        // K-55 ValidationGate: raw (ASR) vs *cleanup* output only.
        // ITN/dictionary are curated and legitimately change tokens (e.g. "fifty dollars" -> "$50.20",
        // "open ai" -> "OpenAI"), so they must not be counted as divergence.
        // The gate therefore validates TextCleanupEngine's deterministic transforms
        // in isolation; on reject we fall back to raw and skip ITN/dictionary entirely
        // (high-quality fallback, never empty).
        let gateMetrics = ValidationGate.metrics(raw: rawInput, cleaned: cleanupResult.text)
        let gateVerdict = ValidationGate.verdict(raw: rawInput, cleaned: cleanupResult.text, metrics: gateMetrics)
        let gateRawFallback: Bool
        let finalText: String
        let itnResult: (text: String, changed: Bool, durationMs: Double, available: Bool, enabled: Bool, spanTokens: Int, spansMasked: Int)
        let replacements: Int
        if case .reject = gateVerdict {
            gateRawFallback = true
            // Fallback to raw ASR, bypassing ITN/dictionary to preserve the user's words.
            // Dictionary is deliberately not applied on fallback. Rejects fall
            // back silently, every time (the K-55 auto-degrade trip store was
            // removed 2026-10-02 — there is no degraded mode anymore).
            itnResult = (text: rawInput, changed: false, durationMs: 0, available: NemoTextProcessing.isAvailable, enabled: false, spanTokens: 0, spansMasked: 0)
            replacements = 0
            finalText = rawInput
        } else {
            gateRawFallback = false
            // Normal path: ITN (gated by cleanup master) → dictionary
            let itn = Self.applyITN(to: cleanupResult.text, masterEnabled: cleanupConfig.enabled)
            itnResult = itn
            let (postProcessed, replaceCount) = dictionaryEngine.apply(to: itn.text)
            replacements = replaceCount
            finalText = postProcessed
        }
        return Output(
            text: finalText,
            replacements: replacements,
            stats: cleanupResult.stats,
            itnEnabled: itnResult.enabled,
            itnAvailable: itnResult.available,
            itnChanged: itnResult.changed,
            itnSpansMasked: itnResult.spansMasked,
            itnMs: Int(itnResult.durationMs),
            gateVerdict: gateVerdict,
            gateMetrics: gateMetrics,
            gateRawFallback: gateRawFallback
        )
    }

    // MARK: - ITN (ported verbatim from AppDelegate.applyITNIfEnabled, ITN span protection)

    private static let itnSpanDefaultsKey = "internal.itn.maxSpanTokens"
    private static let itnDefaultSpanTokens = 16
    private static let itnMinSpanTokens = 4
    private static let itnMaxSpanTokens = 64

    private static func applyITN(to text: String, masterEnabled: Bool) -> (text: String, changed: Bool, durationMs: Double, available: Bool, enabled: Bool, spanTokens: Int, spansMasked: Int) {
        let enabled = masterEnabled
        let spanTokens = Self.itnSpanTokens()
        let nemoAvailable = NemoTextProcessing.isAvailable
        guard enabled, nemoAvailable, !text.isEmpty else {
            return (text, false, 0, nemoAvailable, enabled, spanTokens, 0)
        }

        // currency cents stranding fix: Nemo's currency span stops consuming at sentence-final
        // punctuation and strands the word "cents" ("Five dollars and fifty
        // cents." -> "$5.50 cents."). Strip each line's single trailing
        // terminator up front and re-append it after normalization.
        let span = UInt32(spanTokens)
        let started = CFAbsoluteTimeGetCurrent()
        let protector = ITNSpanProtector()
        let lines = text.components(separatedBy: "\n")
        var spansMasked = 0
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            var terminator: String?
            var workingLine = trimmed
            if let last = workingLine.last, ".!?".contains(last) {
                terminator = String(last)
                workingLine = String(workingLine.dropLast())
            }
            // ITN span protection: mask spoken-number spans ITN mis-normalizes (ranges,
            // idioms, digit sequences), normalize, then restore.
            let masked = protector.protect(workingLine)
            spansMasked += masked.spans.count
            let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: span)
            var restored = protector.restore(normalized, spans: masked.spans)
            if let terminator {
                restored += terminator
            }
            return restored
        }

        let normalized = normalizedLines.joined(separator: "\n")
        let durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return (normalized, normalized != text, durationMs, nemoAvailable, enabled, Int(span), spansMasked)
    }

    private static func itnSpanTokens() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: itnSpanDefaultsKey) != nil else {
            return itnDefaultSpanTokens
        }
        let value = defaults.integer(forKey: itnSpanDefaultsKey)
        return min(itnMaxSpanTokens, max(itnMinSpanTokens, value))
    }
}
