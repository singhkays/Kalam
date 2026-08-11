import Foundation

public struct DictionaryEntry: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var trigger: String
    public var replacement: String

    public var isEnabled: Bool = true

    public var wholeWord: Bool = true
    public var caseInsensitive: Bool = true
    public var preserveCase: Bool = true
    public var morphological: Bool = true

    public var isPhrase: Bool {
        trigger.contains(where: { $0.isWhitespace })
    }

    public var userAdded: Bool = true

    public init(id: UUID = UUID(),
         trigger: String,
         replacement: String,
         isEnabled: Bool = true,
         wholeWord: Bool = true,
         caseInsensitive: Bool = true,
         preserveCase: Bool = true,
         morphological: Bool = true,
         userAdded: Bool = true)
    {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.wholeWord = wholeWord
        self.caseInsensitive = caseInsensitive
        self.preserveCase = preserveCase
        self.morphological = morphological
        self.userAdded = userAdded
    }

    public var nonDefaultOptions: [String] {
        var options: [String] = []
        if !caseInsensitive { options.append("Case Sensitive") }
        if !preserveCase { options.append("Ignore Case") }
        if isPhrase { options.append("Phrase") }
        return options
    }

    public var exampleMatches: [String] {
        guard !trigger.isEmpty && !replacement.isEmpty else { return [] }

        func format(_ s: String) -> String {
            let r: String
            if !isPhrase {
                let commonSuffixes = ["'s", "’s", "s'", "es", "s"]
                var foundSuffix = ""
                let lowerS = s.lowercased()
                let lowerTrigger = trigger.lowercased()

                for suffix in commonSuffixes {
                    if lowerS == lowerTrigger + suffix {
                        foundSuffix = suffix
                        break
                    }
                }

                if !foundSuffix.isEmpty {
                    let baseMatched = String(s.dropLast(foundSuffix.count))
                    let adjustedBase = CaseHelper.adjustCase(of: replacement, toMatch: baseMatched)
                    r = adjustedBase + foundSuffix
                } else {
                    r = CaseHelper.adjustCase(of: replacement, toMatch: s)
                }
            } else {
                r = CaseHelper.adjustCaseForPhrase(of: replacement, toMatch: s)
            }
            return "\(s) → \(r)"
        }

        var variants: [String] = []

        if caseInsensitive || preserveCase {
            variants.append(trigger.lowercased())
            if trigger.count > 0 {
                let title = trigger.prefix(1).uppercased() + trigger.dropFirst().lowercased()
                variants.append(title)
            }
            if trigger.count > 1 {
                variants.append(trigger.uppercased())
            }
        } else {
            variants.append(trigger)
        }

        if !isPhrase {
            let base = trigger.lowercased()
            variants.append("\(base)s")
            variants.append("\(base)'s")
        }

        return Array(Set(variants))
            .sorted { a, b in
                if a.count != b.count { return a.count < b.count }
                return a < b
            }
            .map { format($0) }
    }
}
