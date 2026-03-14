import AppKit
import Foundation
import NaturalLanguage

struct TextCleanupStats: Equatable {
    var fillerRemovals: Int = 0
    var backtrackEdits: Int = 0
    var listItemsFormatted: Int = 0
    var punctuationEdits: Int = 0
    var grammarEdits: Int = 0

    var fillerMs: Double = 0
    var backtrackMs: Double = 0
    var listMs: Double = 0
    var punctuationMs: Double = 0
    var grammarMs: Double = 0
    var durationMs: Double = 0

    var grammarAttempted: Bool = false
    var grammarTimedOut: Bool = false
    var grammarSkippedForLength: Bool = false

    var totalEdits: Int {
        fillerRemovals + backtrackEdits + listItemsFormatted + punctuationEdits + grammarEdits
    }
}

struct TextCleanupResult {
    var text: String
    var stats: TextCleanupStats

    var didChange: Bool {
        stats.totalEdits > 0
    }
}

final class TextCleanupService {
    static let shared = TextCleanupService()
    private init() {}

    func clean(_ text: String, configuration: TextCleanupConfiguration = ModelsConfiguration.load().textCleanup) -> TextCleanupResult {
        let started = CFAbsoluteTimeGetCurrent()
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard configuration.enabled, !input.isEmpty else {
            return TextCleanupResult(text: input, stats: TextCleanupStats())
        }

        var out = input
        var stats = TextCleanupStats()

        if configuration.removeFillers {
            let stageStart = CFAbsoluteTimeGetCurrent()
            let (updated, count) = removeFillers(in: out)
            out = updated
            stats.fillerRemovals = count
            stats.fillerMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
        }

        if configuration.backtrack {
            let stageStart = CFAbsoluteTimeGetCurrent()
            let (updated, count) = applyBacktrack(in: out)
            out = updated
            stats.backtrackEdits = count
            stats.backtrackMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
        }

        if configuration.listFormatting {
            let stageStart = CFAbsoluteTimeGetCurrent()
            let (updated, count) = formatNumberedList(in: out)
            out = updated
            stats.listItemsFormatted = count
            stats.listMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
        }

        if configuration.punctuation {
            let stageStart = CFAbsoluteTimeGetCurrent()
            let (updated, count) = normalizePunctuation(in: out)
            out = updated
            stats.punctuationEdits = count
            stats.punctuationMs = (CFAbsoluteTimeGetCurrent() - stageStart) * 1000
        }

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

    private func removeFillers(in text: String) -> (String, Int) {
        var out = text
        var total = 0

        for regex in Self.multiWordFillerPatterns {
            let (updated, count) = replacingMatches(in: out, regex: regex, with: " ")
            out = updated
            total += count
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = out

        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: out.startIndex..<out.endIndex) { range, _ in
            let token = out[range].lowercased()
            if Self.isSingleWordFiller(token) {
                ranges.append(range)
            }
            return true
        }

        if !ranges.isEmpty {
            for range in ranges.reversed() {
                out.replaceSubrange(range, with: " ")
            }
            total += ranges.count
        }

        return (out, total)
    }

    private func applyBacktrack(in text: String) -> (String, Int) {
        var out = text
        var edits = 0

        while true {
            let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
            guard
                let match = Self.backtrackCuePattern.firstMatch(in: out, options: [], range: nsRange),
                let cueRange = Range(match.range, in: out)
            else {
                break
            }

            let removalStart = startOfPreviousClause(before: cueRange.lowerBound, in: out)
            out.removeSubrange(removalStart..<cueRange.upperBound)
            edits += 1
        }

        return (out, edits)
    }

    private static func isFalsePositiveMarker(match: NSTextCheckingResult, in text: String) -> Bool {
        guard let markerRange = Range(match.range, in: text) else { return true }
        
        // Check if it's explicitly punctuated like "5." or "5)"
        let afterMarker = text[markerRange.upperBound...]
        if let firstChar = afterMarker.first(where: { !$0.isWhitespace }) {
            if firstChar == "." || firstChar == ")" || firstChar == "-" {
                return false // highly likely a valid list marker
            }
        }
        
        let textBefore = text[..<markerRange.lowerBound]
        let wordsBefore = textBefore.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let lastWordBefore = wordsBefore.last?.lowercased().trimmingCharacters(in: .punctuationCharacters)
        
        let prepositions: Set<String> = ["at", "in", "of", "to", "for", "with", "by", "on", "from", "than", "about", "under", "over"]
        if let w = lastWordBefore, prepositions.contains(w) {
            return true
        }
        
        let wordsAfter = afterMarker.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let firstWordAfter = wordsAfter.first?.lowercased().trimmingCharacters(in: .punctuationCharacters)
        
        let multipliers: Set<String> = ["hundred", "thousand", "million", "billion", "trillion", "percent", "dollars", "times"]
        if let w = firstWordAfter, multipliers.contains(w) {
            return true
        }
        
        return false
    }

    private func formatNumberedList(in text: String) -> (String, Int) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.numberMarkerPattern.matches(in: text, options: [], range: nsRange)

        var validMarkers: [NSTextCheckingResult] = []
        var expectedNumber = 1
        for match in matches {
            guard let markerRange = Range(match.range, in: text) else { continue }
            let markerStr = String(text[markerRange]).lowercased()
            let number: Int
            if let mapped = Self.numberWords[markerStr] {
                number = mapped
            } else if let parsed = Int(markerStr.filter { $0.isNumber }) {
                number = parsed
            } else {
                continue
            }
            
            if number == expectedNumber {
                if Self.isFalsePositiveMarker(match: match, in: text) {
                    continue
                }
                validMarkers.append(match)
                expectedNumber += 1
            }
        }

        guard validMarkers.count >= 2 else { return (text, 0) }
        guard let firstRange = Range(validMarkers[0].range, in: text) else { return (text, 0) }

        let prefixRaw = String(text[..<firstRange.lowerBound])
        let prefix = prefixRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        let maxPrefixCount = validMarkers.count >= 3 ? 200 : 40
        if prefix.count > maxPrefixCount {
            return (text, 0)
        }

        var items: [(number: Int, item: String)] = []

        for index in 0..<validMarkers.count {
            guard let markerRange = Range(validMarkers[index].range, in: text) else { return (text, 0) }
            let marker = String(text[markerRange]).lowercased()
            let number: Int
            if let mapped = Self.numberWords[marker] {
                number = mapped
            } else if let parsed = Int(marker.filter { $0.isNumber }) {
                number = parsed
            } else {
                return (text, 0)
            }

            let nextStart: String.Index = {
                if index + 1 < validMarkers.count, let nextRange = Range(validMarkers[index + 1].range, in: text) {
                    return nextRange.lowerBound
                }
                return text.endIndex
            }()

            var item = String(text[markerRange.upperBound..<nextStart])
            item = item.trimmingCharacters(in: Self.listTrimSet)

            let wordCount = item.split(whereSeparator: { $0.isWhitespace }).count
            guard !item.isEmpty, wordCount > 0, wordCount <= 20 else {
                return (text, 0)
            }

            items.append((number, item))
        }

        var parts: [String] = []
        if !prefix.isEmpty {
            parts.append(prefix)
        }
        parts.append(contentsOf: items.map { "\($0.number). \($0.item)" })

        return (parts.joined(separator: "\n"), items.count)
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
            let (updated, count) = replacingMatches(in: out, regex: regex, with: template)
            out = updated
            edits += count
        }

        return (out, edits)
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

    private func startOfPreviousClause(before index: String.Index, in text: String) -> String.Index {
        let prefix = text[..<index]
        if let boundary = prefix.lastIndex(where: { Self.clauseBoundaryCharacters.contains($0) }) {
            return text.index(after: boundary)
        }
        return text.startIndex
    }

    private func replacingMatches(in text: String, regex: NSRegularExpression, with template: String) -> (String, Int) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let count = regex.numberOfMatches(in: text, options: [], range: nsRange)
        guard count > 0 else { return (text, 0) }
        let updated = regex.stringByReplacingMatches(in: text, options: [], range: nsRange, withTemplate: template)
        return (updated, count)
    }

    private static func isSingleWordFiller(_ token: String) -> Bool {
        if singleWordFillerSet.contains(token) {
            return true
        }

        let chars = Array(token)
        guard !chars.isEmpty else { return false }

        if chars.allSatisfy({ $0 == "u" || $0 == "m" }) && token.contains("u") && token.contains("m") {
            return true
        }
        if chars.allSatisfy({ $0 == "u" || $0 == "h" }) && token.contains("u") && token.contains("h") {
            return true
        }

        return false
    }

    private static func isProtectedTerm(_ token: String) -> Bool {
        if token.count <= 1 { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        if token.contains("@") || token.contains("/") || token.contains("_") || token.contains(".") { return true }

        let letters = token.filter { $0.isLetter }
        if letters.count >= 2 && letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        // Keep mixed-case branded or acronym-like terms untouched.
        var sawUpper = false
        var sawLower = false
        for ch in letters {
            if ch.isUppercase { sawUpper = true }
            if ch.isLowercase { sawLower = true }
        }
        return sawUpper && sawLower
    }

    private static let maxGrammarInputCharacters = 1200

    private static let singleWordFillerSet: Set<String> = [
        "um", "uh", "erm", "ah"
    ]

    private static let multiWordFillerPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "(?i)\\byou\\s+know\\b", options: []),
        try! NSRegularExpression(pattern: "(?i)\\bi\\s+mean\\b", options: []),
        try! NSRegularExpression(pattern: "(?i)\\bkind\\s+of\\b", options: []),
        try! NSRegularExpression(pattern: "(?i)\\bsort\\s+of\\b", options: [])
    ]

    private static let backtrackCuePattern = try! NSRegularExpression(
        pattern: "(?i)(?:\\b(?:scratch\\s+that|ignore\\s+that|delete\\s+that|actually|no)\\b[,;:\\-]*\\s*)",
        options: []
    )

    private static let numberMarkerPattern = try! NSRegularExpression(
        pattern: "(?i)\\b(one|two|three|four|five|first|second|third|fourth|fifth|\\d+(?:st|nd|rd|th)?)\\b",
        options: []
    )

    private static let numberWords: [String: Int] = [
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "first": 1,
        "second": 2,
        "third": 3,
        "fourth": 4,
        "fifth": 5
    ]

    private static let spaceBeforePunctuationPattern = try! NSRegularExpression(pattern: "\\s+([,.;:!?])", options: [])
    private static let missingSpaceAfterPunctuationPattern = try! NSRegularExpression(pattern: "([,.;:!?])(?=[\\p{L}\\p{N}])", options: [])
    private static let repeatedPunctuationPattern = try! NSRegularExpression(pattern: "([,.;:!?]){2,}", options: [])
    private static let multiSpacePattern = try! NSRegularExpression(pattern: "[\\t ]{2,}", options: [])
    private static let spaceAroundNewlinePattern = try! NSRegularExpression(pattern: "[\\t ]*\\n[\\t ]*", options: [])

    private static let clauseBoundaryCharacters: Set<Character> = [".", "!", "?", ";", "\n"]
    private static let listTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.!-"))
}
