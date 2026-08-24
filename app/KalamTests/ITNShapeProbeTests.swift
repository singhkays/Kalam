import XCTest
import KalamTextEngine
@testable import Kalam_test

// Observational canary for K-42/K-43 (2026-08-24): prints raw vs protected
// Nemo output for the digit/mixed/time shapes from the T12 live failures,
// and writes /tmp/k42-probe.txt. Always passes — read the report after runs;
// if a Nemo upgrade changes library behavior, this surfaces it.
// 2026-08-24 (K-45): added currency shapes and a full-pipeline row driven by
// TranscriptPostProcessor.process (the production clean -> ITN -> dictionary
// order) so live-run oddities like "$5.50 cents." reproduce at library level.
final class ITNShapeProbeTests: XCTestCase {
    private func raw(_ text: String) -> String {
        guard NemoTextProcessing.isAvailable else { return "<nemo unavailable>" }
        return NemoTextProcessing.normalizeSentence(text, maxSpanTokens: 16)
    }

    private func protectedPipeline(_ text: String) -> String {
        let protector = ITNSpanProtector()
        let masked = protector.protect(text)
        let normalized = NemoTextProcessing.normalizeSentence(masked.text, maxSpanTokens: 16)
        return protector.restore(normalized, spans: masked.spans)
    }

    private func fullPipeline(_ text: String) -> String {
        let processor = TranscriptPostProcessor(
            cleanupConfig: .defaults,
            dictionaryEntries: []
        )
        return processor.process(text).text
    }

    func testObservationalShapeProbe() {
        let shapes = [
            "five five five one two three four",
            "five, five, five, one, two, three, four",
            "Five. Five. Five. One. Two. Three. Four.",
            "call me at 5, 5, 5, 1, 2, 3, 4",
            "five 5 five 1 two three 4",
            "meeting at ten thirty",
            "five dollars and fifty cents",
            "fifty cents",
            "5 dollars and 50 cents",
            "5 dollars 50 cents",
            "five dollars 50 cents",
            "five dollars and 50 cents",
            "5 dollars and fifty cents",
            "Five dollars and fifty cents",
            "Five dollars and 50 cents",
            "Twenty one of us",
            "five dollars and fifty cents cents",
            "Five dollars and fifty cents.",
            "Five dollars and fifty cents!",
            "Five dollars and fifty cents?"
        ]
        var report = ""
        for shape in shapes {
            let line = "raw       | \(shape) => \(raw(shape))\nprotected | \(shape) => \(protectedPipeline(shape))\nfull      | \(shape) => \(fullPipeline(shape))\n---"
            print("PROBE \(line)")
            report += line + "\n"
        }
        try? report.write(toFile: "/tmp/k42-probe.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(true)
    }
}
