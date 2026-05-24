import Foundation
import OSLog

struct DictationTextProcessingResult {
    let text: String
    let changed: Bool
    let durationMs: Double
    let available: Bool
    let enabled: Bool
    let spanTokens: Int
}

enum DictationTextPostProcessor {
    private enum ITNOptions {
        static let enabledDefaultsKey = "internal.itn.enabled"
        static let spanDefaultsKey = "internal.itn.maxSpanTokens"
        static let defaultEnabled = true
        static let defaultSpanTokens = 16
        static let minSpanTokens = 4
        static let maxSpanTokens = 64
    }

    static func logStatusOnStartup(logger: Logger) {
        let enabled = isITNEnabled()
        let span = itnSpanTokens()
        if NemoTextProcessing.isAvailable {
            let version = NemoTextProcessing.version ?? "unknown"
            logger.info("ITN ready enabled=\(enabled, privacy: .public) span=\(span, privacy: .public) version=\(version, privacy: .public)")
        } else {
            logger.warning("ITN unavailable enabled=\(enabled, privacy: .public) span=\(span, privacy: .public)")
        }
    }

    static func applyITNIfEnabled(to text: String) -> DictationTextProcessingResult {
        let enabled = isITNEnabled()
        let spanTokens = itnSpanTokens()
        let nemoAvailable = NemoTextProcessing.isAvailable
        guard enabled, nemoAvailable, !text.isEmpty else {
            return DictationTextProcessingResult(
                text: text,
                changed: false,
                durationMs: 0,
                available: nemoAvailable,
                enabled: enabled,
                spanTokens: spanTokens
            )
        }

        let span = UInt32(spanTokens)
        let started = CFAbsoluteTimeGetCurrent()
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return NemoTextProcessing.normalizeSentence(line, maxSpanTokens: span)
        }

        let normalized = normalizedLines.joined(separator: "\n")
        let durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return DictationTextProcessingResult(
            text: normalized,
            changed: normalized != text,
            durationMs: durationMs,
            available: nemoAvailable,
            enabled: enabled,
            spanTokens: Int(span)
        )
    }

    private static func isITNEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ITNOptions.enabledDefaultsKey) != nil else {
            return ITNOptions.defaultEnabled
        }
        return defaults.bool(forKey: ITNOptions.enabledDefaultsKey)
    }

    private static func itnSpanTokens() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ITNOptions.spanDefaultsKey) != nil else {
            return ITNOptions.defaultSpanTokens
        }
        let value = defaults.integer(forKey: ITNOptions.spanDefaultsKey)
        return min(ITNOptions.maxSpanTokens, max(ITNOptions.minSpanTokens, value))
    }
}
