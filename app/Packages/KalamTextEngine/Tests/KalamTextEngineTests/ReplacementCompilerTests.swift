import Testing
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
    let entry = DictionaryEntry(
        trigger: "apple",
        replacement: "orange",
        morphological: false
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
    let entry = DictionaryEntry(
        trigger: "car",
        replacement: "truck",
        wholeWord: false
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
