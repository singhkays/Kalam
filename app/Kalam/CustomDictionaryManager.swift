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

    @Published var entries: [DictionaryEntry] = []

    /// Set when `user_dictionary.json` exists but fails to decode; the corrupt
    /// file is preserved as `user_dictionary.json.bak` before the store resets.
    @Published var loadFailureNotice: String?

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "CustomDictionary")
    private let storeURLOverride: URL?
    private let fileName = "user_dictionary.json"

    init(storeURL: URL? = nil) {
        self.storeURLOverride = storeURL
    }

    private var appSupportURL: URL {
        if let storeURLOverride { return storeURLOverride }
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
        // An explicit import is a user action: imported entries are user-owned,
        // so they must survive the `userAdded` filter on the next launch.
        entries = decoded.map { entry in
            var owned = entry
            owned.userAdded = true
            return owned
        }
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
            loadFailureNotice = nil
            logger.info("Custom dictionary file missing; starting empty")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            entries = decoded.filter { $0.userAdded }
            loadFailureNotice = nil
            logger.info("Custom dictionary loaded entries=\(decoded.count), userEntries=\(self.entries.count)")
        } catch {
            logger.warning("Custom dictionary load failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            preserveCorruptFile(at: url)
            entries = []
            loadFailureNotice = "Kalam couldn't read your saved dictionary. A backup was kept next to the original file."
        }
    }

    private func preserveCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension().appendingPathExtension("json.bak")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: url, to: backupURL)
            logger.info("Custom dictionary corrupt file preserved as \(backupURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Custom dictionary backup failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
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
