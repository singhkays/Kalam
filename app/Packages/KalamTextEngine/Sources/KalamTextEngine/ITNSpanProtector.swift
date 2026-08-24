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
/// - spoken times:     "at ten thirty"      -> "40" (sum composition, K-43)
///
/// K-42 (2026-08-24, probed against the real library): ASR also emits
/// comma/period-separated and mixed word+digit runs; whitespace-only joins
/// missed those. Separators now include ", ." and runs may mix words with
/// 1-2 digit tokens.
///
/// Temporal spans ("at ten thirty") are RENDERED by us as "H:MM" instead of
/// being restored verbatim: Nemo composes the pair as a sum ("40"), so the
/// only deterministic dodge is to not let Nemo see it.
///
/// Patterns below are built by CONCATENATION, not string interpolation, so
/// no regex fragment depends on "\(...)" surviving a shared-mount edit.
public struct ITNSpanProtector: Sendable {
    public struct ProtectedSpan: Equatable, Sendable {
        public let token: String
        public let original: String
        /// What `restore` puts back. Equal to `original` except for temporal
        /// spans, which render as clock time ("at ten thirty" -> "at 10:30").
        public let rendered: String

        public init(token: String, original: String, rendered: String? = nil) {
            self.token = token
            self.original = original
            self.rendered = rendered ?? original
        }
    }

    public init() {}

    /// Replaces every protectable span with a unique placeholder token.
    public func protect(_ text: String) -> (text: String, spans: [ProtectedSpan]) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var tagged: [(range: NSRange, temporal: Bool)] = []
        for pattern in Self.protectionPatterns {
            let isTemporal = pattern === Self.temporalPattern
            for m in pattern.matches(in: text, options: [], range: nsRange) {
                tagged.append((m.range, isTemporal))
            }
        }
        guard !tagged.isEmpty else { return (text, []) }

        tagged.sort { $0.range.location < $1.range.location }
        var merged: [(range: NSRange, temporal: Bool)] = []
        for item in tagged {
            if let last = merged.last, item.range.location <= last.range.location + last.range.length {
                let end = max(last.range.location + last.range.length, item.range.location + item.range.length)
                merged[merged.count - 1] = (NSRange(location: last.range.location, length: end - last.range.location),
                                            last.temporal || item.temporal)
            } else {
                merged.append(item)
            }
        }

        var spans: [ProtectedSpan] = []
        var masked = ""
        var cursor = text.startIndex
        for (index, item) in merged.enumerated() {
            guard let swiftRange = Range(item.range, in: text) else { continue }
            masked += text[cursor..<swiftRange.lowerBound]
            let original = String(text[swiftRange])
            let token = "XXKALAMSPAN\(index)XX"
            let rendered = item.temporal ? (Self.renderClockTime(original) ?? original) : original
            spans.append(ProtectedSpan(token: token, original: original, rendered: rendered))
            masked += token
            cursor = swiftRange.upperBound
        }
        masked += text[cursor...]
        return (masked, spans)
    }

    /// Restores spans, substituting the rendered form for temporal ones.
    public func restore(_ text: String, spans: [ProtectedSpan]) -> String {
        var out = text
        for span in spans {
            out = out.replacingOccurrences(of: span.token, with: span.rendered)
        }
        return out
    }

    // MARK: - Clock-time rendering (K-43)

    private static let hourWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
    ]
    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let teensWords: [String: Int] = [
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let unitWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]
    private static let timePrepositions: Set<String> = ["at", "until", "by", "around"]

    /// "ten thirty" -> "10:30", "at twelve fifteen" -> "at 12:15",
    /// "at ten twenty five" -> "at 10:25" (preposition preserved). Nil for
    /// anything else — caller restores verbatim (fail-open, never corrupts).
    static func renderClockTime(_ spoken: String) -> String? {
        var tokens = spoken.lowercased()
            .split(whereSeparator: { ",. ".contains($0) })
            .map(String.init)
        var prefix = ""
        if let first = tokens.first, timePrepositions.contains(first) {
            prefix = first + " "
            tokens.removeFirst()
        }
        guard (2...3).contains(tokens.count),
              let hour = hourWords[tokens[0]]
        else { return nil }

        let minutes: Int
        if let teens = teensWords[tokens[1]] {
            guard tokens.count == 2 else { return nil }
            minutes = teens
        } else if let tens = tensWords[tokens[1]] {
            if tokens.count == 3, let unit = unitWords[tokens[2]] {
                minutes = tens + unit
            } else if tokens.count == 2 {
                minutes = tens
            } else {
                return nil
            }
        } else {
            return nil
        }
        return prefix + String(format: "%02d:%02d", hour, minutes)
    }

    // MARK: - Regex fragments (concatenated, never interpolated)

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
    private static let teensWord =
        "(?:thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"

    /// Dictation separators: spaces, commas, periods (Parakeet punctuates
    /// sequences: "five, five, five, ...").
    private static let sep = "[,\\s.]+"
    private static let optSep = "[,\\s.]?"
    /// Run tokens: simple words or short standalone digits (mixed sequences).
    private static let runToken = "(?:" + simpleNumberWord + "|\\d{1,2})"

    // MARK: - Patterns

    /// "at ten thirty", "around twelve fifteen" — Nemo SUMS the two-token
    /// pair ("40", K-43). Probe-established boundary (2026-08-24): the
    /// THREE-token form ("two fifty three") is handled CORRECTLY by Nemo
    /// ("02:53"), so the mask stops after tens/teens minutes and refuses
    /// when another number word follows — those stay with Nemo's correct
    /// time handler. Hour one-twelve keeps phone sequences and years out.
    private static let temporalPattern = try! NSRegularExpression(
        pattern: "(?i)\\b(?:at|until|by|around)\\s+" + simpleNumberWord + optSep +
            "(?:" + tensWord + "|" + teensWord + ")" +
            "(?![,\\s.]?" + numberWord + "\\b)",
        options: []
    )

    /// "two to three", "twelve through fourteen" — ITN reads these as times.
    private static let rangePattern = try! NSRegularExpression(
        pattern: "(?i)\\b" + numberWord + sep + "(?:to|through)" + sep + numberWord + "\\b",
        options: []
    )

    /// "one of us", "first of all" — fixed-width tens lookbehind keeps
    /// compound numbers ("twenty one of us" SHOULD normalize) out.
    private static let idiomPattern = try! NSRegularExpression(
        pattern: "(?i)(?<!\\b" + tensWord + "\\s)\\b(?:" + simpleNumberWord + "|" + ordinalWord + ")\\s+of\\b",
        options: []
    )

    /// "five five five one two three four", "five, five, five...",
    /// "five 5 five 1 two three 4" — >=3 tokens so "twenty twenty five"
    /// and "two hundred" stay with Nemo's year/quantity handlers.
    private static let runPattern = try! NSRegularExpression(
        pattern: "(?i)\\b" + runToken + "(?:" + sep + runToken + "){2,}\\b",
        options: []
    )

    private static let protectionPatterns: [NSRegularExpression] = [
        temporalPattern, rangePattern, idiomPattern, runPattern
    ]
}
