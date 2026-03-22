import Foundation
#if canImport(CNemoTextProcessing)
import CNemoTextProcessing
#endif

/// Swift wrapper for NeMo Text Processing (Inverse Text Normalization).
///
/// Converts spoken-form ASR output to written form:
/// - "two hundred thirty two" → "232"
/// - "five dollars and fifty cents" → "$5.50"
/// - "january fifth twenty twenty five" → "January 5, 2025"
/// - "period" → "."
public enum NemoTextProcessing {
    private static let numericMultiplierPattern = try! NSRegularExpression(
        pattern: #"(?i)\b\d+\s+(hundred|thousand|million|billion|trillion)\b"#,
        options: []
    )

    public static var isAvailable: Bool {
        #if canImport(CNemoTextProcessing)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Normalization

    /// Normalize spoken-form text to written form.
    ///
    /// Tries to match the entire input as a single expression.
    /// Use `normalizeSentence` for inputs containing mixed natural language and spoken forms.
    ///
    /// - Parameter input: Spoken-form text from ASR
    /// - Returns: Written-form text, or original if no normalization applies
    public static func normalize(_ input: String) -> String {
        #if canImport(CNemoTextProcessing)
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }

        return String(cString: resultPtr)
        #else
        return input
        #endif
    }

    /// Normalize a full sentence, replacing spoken-form spans with written form.
    ///
    /// Scans for normalizable spans within a larger sentence using a sliding window.
    /// Uses a default max span of 16 tokens.
    ///
    /// - Parameter input: Sentence containing spoken-form spans
    /// - Returns: Sentence with spoken-form spans replaced
    ///
    /// Example:
    /// ```swift
    /// let result = NemoTextProcessing.normalizeSentence("I have twenty one apples")
    /// // result is "I have 21 apples"
    /// ```
    public static func normalizeSentence(_ input: String) -> String {
        #if canImport(CNemoTextProcessing)
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize_sentence(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }

        return String(cString: resultPtr)
        #else
        return input
        #endif
    }

    /// Normalize a full sentence with a configurable max span size.
    ///
    /// - Parameters:
    ///   - input: Sentence containing spoken-form spans
    ///   - maxSpanTokens: Maximum consecutive tokens per normalizable span (default 16)
    /// - Returns: Sentence with spoken-form spans replaced
    public static func normalizeSentence(_ input: String, maxSpanTokens: UInt32) -> String {
        guard !shouldBypassSentenceNormalization(input) else {
            return input
        }
        #if canImport(CNemoTextProcessing)
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize_sentence_with_max_span(cString, maxSpanTokens) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }

        return String(cString: resultPtr)
        #else
        return input
        #endif
    }

    private static func shouldBypassSentenceNormalization(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return numericMultiplierPattern.firstMatch(in: input, options: [], range: range) != nil
    }

    // MARK: - Custom Rules

    /// Add a custom spoken→written normalization rule.
    ///
    /// Custom rules have the highest priority, checked before all built-in taggers.
    /// Matching is case-insensitive on the spoken form.
    /// If a rule with the same spoken form exists, it is replaced.
    ///
    /// - Parameters:
    ///   - spoken: The spoken form to match (e.g., "gee pee tee")
    ///   - written: The written replacement (e.g., "GPT")
    public static func addRule(spoken: String, written: String) {
        #if canImport(CNemoTextProcessing)
        spoken.withCString { spokenPtr in
            written.withCString { writtenPtr in
                nemo_add_rule(spokenPtr, writtenPtr)
            }
        }
        #endif
    }

    /// Remove a custom normalization rule.
    ///
    /// - Parameter spoken: The spoken form to remove
    /// - Returns: True if the rule was found and removed
    @discardableResult
    public static func removeRule(spoken: String) -> Bool {
        #if canImport(CNemoTextProcessing)
        return spoken.withCString { spokenPtr in
            nemo_remove_rule(spokenPtr) != 0
        }
        #else
        return false
        #endif
    }

    /// Clear all custom normalization rules.
    public static func clearRules() {
        #if canImport(CNemoTextProcessing)
        nemo_clear_rules()
        #endif
    }

    /// The number of custom rules currently registered.
    public static var ruleCount: Int {
        #if canImport(CNemoTextProcessing)
        Int(nemo_rule_count())
        #else
        0
        #endif
    }

    // MARK: - Info

    /// Get the library version.
    public static var version: String? {
        #if canImport(CNemoTextProcessing)
        guard let versionPtr = nemo_version() else {
            return nil
        }
        return String(cString: versionPtr)
        #else
        return nil
        #endif
    }
}
