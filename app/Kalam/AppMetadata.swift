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
