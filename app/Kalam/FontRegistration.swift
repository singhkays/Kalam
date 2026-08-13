import AppKit
import CoreText
import os

/// Registers the bundled OFL web fonts — the Compass settings window typography (K-31):
/// Instrument Serif, Plus Jakarta Sans (variable), IBM Plex Mono.
///
/// The app has NO network entitlement (AGENTS.md invariant): the fonts ship inside the
/// app bundle and are registered process-scope at launch. Logs carry counts only —
/// never font names or paths (SECURITY.md).
enum FontRegistration {
    struct Result: Equatable {
        var registered: Int = 0
        var alreadyRegistered: Int = 0
        var failed: Int = 0
    }

    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "Fonts")

    /// Registers every bundled `.ttf`. Safe to call repeatedly: fonts already registered
    /// in this process are counted separately, not as failures. Call once at launch.
    @discardableResult
    static func registerBundledFonts() -> Result {
        var result = Result()
        for url in bundledFontURLs() {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                result.registered += 1
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                result.alreadyRegistered += 1
            } else {
                result.failed += 1
            }
        }
        logger.info("Fonts: \(result.registered, privacy: .public) registered, \(result.alreadyRegistered, privacy: .public) already registered, \(result.failed, privacy: .public) failed")
        return result
    }

    /// Recursive scan of the bundle resources root — robust to Xcode's resource layout
    /// (synchronized groups currently flatten the Fonts folder into Resources/).
    private static func bundledFontURLs() -> [URL] {
        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "ttf" }
    }
}
