import Foundation
import FluidAudio

/// A unified runner to exercise the Kalam engine pipeline in a "special mode" for testing.
/// This allows feeding text or audio through the system and inspecting intermediate results.
struct KalamTestRunner {
    
    struct EngineResult {
        let input: String
        let afterCleanup: String
        let afterITN: String
        let final: String
        
        func printSummary() {
            print("\n--- Kalam Engine Test Summary ---")
            print("[Stage: Input]     \(input)")
            print("[Stage: Cleanup]   \(afterCleanup)")
            print("[Stage: ITN]       \(afterITN)")
            print("[Stage: Final]     \(final)")
            print("---------------------------------\n")
        }
    }
    
    static let shared = KalamTestRunner()
    
    /// Run the full pipeline starting from processed text (simulating ASR output)
    func runTextPipeline(_ text: String, configuration: TextCleanupConfiguration? = nil) -> EngineResult {
        let config = configuration ?? ModelsConfiguration.load().textCleanup
        
        // 1. Cleanup
        let cleanupResult = TextCleanupService.shared.clean(text, configuration: config)
        let cleanedText = cleanupResult.text
        
        // 2. ITN (Inverse Text Normalization)
        let itnResult = applyITN(to: cleanedText)
        let itnText = itnResult.text
        
        // 3. Custom Dictionary
        let (finalText, _) = CustomDictionaryManager.shared.apply(to: itnText)
        
        return EngineResult(
            input: text,
            afterCleanup: cleanedText,
            afterITN: itnText,
            final: finalText
        )
    }
    
    /// Run the full pipeline starting from raw audio samples
    func runAudioPipeline(samples: [Float], asrService: ASRService) async throws -> EngineResult {
        // 1. ASR
        let transcribedText = try await asrService.transcribe(samples: samples)
        
        // 2. Process via text pipeline
        return runTextPipeline(transcribedText)
    }
    
    private func applyITN(to text: String) -> (text: String, changed: Bool) {
        let defaults = UserDefaults.standard
        let itnEnabled = defaults.bool(forKey: "internal.itn.enabled") 
        let itnSpan = defaults.integer(forKey: "internal.itn.maxSpanTokens")
        
        guard itnEnabled, NemoTextProcessing.isAvailable else {
            return (text, false)
        }
        
        let span = itnSpan > 0 ? UInt32(itnSpan) : 16
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return NemoTextProcessing.normalizeSentence(line, maxSpanTokens: span)
        }
        let normalized = normalizedLines.joined(separator: "\n")
        return (normalized, normalized != text)
    }
}
