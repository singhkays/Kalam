import KalamTextEngine
import XCTest
@testable import Kalam_test

@MainActor
final class CustomDictionaryManagerTests: XCTestCase {
    
    func testSmartCaseMimicry() {
        let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "orange",
            caseInsensitive: true,
            preserveCase: true
        )
        
        // Use ReplacementCompiler directly for testing since we don't want to mess with the shared manager's persistence
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        let tests = [
            ("i want an apple", "i want an orange"),
            ("I want an Apple", "I want an Orange"),
            ("I WANT AN APPLE", "I WANT AN ORANGE")
        ]
        
        for (input, expected) in tests {
            let (out, _) = engine.apply(to: input)
            XCTAssertEqual(out, expected)
        }
    }
    
    func testLiteralMatch() {
        let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "ORANGE",
            caseInsensitive: false,
            preserveCase: false
        )
        
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        let (out1, _) = engine.apply(to: "i want an apple")
        XCTAssertEqual(out1, "i want an ORANGE")
        
        let (out2, _) = engine.apply(to: "I want an Apple")
        XCTAssertEqual(out2, "I want an Apple") // No match due to case sensitivity
    }
    
    func testMorphologicalSuffixes() {
        // Suffix matching is unconditional: plurals and possessives always map.
        let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "orange"
        )
        
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        XCTAssertEqual(engine.apply(to: "apples").0, "oranges")
        XCTAssertEqual(engine.apply(to: "apple's").0, "orange's")
    }
    
    func testPhraseReplacement() {
        let entry = DictionaryEntry(
            trigger: "my addr",
            replacement: "123 Main St",
            caseInsensitive: true,
            preserveCase: true
        )
        
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        XCTAssertEqual(engine.apply(to: "send to my addr").0, "send to 123 Main St")
        XCTAssertEqual(engine.apply(to: "My Addr is here").0, "123 Main St is here")
    }
    
    func testWholeWordEnforcement() {
        // Whole-word matching is unconditional (never matches inside "carpet").
        let entry = DictionaryEntry(
            trigger: "car",
            replacement: "truck"
        )
        
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        XCTAssertEqual(engine.apply(to: "the car is here").0, "the truck is here")
        XCTAssertEqual(engine.apply(to: "the carpet is here").0, "the carpet is here") // Should NOT match "car" in "carpet"
    }
    
    func testMixedCasePreservation() {
        let entry = DictionaryEntry(
            trigger: "ipad",
            replacement: "iPad",
            caseInsensitive: true,
            preserveCase: true
        )
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        XCTAssertEqual(engine.apply(to: "my ipad").0, "my iPad")
        XCTAssertEqual(engine.apply(to: "My Ipad").0, "My iPad") // Should PRESERVE iPad even matching Title Case
        XCTAssertEqual(engine.apply(to: "MY IPAD").0, "MY IPAD") // Should still upcase for shouting
    }
    
    func testTitleCaseMimicry() {
         let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "Orange", // User typed Title Case replacement
            caseInsensitive: true,
            preserveCase: true
        )
        let engine = ReplacementCompiler.compile(entries: [entry])
        
        XCTAssertEqual(engine.apply(to: "my apple").0, "my orange") // Should lowercase because source is lower
        XCTAssertEqual(engine.apply(to: "My Apple").0, "My Orange") // Should titlecase
    }
    
    func testLiveExampleSuffixes() {
        let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "orange"
        )
        
        let examples = entry.exampleMatches
        // Should contain apple -> orange, Apple -> Orange, APPLE -> ORANGE, apples -> oranges, apple's -> orange's
        XCTAssertTrue(examples.contains("apple → orange"))
        XCTAssertTrue(examples.contains("apples → oranges"))
        XCTAssertTrue(examples.contains("apple's → orange's"))
        XCTAssertTrue(examples.contains("Apple → Orange"))
    }

    // MARK: - dictionary data-loss edge cases persistence edges

    private func makeIsolatedManager() throws -> (CustomDictionaryManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamDictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("user_dictionary.json")
        return (CustomDictionaryManager(storeURL: store), store)
    }

    func testImportedEntriesSurviveRelaunch() throws {
        let (manager, store) = try makeIsolatedManager()
        let importURL = store.deletingLastPathComponent().appendingPathComponent("import.json")
        let imported = DictionaryEntry(trigger: "kalam", replacement: "Kalam",
                                       caseInsensitive: true, preserveCase: false, userAdded: false)
        try JSONEncoder().encode([imported]).write(to: importURL)

        try manager.importJSON(from: importURL)
        XCTAssertEqual(manager.entries.count, 1)

        // Simulate relaunch: a fresh manager over the same store file.
        let relaunched = CustomDictionaryManager(storeURL: store)
        relaunched.bootstrap()
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertEqual(relaunched.entries.first?.trigger, "kalam")
        XCTAssertTrue(relaunched.entries.first?.userAdded == true)
    }

    func testCorruptStoreIsBackedUpAndNoticeSet() throws {
        let (manager, store) = try makeIsolatedManager()
        try Data("not json {{{".utf8).write(to: store)

        manager.bootstrap()

        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertNotNil(manager.loadFailureNotice)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.deletingPathExtension().appendingPathExtension("json.bak").path))
    }

    func testHealthyStoreHasNoBackupOrNotice() throws {
        let (manager, store) = try makeIsolatedManager()
        let entry = DictionaryEntry(trigger: "apple", replacement: "orange")
        try JSONEncoder().encode([entry]).write(to: store)

        manager.bootstrap()

        XCTAssertNil(manager.loadFailureNotice)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.deletingPathExtension().appendingPathExtension("json.bak").path))
    }

    func testCurrentCompiledEngineReflectsLatestMutation() throws {
        let (manager, _) = try makeIsolatedManager()
        manager.bootstrap()
        manager.addEntry(DictionaryEntry(trigger: "open ai", replacement: "OpenAI"))
        let engine = manager.currentCompiledEngine
        let (out, count) = engine.apply(to: "i use open ai daily")
        XCTAssertEqual(out, "i use OpenAI daily")
        XCTAssertEqual(count, 1)
    }

    func testOrderlyFlushWritesPendingChangesWithoutRecompiling() throws {
        let (_, store) = try makeIsolatedManager()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        var scheduled: [DispatchWorkItem] = []
        var compiles = 0
        let manager = CustomDictionaryManager(storeURL: store, scheduleSave: { scheduled.append($0) }, compileEntries: {
            compiles += 1
            return ReplacementCompiler.compile(entries: $0)
        })
        manager.bootstrap()
        let rule = DictionaryEntry(trigger: "cat", replacement: "lynx")
        manager.addEntry(rule)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(manager.flushPendingSave())
        XCTAssertTrue(scheduled[0].isCancelled)
        XCTAssertEqual(try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: store)), [rule])
        XCTAssertEqual(compiles, 2, "bootstrap and edit, with no compilation at persistence time")
    }

    func testOrderlyFlushLeavesCleanStoreUntouched() throws {
        let (_, store) = try makeIsolatedManager()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let clean = Data("[\n]\n".utf8)
        try clean.write(to: store)
        let manager = CustomDictionaryManager(storeURL: store, scheduleSave: { _ in XCTFail("Unexpected save scheduled") })
        manager.bootstrap()
        XCTAssertTrue(manager.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: store), clean)
    }

    func testBackupReplacementUsesPreparedFileAndProtectsOriginalOnFailure() throws {
        let (_, store) = try makeIsolatedManager()
        let directory = store.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = store.appendingPathExtension("bak")
        let corrupt = Data("unreadable current dictionary".utf8)
        let prior = Data("prior backup".utf8)
        try corrupt.write(to: store)
        try prior.write(to: backup)
        var attempted = 0
        let manager = CustomDictionaryManager(
            storeURL: store,
            scheduleSave: { _ in XCTFail("Protected stores must not schedule writes") },
            replaceBackup: { staged, destination in
                attempted += 1
                XCTAssertEqual(staged.deletingLastPathComponent(), directory)
                XCTAssertEqual(destination, backup)
                XCTAssertEqual(try Data(contentsOf: staged), corrupt)
                XCTAssertEqual(try Data(contentsOf: backup), prior)
                throw CocoaError(.fileWriteNoPermission)
            }
        )

        manager.bootstrap()
        XCTAssertEqual(attempted, 1)
        XCTAssertTrue(manager.loadFailureNotice?.contains("couldn’t back up") == true)
        manager.addEntry(DictionaryEntry(trigger: "uh", replacement: "ah"))
        XCTAssertFalse(manager.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: store), corrupt)
        XCTAssertEqual(try Data(contentsOf: backup), prior)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), [store.lastPathComponent, backup.lastPathComponent])
    }

    func testSuccessfulRecoveryReplacesPriorBackup() throws {
        let (manager, store) = try makeIsolatedManager()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let backup = store.appendingPathExtension("bak")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: store)
        try Data("prior backup".utf8).write(to: backup)
        manager.bootstrap()
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertTrue(manager.loadFailureNotice?.contains("A backup was saved") == true)
        manager.addEntry(DictionaryEntry(trigger: "cat", replacement: "lynx"))
        XCTAssertTrue(manager.flushPendingSave())
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: store)).count, 1)
    }

}
