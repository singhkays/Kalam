import ApplicationServices
import Foundation
import OSLog

// MARK: - Accessibility helper

enum AccessibilityHelper {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AccessibilityHelper")

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }
    
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            explainAccessibilityIfNeeded()
        } else {
            logger.info("Accessibility trusted")
        }
        return trusted
    }
    
    static func explainAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        logger.warning("Accessibility not enabled for this app")
    }
}
