import ApplicationServices

// MARK: - Accessibility helper

enum AccessibilityHelper {
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
            print("Accessibility: trusted = true")
        }
        return trusted
    }
    
    static func explainAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        print("""
        Accessibility not enabled for this app.
        Enable it in:
        System Settings → Privacy & Security → Accessibility → enable for Kalam.
        If you just enabled it, quit and re-launch the app.
        """)
    }
}
