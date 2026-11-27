import Darwin
import Foundation
import OSLog
import KalamTextEngine

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

@MainActor
final class CustomDictionaryManager: ObservableObject {
    static let shared = CustomDictionaryManager()

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var loadFailureNotice: String?

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")
    private let storeURLOverride: URL?
    private let scheduleSave: (DispatchWorkItem) -> Void
    private let compileEntries: ([DictionaryEntry]) -> CompiledReplacementEngine
    private let replaceBackup: (URL, URL) throws -> Void
    private let fileName = "user_dictionary.json"

    private var compiled: CompiledReplacementEngine = .empty
    private var debounceWork: DispatchWorkItem?
    private var hasPendingSave = false
    private var protectsOriginal = false

    init(
        storeURL: URL? = nil,
        scheduleSave: @escaping (DispatchWorkItem) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        },
        compileEntries: @escaping ([DictionaryEntry]) -> CompiledReplacementEngine = ReplacementCompiler.compile,
        replaceBackup: @escaping (URL, URL) throws -> Void = CustomDictionaryManager.installBackup
    ) {
        storeURLOverride = storeURL
        self.scheduleSave = scheduleSave
        self.compileEntries = compileEntries
        self.replaceBackup = replaceBackup
    }

    private var appSupportURL: URL {
        if let storeURLOverride { return storeURLOverride }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Kalam", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }

    /// The postprocessor snapshots the compiled dictionary on the main actor.
    var currentCompiledEngine: CompiledReplacementEngine { compiled }

    func bootstrap() {
        let loaded = load()
        compiled = compileEntries(loaded)
        entries = loaded
        logger.info("Custom dictionary loaded entries=\(self.entries.count, privacy: .public)")
    }

    func apply(to text: String) -> (String, Int) {
        let (out, count) = compiled.apply(to: text)
        if count > 0 {
            logger.debug("Custom dictionary applied replacements=\(count), outputLength=\(out.count)")
        }
        return (out, count)
    }

    func addEntry(_ entry: DictionaryEntry) {
        stage(entries + [entry])
    }

    func updateEntry(id: UUID, edit: (inout DictionaryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries
        edit(&next[index])
        next[index].id = id
        stage(next)
    }

    func removeEntry(id: UUID) {
        stage(entries.filter { $0.id != id })
    }

    /// The one-time Settings migration re-enables legacy disabled rules.
    func migrateDisabledEntries() -> Bool {
        guard !protectsOriginal else { return false }
        let enabled = entries.map { entry in
            var result = entry
            result.isEnabled = true
            return result
        }
        if replaceEntries(with: enabled) {
            return flushPendingSave()
        }
        return !hasPendingSave
    }

    func importJSON(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        // An explicit import makes the entries user-owned.
        let imported = decoded.map { entry in
            var owned = entry
            owned.userAdded = true
            return owned
        }
        if replaceEntries(with: imported) {
            flushPendingSave()
        }
    }

    func exportJSON(to url: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
    }

    private func load() -> [DictionaryEntry] {
        let url = appSupportURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var original: Data?
        do {
            let data = try Data(contentsOf: url)
            original = data
            return try JSONDecoder().decode([DictionaryEntry].self, from: data).filter(\.userAdded)
        } catch {
            logger.warning("Custom dictionary load failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            if let original, preserveCorruptFile(original, at: url) {
                loadFailureNotice = "Kalam couldn’t read your dictionary. A backup was saved beside the original."
            } else {
                protectsOriginal = true
                loadFailureNotice = "Kalam couldn’t back up your dictionary. The original was kept, and changes are temporary in this session."
            }
            return []
        }
    }

    private func preserveCorruptFile(_ original: Data, at url: URL) -> Bool {
        let backup = url.appendingPathExtension("bak")
        let staged = url.deletingLastPathComponent().appendingPathComponent(".dictionary-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try original.write(to: staged, options: .withoutOverwriting)
            try replaceBackup(staged, backup)
            return true
        } catch {
            logger.warning("Custom dictionary backup failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            return false
        }
    }

    /// Both files are siblings. Rename atomically replaces the old backup
    /// after the new file is ready and preserves it if replacement fails.
    nonisolated private static func installBackup(_ staged: URL, _ backup: URL) throws {
        if rename(staged.path, backup.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Used by debounce, orderly termination, and relaunch before the next
    /// process can load the store. A clean dictionary requires no I/O.
    @discardableResult
    func flushPendingSave() -> Bool {
        debounceWork?.cancel()
        debounceWork = nil
        guard !protectsOriginal else { return false }
        guard hasPendingSave else { return true }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: appSupportURL, options: .atomic)
            hasPendingSave = false
            logger.info("Custom dictionary saved entries=\(self.entries.count, privacy: .public)")
            return true
        } catch {
            logger.warning("Custom dictionary save failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            return false
        }
    }

    private func stage(_ next: [DictionaryEntry]) {
        guard replaceEntries(with: next), !protectsOriginal else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingSave()
        }
        debounceWork = work
        scheduleSave(work)
    }

    @discardableResult
    private func replaceEntries(with next: [DictionaryEntry]) -> Bool {
        guard entries != next else { return false }
        compiled = compileEntries(next)
        hasPendingSave = true
        entries = next
        return true
    }
}
