import Foundation

enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
        } catch {
            print("Failed to relaunch app automatically: \(error.localizedDescription)")
        }

        exit(0)
    }
}
