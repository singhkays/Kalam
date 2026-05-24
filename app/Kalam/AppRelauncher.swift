import Foundation
import OSLog

enum AppRelauncher {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AppRelauncher")

    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
        } catch {
            logger.warning("Failed to relaunch app automatically errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }

        exit(0)
    }
}
