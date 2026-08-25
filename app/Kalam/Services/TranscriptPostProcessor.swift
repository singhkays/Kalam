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
    }

    private let cleanupConfig: TextCleanupConfiguration
    private let dictionaryEntries: [DictionaryEntry]

    init(cleanupConfig: TextCleanupConfiguration, dictionaryEntries: [DictionaryEntry]) {
        self.cleanupConfig = cleanupConfig
        self.dictionaryEntries = dictionaryEntries
    }

    func process(_ input: String) -> Output {
        let cleanupResult = TextCleanupEngine().clean(input, configuration: cleanupConfig)
        // cleanup master toggle gating ITN: ITN answers to the same master switch as the cleanup rules.
        // It previously keyed off the orphaned private default
        // `internal.itn.enabled` (default true, written by nothing since settings redesign
        // removed the old settings UI), so Cleanup OFF still normalized
        // numbers behind the pane's promise. The dictionary stays independent
        // of the master by design (scoped 2026-08-24).
        let itnResult = Self.applyITN(to: cleanupResult.text, masterEnabled: cleanupConfig.enabled)
        let compiled = ReplacementCompiler.compile(entries: dictionaryEntries)
        let (postProcessed, replaceCount) = compiled.apply(to: itnResult.text)
        return Output(
            text: postProcessed,
            replacements: replaceCount,
            stats: cleanupResult.stats,
            itnEnabled: itnResult.enabled,
            itnAvailable: itnResult.available,
            itnChanged: itnResult.changed,
            itnSpansMasked: itnResult.spansMasked,
            itnMs: Int(itnResult.durationMs)
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
