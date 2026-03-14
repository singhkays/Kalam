import XCTest
@testable import Kalam_test

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
        // Even if morphological is false, the engine should now enforce it
        let entry = DictionaryEntry(
            trigger: "apple",
            replacement: "orange",
            morphological: false 
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
        // Even if wholeWord is false, the engine should now enforce it
        let entry = DictionaryEntry(
            trigger: "car",
            replacement: "truck",
            wholeWord: false
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
}
