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
}
