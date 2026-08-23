import Foundation
import OSLog
import KalamTextEngine

/// K-38: the pure post-ASR text stages (cleanup -> ITN -> dictionary),
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
        let itnResult = Self.applyITN(to: cleanupResult.text)
        let compiled = ReplacementCompiler.compile(entries: dictionaryEntries)
        let (postProcessed, replaceCount) = compiled.apply(to: itnResult.text)
        return Output(
            text: postProcessed,
            replacements: replaceCount,
            stats: cleanupResult.stats,
            itnEnabled: itnResult.enabled,
            itnAvailable: itnResult.available,
            itnChanged: itnResult.changed,
            itnMs: Int(itnResult.durationMs)
        )
    }

    // MARK: - ITN (ported verbatim from AppDelegate.applyITNIfEnabled, K-28)

    private static let itnEnabledDefaultsKey = "internal.itn.enabled"
    private static let itnSpanDefaultsKey = "internal.itn.maxSpanTokens"
    private static let itnDefaultEnabled = true
    private static let itnDefaultSpanTokens = 16
    private static let itnMinSpanTokens = 4
    private static let itnMaxSpanTokens = 64

    private static func applyITN(to text: String) -> (text: String, changed: Bool, durationMs: Double, available: Bool, enabled: Bool, spanTokens: Int) {
        let enabled = Self.isITNEnabled()
        let spanTokens = Self.itnSpanTokens()
        let nemoAvailable = NemoTextProcessing.isAvailable
        guard enabled, nemoAvailable, !text.isEmpty else {
            return (text, false, 0, nemoAvailable, enabled, spanTokens)
        }

        let span = UInt32(spanTokens)
        let started = CFAbsoluteTimeGetCurrent()
        let protector = ITNSpanProtector()
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            // K-28: mask spoken-number spans ITN mis-normalizes (ranges,
            // idioms, digit sequences), normalize, then restore.
            let masked = protector.protect(trimmed)
            let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: span)
            return protector.restore(normalized, spans: masked.spans)
        }

        let normalized = normalizedLines.joined(separator: "\n")
        let durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return (normalized, normalized != text, durationMs, nemoAvailable, enabled, Int(span))
    }

    private static func isITNEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: itnEnabledDefaultsKey) != nil else {
            return itnDefaultEnabled
        }
        return defaults.bool(forKey: itnEnabledDefaultsKey)
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
