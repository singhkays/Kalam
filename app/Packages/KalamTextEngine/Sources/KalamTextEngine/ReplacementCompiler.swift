import Foundation
import OSLog

public struct CompiledRule: @unchecked Sendable {
    public let entry: DictionaryEntry
    public let regex: NSRegularExpression
    public let isWordRule: Bool
    public let baseGroupIndex: Int
    public let suffixGroupIndex: Int?
}

public struct CompiledReplacementEngine: @unchecked Sendable {
    public var phraseRules: [CompiledRule] = []
    public var wordRules: [CompiledRule] = []

    public static let empty = CompiledReplacementEngine(phraseRules: [], wordRules: [])

    public init(phraseRules: [CompiledRule] = [], wordRules: [CompiledRule] = []) {
        self.phraseRules = phraseRules
        self.wordRules = wordRules
    }

    public func apply(to text: String) -> (String, Int) {
        var total = 0
        var out = text
        for rule in phraseRules {
            let (newText, count) = CompiledReplacementEngine.apply(rule: rule, to: out)
            out = newText
            total += count
        }
        for rule in wordRules {
            let (newText, count) = CompiledReplacementEngine.apply(rule: rule, to: out)
            out = newText
            total += count
        }
        return (out, total)
    }

    private static func apply(rule: CompiledRule, to text: String) -> (String, Int) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = rule.regex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty { return (text, 0) }

        var result = String()
        var lastLocation = 0
        var count = 0

        for m in matches {
            let mRange = m.range
            guard mRange.location != NSNotFound else { continue }
            let beforeRange = NSRange(location: lastLocation, length: mRange.location - lastLocation)
            result.append(nsText.substring(with: beforeRange))

            let entry = rule.entry
            let matchedString = nsText.substring(with: mRange)

            let replacement: String
            if rule.isWordRule {
                let baseRange = m.range(at: rule.baseGroupIndex)
                let baseText = baseRange.location != NSNotFound ? nsText.substring(with: baseRange) : matchedString
                let suffixText: String = {
                    if let sIdx = rule.suffixGroupIndex {
                        let r = m.range(at: sIdx)
                        if r.location != NSNotFound, r.length > 0 {
                            return nsText.substring(with: r)
                        }
                    }
                    return ""
                }()

                let baseRepl = entry.preserveCase ? CaseHelper.adjustCase(of: entry.replacement, toMatch: baseText) : entry.replacement
                replacement = baseRepl + suffixText
            } else {
                let baseRepl: String
                if entry.preserveCase {
                    baseRepl = CaseHelper.adjustCaseForPhrase(of: entry.replacement, toMatch: matchedString)
                } else {
                    baseRepl = entry.replacement
                }
                replacement = baseRepl
            }

            result.append(replacement)
            count += 1
            lastLocation = mRange.location + mRange.length
        }

        if lastLocation < nsText.length {
            let tailRange = NSRange(location: lastLocation, length: nsText.length - lastLocation)
            result.append(nsText.substring(with: tailRange))
        }

        return (result, count)
    }
}

public enum ReplacementCompiler {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")

    public static func compile(entries: [DictionaryEntry]) -> CompiledReplacementEngine {
        let cleaned = entries
            .filter { $0.isEnabled }
            .map { e -> DictionaryEntry in
                var e = e
                e.trigger = e.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                e.replacement = e.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                return e
            }
            .filter { !$0.trigger.isEmpty && !$0.replacement.isEmpty }

        var seen = Set<String>()
        var deduped: [DictionaryEntry] = []
        for e in cleaned.reversed() {
            let k = "\(e.trigger.lowercased())|\(e.caseInsensitive)|\(e.preserveCase)|\(e.isPhrase)"
            if !seen.contains(k) {
                deduped.append(e)
                seen.insert(k)
            }
        }
        deduped.reverse()

        let phrases = deduped.filter { $0.isPhrase }.sorted { $0.trigger.count > $1.trigger.count }
        let words = deduped.filter { !$0.isPhrase }.sorted { $0.trigger.count > $1.trigger.count }

        var phraseRules: [CompiledRule] = []
        var wordRules: [CompiledRule] = []

        for e in phrases {
            if let r = compilePhraseRule(e) {
                phraseRules.append(r)
            }
        }
        for e in words {
            if let r = compileWordRule(e) {
                wordRules.append(r)
            }
        }

        let enabledCount = entries.filter(\.isEnabled).count
        Self.logger.info("Custom dictionary compiled phraseRules=\(phraseRules.count, privacy: .public) wordRules=\(wordRules.count, privacy: .public) enabledEntries=\(enabledCount, privacy: .public)")
        return CompiledReplacementEngine(phraseRules: phraseRules, wordRules: wordRules)
    }

    private static func compilePhraseRule(_ e: DictionaryEntry) -> CompiledRule? {
        let tokens = e.trigger.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return nil }
        var pattern = tokens.joined(separator: "\\s+")
        pattern = "\\b" + pattern + "\\b"

        var opts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if e.caseInsensitive {
            opts.insert(.caseInsensitive)
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return CompiledRule(entry: e, regex: re, isWordRule: false, baseGroupIndex: 0, suffixGroupIndex: nil)
    }

    private static func compileWordRule(_ e: DictionaryEntry) -> CompiledRule? {
        let trigger = NSRegularExpression.escapedPattern(for: e.trigger)
        let baseGroupIndex = 1

        let pattern = "\\b(" + trigger + ")" + "(" + "'s|’s|s'|es|s" + ")?\\b"
        let suffixIndex = 2

        var opts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if e.caseInsensitive { opts.insert(.caseInsensitive) }

        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return CompiledRule(entry: e, regex: re, isWordRule: true, baseGroupIndex: baseGroupIndex, suffixGroupIndex: suffixIndex)
    }
}
