import Foundation

public enum CaseHelper {
    public static func adjustCase(of replacement: String, toMatch source: String) -> String {
        if source.isEmpty || replacement.isEmpty { return replacement }

        if isMixedCase(replacement) {
            if isAllUpper(source) && source.count > 1 {
                return replacement.uppercased()
            }
            return replacement
        }

        if isAllUpper(source) && source.count > 1 {
            return replacement.uppercased()
        }
        if isAllLower(source) {
            return replacement.lowercased()
        }
        if isTitleWord(source) {
            return titleWord(replacement)
        }
        return replacement
    }

    public static func adjustCaseForPhrase(of replacement: String, toMatch source: String) -> String {
        if source.isEmpty || replacement.isEmpty { return replacement }

        if isMixedCase(replacement) {
            if isAllUpper(source) && source.count > 1 {
                return replacement.uppercased()
            }
            return replacement
        }

        if isAllUpper(source) && source.count > 1 {
            return replacement.uppercased()
        }
        if isAllLower(source) {
            return replacement.lowercased()
        }
        if isTitlePhrase(source) {
            return replacement
                .split(whereSeparator: { $0.isWhitespace })
                .map { titleWord(String($0)) }
                .joined(separator: " ")
        }
        return replacement
    }

    private static func isAllUpper(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isAllLower(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
    }

    private static func isTitleWord(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var sawLetter = false
        var firstHandled = false
        for ch in s {
            if ch.isLetter {
                if !firstHandled {
                    if !String(ch).uppercased().elementsEqual(String(ch)) { return false }
                    firstHandled = true
                } else {
                    if !String(ch).lowercased().elementsEqual(String(ch)) { return false }
                }
                sawLetter = true
            }
        }
        return sawLetter
    }

    private static func titleWord(_ s: String) -> String {
        guard let first = s.first else { return s }
        let firstUpper = String(first).uppercased()
        let rest = String(s.dropFirst()).lowercased()
        return firstUpper + rest
    }

    private static func isTitlePhrase(_ s: String) -> Bool {
        let tokens = s.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { isTitleWord(String($0)) }
    }

    private static func isMixedCase(_ s: String) -> Bool {
        guard s.count > 1 else { return false }
        let suffix = s.dropFirst()
        return suffix.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }
}
