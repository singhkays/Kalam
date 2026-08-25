import Testing
import Foundation
@testable import KalamTextEngine

@Test func smartCaseMimicry() {
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "orange",
        caseInsensitive: true,
        preserveCase: true
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    let tests = [
        ("i want an apple", "i want an orange"),
        ("I want an Apple", "I want an Orange"),
        ("I WANT AN APPLE", "I WANT AN ORANGE")
    ]

    for (input, expected) in tests {
        let (out, _) = engine.apply(to: input)
        #expect(out == expected)
    }
}

@Test func literalMatch() {
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "ORANGE",
        caseInsensitive: false,
        preserveCase: false
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    let (out1, _) = engine.apply(to: "i want an apple")
    #expect(out1 == "i want an ORANGE")

    let (out2, _) = engine.apply(to: "I want an Apple")
    #expect(out2 == "I want an Apple")
}

@Test func morphologicalSuffixes() {
    // Suffix matching is unconditional: plurals and possessives always map.
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "orange"
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "apples").0 == "oranges")
    #expect(engine.apply(to: "apple's").0 == "orange's")
}

@Test func phraseReplacement() {
    let entry = DictionaryEntry(
        trigger: "my addr",
        replacement: "123 Main St",
        caseInsensitive: true,
        preserveCase: true
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "send to my addr").0 == "send to 123 Main St")
    #expect(engine.apply(to: "My Addr is here").0 == "123 Main St is here")
}

@Test func wholeWordEnforcement() {
    // Whole-word matching is unconditional: "car" must never match inside "carpet".
    let entry = DictionaryEntry(
        trigger: "car",
        replacement: "truck"
    )

    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "the car is here").0 == "the truck is here")
    #expect(engine.apply(to: "the carpet is here").0 == "the carpet is here")
}

@Test func mixedCasePreservation() {
    let entry = DictionaryEntry(
        trigger: "ipad",
        replacement: "iPad",
        caseInsensitive: true,
        preserveCase: true
    )
    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "my ipad").0 == "my iPad")
    #expect(engine.apply(to: "My Ipad").0 == "My iPad")
    #expect(engine.apply(to: "MY IPAD").0 == "MY IPAD")
}

@Test func titleCaseMimicry() {
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "Orange",
        caseInsensitive: true,
        preserveCase: true
    )
    let engine = ReplacementCompiler.compile(entries: [entry])

    #expect(engine.apply(to: "my apple").0 == "my orange")
    #expect(engine.apply(to: "My Apple").0 == "My Orange")
}

@Test func liveExampleSuffixes() {
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "orange"
    )

    let examples = entry.exampleMatches
    #expect(examples.contains("apple → orange"))
    #expect(examples.contains("apples → oranges"))
    #expect(examples.contains("apple's → orange's"))
    #expect(examples.contains("Apple → Orange"))
}

@Test func legacyDictionaryJSONWithDeadFlagsStillDecodes() throws {
    // Pre-dead dictionary flags removal user_dictionary.json files contain wholeWord/morphological keys.
    // Synthesized Codable ignores unknown keys; old files must keep decoding.
    let legacy = """
    [{"id": "11111111-1111-1111-1111-111111111111", "trigger": "car", "replacement": "truck", "isEnabled": true, "wholeWord": false, "morphological": false, "caseInsensitive": true, "preserveCase": true, "userAdded": true}]
    """
    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(legacy.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].trigger == "car")
    #expect(entries[0].caseInsensitive)
}

@Test func dictionaryEntryIsSendable() {
    // off-main post-processing: TranscriptPostProcessor stores [DictionaryEntry] behind a
    // Sendable struct; pin the conformance so it can't regress silently.
    func assertSendable<T: Sendable>(_ value: T) {}
    assertSendable(DictionaryEntry(trigger: "x", replacement: "y"))
}
