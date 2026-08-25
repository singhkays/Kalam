import AppKit
import Foundation
import OSLog

/// Relaunches the app as a fresh process.
///
/// relaunch lifecycle rework: replaces the old `open -n` (via a `/usr/bin/open` `Process`) +
/// unconditional `exit(0)`. The old code quit even when the new instance
/// failed to launch (leaving the user with no app at all), and `exit(0)`
/// skipped the orderly termination lifecycle (`applicationWillTerminate`:
/// transcription-task cancellation, observer removal).
///
/// The live strategy launches a second instance via
/// `NSWorkspace.openApplication` (the sandbox-sanctioned API — no Process
/// hop) and terminates via `NSApp.terminate` ONLY after the launch succeeded;
/// a failed launch is logged and the app stays alive so the user can retry.
enum AppRelauncher {

    /// Injectable seam (same pattern as `PasteService.PasteStrategies`, clipboard restore on failed paste)
    /// so the orchestration is unit-testable without spawning processes.
    struct Strategy: Sendable {
        /// Launch a second instance of the app at `url`. Must call
        /// `completion` exactly once; `nil` means the launch was accepted.
        var launchNewInstance: @Sendable (URL, @escaping @Sendable (NSError?) -> Void) -> Void
        /// Orderly termination of the current instance.
        var terminate: @Sendable () -> Void
    }

    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AppRelauncher")

    /// Real implementation. `createsNewApplicationInstance = true` mirrors the
    /// old `open -n` semantics — and is REQUIRED here: without it, LaunchServices
    /// re-activates the still-running current instance and the relaunch
    /// degenerates into a plain quit. Do not remove.
    static let live = Strategy(
        launchNewInstance: { url, completion in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                completion(error as NSError?)
            }
        },
        terminate: {
            NSApp.terminate(nil)
        }
    )

    static func relaunch(strategy: Strategy = AppRelauncher.live) {
        let bundleURL = Bundle.main.bundleURL
        strategy.launchNewInstance(bundleURL) { error in
            if let error {
                logger.error("Failed to relaunch app automatically: \(error.localizedDescription, privacy: .public)")
                return
            }
            // NSWorkspace does not document the completion thread; hop to
            // main before touching NSApp.
            DispatchQueue.main.async {
                strategy.terminate()
            }
        }
    }
}
