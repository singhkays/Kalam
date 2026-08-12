import Foundation

/// Protects spoken-number spans that the ITN tagger mis-normalizes, so that
/// natural dictation like "one of us" or "a two to three pager" survives
/// inverse text normalization unchanged.
///
/// ITN (NemoTextProcessing) converts number words to digits, and its taggers
/// misfire on:
/// - numeric ranges:   "two to three pager" -> "02:58 pager"
/// - partitive idioms: "one of us"          -> "1 of us"
/// - digit sequences:  "five five five..."  -> "16 9"
///
/// The pipeline masks protectable spans with unique placeholder tokens before
/// ITN runs, then restores the original spoken forms afterwards. Tokens are
/// letters-only so ITN never treats them as normalizable input. Custom
/// `nemo_add_rule` identity rules were verified NOT to block the built-in
/// taggers — masking is the only reliable mechanism.
public struct ITNSpanProtector: Sendable {
    public struct ProtectedSpan: Equatable, Sendable {
        public let token: String
        public let original: String

        public init(token: String, original: String) {
            self.token = token
            self.original = original
        }
    }

    public init() {}

    /// Replaces every protectable span with a unique placeholder token.
    /// Spans are returned in text order; `restore(_:spans:)` works regardless
    /// of order because tokens are unique.
    public func protect(_ text: String) -> (text: String, spans: [ProtectedSpan]) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [NSRange] = []
        for pattern in Self.protectionPatterns {
            matches.append(contentsOf: pattern.matches(in: text, options: [], range: nsRange).map(\.range))
        }
        guard !matches.isEmpty else { return (text, []) }

        matches.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for match in matches {
            if let last = merged.last, match.location <= last.location + last.length {
                let end = max(last.location + last.length, match.location + match.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(match)
            }
        }

        var spans: [ProtectedSpan] = []
        var masked = ""
        var cursor = text.startIndex
        for (index, range) in merged.enumerated() {
            guard let swiftRange = Range(range, in: text) else { continue }
            masked += text[cursor..<swiftRange.lowerBound]
            let token = "XXKALAMSPAN\(index)XX"
            spans.append(ProtectedSpan(token: token, original: String(text[swiftRange])))
            masked += token
            cursor = swiftRange.upperBound
        }
        masked += text[cursor...]
        return (masked, spans)
    }

    /// Restores the original span text in a normalized (masked) string.
    public func restore(_ text: String, spans: [ProtectedSpan]) -> String {
        var out = text
        for span in spans {
            out = out.replacingOccurrences(of: span.token, with: span.original)
        }
        return out
    }

    // MARK: - Patterns

    private static let numberWord =
        "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|" +
        "thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|" +
        "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|" +
        "hundred|thousand|million|billion)"
    private static let simpleNumberWord =
        "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let ordinalWord =
        "(?:first|second|third|fourth|fifth)"
    private static let tensWord =
        "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"

    /// "two to three", "twelve through fourteen" — ITN reads these as times
    /// ("02:58", "13:48"). Word separators only; digit ranges ("2 to 3")
    /// pass through untouched (verified against the real library).
    private static let rangePattern = try! NSRegularExpression(
        pattern: "(?i)\\b\(numberWord)\\s+(?:to|through)\\s+\(numberWord)\\b",
        options: []
    )

    /// "one of us", "two of the team", "first of all" — ITN digitizes the
    /// number word ("1 of us", "1st of all"). The fixed-width tens-word
    /// lookbehind keeps compound numbers like "twenty one of us" out (those
    /// SHOULD normalize to "21 of us").
    private static let idiomPattern = try! NSRegularExpression(
        pattern: "(?i)(?<!\\b\(tensWord)\\s)\\b(?:\(simpleNumberWord)|\(ordinalWord))\\s+of\\b",
        options: []
    )

    /// "five five five one two three four", "one two three" — digit-by-digit
    /// sequences ITN turns into arithmetic ("16 9", "10 05:06"). Runs of
    /// simple number words only, so "twenty twenty five" (-> 2025) and
    /// "two hundred" (-> 200) are unaffected.
    private static let runPattern = try! NSRegularExpression(
        pattern: "(?i)\\b\(simpleNumberWord)(?:\\s+\(simpleNumberWord))+\\b",
        options: []
    )

    private static let protectionPatterns: [NSRegularExpression] = [
        rangePattern, idiomPattern, runPattern
    ]
}
