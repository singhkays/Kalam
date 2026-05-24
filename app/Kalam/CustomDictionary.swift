import Foundation
import OSLog
import SwiftUI

// MARK: - Dictionary Model
struct DictionaryEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var trigger: String
    var replacement: String
    
    var isEnabled: Bool = true
    
    var caseInsensitive: Bool = true
    var preserveCase: Bool = true
    
    var isPhrase: Bool {
        trigger.contains(where: { $0.isWhitespace })
    }
    
    var userAdded: Bool = true
    
    init(id: UUID = UUID(),
         trigger: String,
         replacement: String,
         isEnabled: Bool = true,
         caseInsensitive: Bool = true,
         preserveCase: Bool = true,
         userAdded: Bool = true)
    {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.caseInsensitive = caseInsensitive
        self.preserveCase = preserveCase
        self.userAdded = userAdded
    }
    
    // Computed: Non-default options for badges (simplified)
    var nonDefaultOptions: [String] {
        var options: [String] = []
        if !caseInsensitive { options.append("Case Sensitive") }
        if !preserveCase { options.append("Ignore Case") }
        if isPhrase { options.append("Phrase") }
        return options
    }
    
    // Computed: Live examples of what this entry covers
    var exampleMatches: [String] {
        guard !trigger.isEmpty && !replacement.isEmpty else { return [] }
        
        func format(_ s: String) -> String {
            let r: String
            if !isPhrase {
                // Check for common suffixes in the source matching variant to show realistic output
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
                    // Match the base casing first, then append the suffix
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
        
        // Casing variants
        if caseInsensitive || preserveCase {
            variants.append(trigger.lowercased())
            // Title case
            if trigger.count > 0 {
                let title = trigger.prefix(1).uppercased() + trigger.dropFirst().lowercased()
                variants.append(title)
            }
            // ALL CAPS (only for 2+ chars)
            if trigger.count > 1 {
                variants.append(trigger.uppercased())
            }
        } else {
            // Literal casing match
            variants.append(trigger)
        }
        
        // Suffixes for single words to show coverage
        if !isPhrase {
            let base = trigger.lowercased()
            variants.append("\(base)s")
            variants.append("\(base)'s")
        }
        
        // Return sorted, formatted unique examples
        return Array(Set(variants))
            .sorted { a, b in
                // Sort by length then alphabetically
                if a.count != b.count { return a.count < b.count }
                return a < b
            }
            .map { format($0) }
    }
}

// In-memory compiled rule
struct CompiledRule {
    let entry: DictionaryEntry
    let regex: NSRegularExpression
    let isWordRule: Bool
    // Groups for word rules
    let baseGroupIndex: Int
    let suffixGroupIndex: Int?
}

// Compiled engine
struct CompiledReplacementEngine {
    var phraseRules: [CompiledRule] = []
    var wordRules: [CompiledRule] = []
    
    static let empty = CompiledReplacementEngine(phraseRules: [], wordRules: [])
    
    func apply(to text: String) -> (String, Int) {
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
            // Append preceding segment
            let beforeRange = NSRange(location: lastLocation, length: mRange.location - lastLocation)
            result.append(nsText.substring(with: beforeRange))
            
            let entry = rule.entry
            let matchedString = nsText.substring(with: mRange)
            
            // Build replacement with options
            let replacement: String
            if rule.isWordRule {
                // Base and suffix
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
                // Phrase rule
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
        
        // Append trailing segment
        if lastLocation < nsText.length {
            let tailRange = NSRange(location: lastLocation, length: nsText.length - lastLocation)
            result.append(nsText.substring(with: tailRange))
        }
        
        return (result, count)
    }
}

enum ReplacementCompiler {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")

    static func compile(entries: [DictionaryEntry]) -> CompiledReplacementEngine {
        // Filter invalid/empty triggers AND disabled entries
        let cleaned = entries
            .filter { $0.isEnabled } // Only compile enabled entries
            .map { e -> DictionaryEntry in
                var e = e
                // Trim whitespace from trigger and replacement
                e.trigger = e.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                e.replacement = e.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                // The 'isPhrase' logic is now automatic in the struct, so we no longer set it here.
                return e
            }
            .filter { !$0.trigger.isEmpty && !$0.replacement.isEmpty }
        
        // Deduplicate by (trigger, options) — last wins
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
        
        // Compile phrase rules first (longest triggers first)
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
        // Escape tokens, allow flexible whitespace between them
        let tokens = e.trigger.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return nil }
        var pattern = tokens.joined(separator: "\\s+")
        // Enforce whole word for phrases
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
        
        // Always enforce morphological (suffixes) and whole word for single words
        // Capture base, then optional suffix, enforce trailing boundary after suffix
        // Suffix includes: 's, ’s, s', es, s
        let pattern = "\\b(" + trigger + ")" + "(" + "'s|’s|s'|es|s" + ")?\\b" // group 1 = base, group 2 = suffix
        let suffixIndex = 2
        
        var opts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if e.caseInsensitive { opts.insert(.caseInsensitive) }
        
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return CompiledRule(entry: e, regex: re, isWordRule: true, baseGroupIndex: baseGroupIndex, suffixGroupIndex: suffixIndex)
    }
}


enum CaseHelper {
    static func adjustCase(of replacement: String, toMatch source: String) -> String {
        if source.isEmpty || replacement.isEmpty { return replacement }
        
        // If replacement is truly mixed-case/branded (e.g. "iPad", "eBay", "Main St"),
        // we respect the user's explicit casing unless the source is ALL CAPS (shouting).
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
        // Mixed or branded case, leave as user-specified replacement
        return replacement
    }
    
    static func adjustCaseForPhrase(of replacement: String, toMatch source: String) -> String {
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
            // Capitalize each word token in replacement
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
        // Require each token to be title-cased
        return tokens.allSatisfy { isTitleWord(String($0)) }
    }
    
    private static func isMixedCase(_ s: String) -> Bool {
        // We consider it "Mixed/Branded" if there is an uppercase letter 
        // that is NOT at the very beginning of the string.
        // e.g. "iPad", "eBay", "Main St", "123 Main St" vs "Orange" or "orange"
        guard s.count > 1 else { return false }
        let suffix = s.dropFirst()
        return suffix.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }
}

// Persistence + Manager
@MainActor
final class CustomDictionaryManager: ObservableObject {
    static let shared = CustomDictionaryManager()
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")
    private init() {}
    
    @Published var entries: [DictionaryEntry] = []
    
    private let fileName = "user_dictionary.json"
    private var appSupportURL: URL {
        let fm = FileManager.default
        let appName = "Kalam"
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }
    
    private var compiled: CompiledReplacementEngine = .empty
    
    private var debounceWork: DispatchWorkItem?
    
    var isFirstLaunch: Bool {
        guard FileManager.default.fileExists(atPath: appSupportURL.path) else { return true }
        // Check if file has userAdded entries; if all false or empty, treat as first
        return entries.isEmpty || !entries.contains(where: { $0.userAdded })
    }
    
    func bootstrap() {
        logger.info("Custom dictionary bootstrap started")
        load()
        recompile()
        logger.info("Custom dictionary bootstrap complete: entries=\(self.entries.count), firstLaunch=\(self.isFirstLaunch)")
    }
    
    func apply(to text: String) -> (String, Int) {
        let (out, count) = compiled.apply(to: text)
        if count > 0 {
            logger.info("Custom dictionary applied replacements=\(count), outputLength=\(out.count)")
        }
        return (out, count)
    }
    
    func addEntry(_ entry: DictionaryEntry) {
        logger.info("Custom dictionary adding entry; previousCount=\(self.entries.count)")
        entries.append(entry)
        logger.info("Custom dictionary entry added; count=\(self.entries.count)")
        entriesDidChange()
    }
    
    func removeEntries(withIds ids: [UUID]) {
        guard !ids.isEmpty else { return }
        logger.info("Custom dictionary removing entries=\(ids.count), previousCount=\(self.entries.count)")
        let beforeCount = entries.count
        entries.removeAll { ids.contains($0.id) }
        logger.info("Custom dictionary removed entries; count=\(self.entries.count), removed=\(beforeCount - self.entries.count)")
        entriesDidChange()
    }
    
    func sortEntriesByTrigger() {
        logger.info("Custom dictionary sorting entries=\(self.entries.count)")
        entries.sort { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        entriesDidChange()
    }
    
    func importJSON(from url: URL) throws {
        logger.info("Custom dictionary import started")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        entries = decoded
        logger.info("Custom dictionary import complete; count=\(self.entries.count)")
        save()
        recompile()
    }
    
    func exportJSON(to url: URL) throws {
        logger.info("Custom dictionary export started; count=\(self.entries.count)")
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
        logger.info("Custom dictionary export complete")
    }
    
    private func load() {
        let url = appSupportURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            logger.info("Custom dictionary file missing; starting empty")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            entries = decoded.filter { $0.userAdded }
            logger.info("Custom dictionary loaded entries=\(decoded.count), userEntries=\(self.entries.count)")
        } catch {
            logger.warning("Custom dictionary load failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            entries = []
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: appSupportURL, options: .atomic)
            logger.info("Custom dictionary saved entries=\(self.entries.count)")
        } catch {
            logger.warning("Custom dictionary save failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }
    }
    
    func saveImmediately() {
        debounceWork?.cancel()
        debounceWork = nil
        save()
        recompile()
        logger.info("Custom dictionary immediate save triggered")
    }
    
    func entriesDidChange() {
        debounceWork?.cancel()
        recompile()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    
    private func recompile() {
        compiled = ReplacementCompiler.compile(entries: entries)
    }
    
    func reloadFromDisk() {
        load()
        recompile()
    }
}
