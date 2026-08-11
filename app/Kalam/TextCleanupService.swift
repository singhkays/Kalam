import AppKit
import Foundation
import NaturalLanguage
import KalamTextEngine

final class TextCleanupService: Sendable {
    static let shared = TextCleanupService()
    private let engine = TextCleanupEngine()
    private init() {}

    func clean(_ text: String, configuration: TextCleanupConfiguration = ModelsConfiguration.load().textCleanup) -> TextCleanupResult {
        let started = CFAbsoluteTimeGetCurrent()
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard configuration.enabled, !input.isEmpty else {
            return TextCleanupResult(text: input, stats: TextCleanupStats())
        }

        var result = engine.clean(input, configuration: configuration)
        var out = result.text
        var stats = result.stats

        if configuration.grammarMode != .off {
            stats.grammarAttempted = true

            if out.count > Self.maxGrammarInputCharacters {
                stats.grammarSkippedForLength = true
            } else {
                let stageStart = CFAbsoluteTimeGetCurrent()
                let grammarResult = applyGrammar(
                    in: out,
                    mode: configuration.grammarMode,
                    timeoutMs: configuration.boundedGrammarTimeoutMs
                )
                stats.grammarMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
                stats.grammarTimedOut = grammarResult.timedOut
                if !grammarResult.timedOut {
                    out = grammarResult.text
                    stats.grammarEdits = grammarResult.editCount
                }
            }
        }

        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            out = input
        }

        stats.durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return TextCleanupResult(text: out, stats: stats)
    }

    private func applyGrammar(in text: String, mode: TextCleanupGrammarMode, timeoutMs: Int) -> (text: String, editCount: Int, timedOut: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + (Double(timeoutMs) / 1000.0)
        let result = runGrammar(text: text, mode: mode, deadline: deadline)
        if result.timedOut {
            return (text, 0, true)
        }
        return (result.text, result.edits, false)
    }

    private func runGrammar(text: String, mode: TextCleanupGrammarMode, deadline: CFAbsoluteTime) -> (text: String, edits: Int, timedOut: Bool) {
        let checker = NSSpellChecker.shared
        let docTag = NSSpellChecker.uniqueSpellDocumentTag()
        let language = Locale.current.identifier
        defer { checker.closeSpellDocument(withTag: docTag) }

        var out = text
        var edits = 0

        let correctionCap = mode == .light ? 12 : 28
        let passCap = mode == .light ? 1 : 2

        for _ in 0..<passCap {
            if CFAbsoluteTimeGetCurrent() >= deadline {
                return (text, 0, true)
            }
            var location = 0
            while location < (out as NSString).length, edits < correctionCap {
                if CFAbsoluteTimeGetCurrent() >= deadline {
                    return (text, 0, true)
                }
                let misspelledRange = checker.checkSpelling(of: out, startingAt: location)
                guard misspelledRange.location != NSNotFound else { break }

                let nsOut = out as NSString
                let originalWord = nsOut.substring(with: misspelledRange)
                if Self.isProtectedTerm(originalWord) {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                let replacement = checker.correction(
                    forWordRange: misspelledRange,
                    in: out,
                    language: language,
                    inSpellDocumentWithTag: docTag
                ) ?? checker.guesses(
                    forWordRange: misspelledRange,
                    in: out,
                    language: language,
                    inSpellDocumentWithTag: docTag
                )?.first

                guard let replacement else {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                if replacement.caseInsensitiveCompare(originalWord) == .orderedSame {
                    location = misspelledRange.location + misspelledRange.length
                    continue
                }

                out = nsOut.replacingCharacters(in: misspelledRange, with: replacement)
                edits += 1
                location = misspelledRange.location + (replacement as NSString).length
            }
        }

        if CFAbsoluteTimeGetCurrent() >= deadline {
            return (text, 0, true)
        }
        let punctuationResult = normalizePunctuation(in: out)
        out = punctuationResult.0
        edits += punctuationResult.1

        if mode == .full {
            if CFAbsoluteTimeGetCurrent() >= deadline {
                return (text, 0, true)
            }
            let sentenceResult = normalizeSentenceStarts(in: out)
            out = sentenceResult.0
            edits += sentenceResult.1
        }

        return (out, edits, false)
    }

    private func normalizeSentenceStarts(in text: String) -> (String, Int) {
        guard !text.isEmpty else { return (text, 0) }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var output = text
        var editCount = 0
        var offsets = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            guard let letterIndex = sentence.firstIndex(where: { $0.isLetter }) else { return true }
            let ch = sentence[letterIndex]
            guard ch.isLowercase else { return true }

            guard let utf16Position = letterIndex.samePosition(in: sentence.utf16) else { return true }
            let utf16Offset = sentence.utf16.distance(from: sentence.utf16.startIndex, to: utf16Position)
            let nsRangeOriginal = NSRange(range, in: text)
            let nsLocation = nsRangeOriginal.location + utf16Offset + offsets
            let replaceRange = NSRange(location: nsLocation, length: 1)

            let nsOutput = output as NSString
            let replacement = String(ch).uppercased()
            output = nsOutput.replacingCharacters(in: replaceRange, with: replacement)
            editCount += 1
            offsets += (replacement as NSString).length - 1
            return true
        }

        return (output, editCount)
    }

    private func normalizePunctuation(in text: String) -> (String, Int) {
        var out = text
        var edits = 0

        let transformations: [(NSRegularExpression, String)] = [
            (Self.spaceBeforePunctuationPattern, "$1"),
            (Self.missingSpaceAfterPunctuationPattern, "$1 "),
            (Self.repeatedPunctuationPattern, "$1"),
            (Self.spaceAroundNewlinePattern, "\n"),
            (Self.multiSpacePattern, " ")
        ]

        for (regex, template) in transformations {
            let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
            let count = regex.numberOfMatches(in: out, options: [], range: nsRange)
            if count > 0 {
                out = regex.stringByReplacingMatches(in: out, options: [], range: nsRange, withTemplate: template)
                edits += count
            }
        }

        return (out, edits)
    }

    static func isProtectedTerm(_ token: String) -> Bool {
        if token.count <= 1 { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        if token.contains("@") || token.contains("/") || token.contains("_") || token.contains(".") { return true }

        let letters = token.filter { $0.isLetter }
        if letters.count >= 2 && letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        var sawUpper = false
        var sawLower = false
        for ch in letters {
            if ch.isUppercase { sawUpper = true }
            if ch.isLowercase { sawLower = true }
        }
        return sawUpper && sawLower
    }

    private static let maxGrammarInputCharacters = 1200

    private static let spaceBeforePunctuationPattern = try! NSRegularExpression(pattern: "\\s+([,.;:!?])", options: [])
    private static let missingSpaceAfterPunctuationPattern = try! NSRegularExpression(pattern: "([,.;:!?])(?=[\\p{L}\\p{N}])", options: [])
    private static let repeatedPunctuationPattern = try! NSRegularExpression(pattern: "([,.;:!?]){2,}", options: [])
    private static let multiSpacePattern = try! NSRegularExpression(pattern: "[\\t ]{2,}", options: [])
    private static let spaceAroundNewlinePattern = try! NSRegularExpression(pattern: "[\\t ]*\\n[\\t ]*", options: [])
}
