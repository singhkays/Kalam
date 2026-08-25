import Foundation
import AppKit

enum KalamExternalLinks {
    static let latestReleaseURL = URL(string: "https://github.com/singhkays/Kalam/releases/latest")!

    @MainActor
    @discardableResult
    static func openLatestRelease() -> Bool {
        NSWorkspace.shared.open(latestReleaseURL)
    }
}

enum KalamAppVersion {
    static var displayString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty {
            return version
        }
        return "Unknown"
    }
}

/// The user-facing app name for the *running build*. Debug builds ship as
/// "Kalam-test" (`singhkays.Kalam-test`, PRODUCT_NAME `$(TARGET_NAME)-test`);
/// Release is plain "Kalam". Copy that names the app (permission instructions,
/// drag tiles) must match what the user sees in System Settings and the Dock —
/// otherwise a -Test build tells the user to look for "Kalam" while the list
/// shows "Kalam-test".
enum KalamAppName {
    static var current: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let name, !name.isEmpty {
            return name
        }
        // Fallback mirrors the PRODUCT_NAME scheme when CFBundleName is absent.
        #if DEBUG
        return "Kalam-test"
        #else
        return "Kalam"
        #endif
    }

    /// True when this is the -Test (development) flavor of the app.
    static var isTestBuild: Bool {
        current.lowercased().hasSuffix("-test")
    }
}
