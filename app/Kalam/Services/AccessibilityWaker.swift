import ApplicationServices
import Foundation
import OSLog

/// Session-start AX wake prefetch — invoked while the user is still speaking
/// (KalamApp startRecording region), not after transcript lands. Warms the AX
/// connection for the target app so the later Tier-1 SET has a hot path.
///
/// Mirrors Jot's prefetch; intentionally lightweight: one bounded AX attribute
/// read on the target app's element. No transcript or audio content is ever
/// accessed.
enum AccessibilityWaker {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AccessibilityWaker")
    private static let wakeTimeoutSeconds: Float = 0.75

    /// Prefetch AX connection for the given bundleID/pid. Best-effort, no throw,
    /// no log of content. Called off the critical paste path.
    @discardableResult
    static func wakeIfNeeded(bundleID: String?, pid: pid_t?) -> Bool {
        guard let pid else {
            logger.debug("AccessibilityWaker: no pid, skip")
            return false
        }
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, wakeTimeoutSeconds)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        if result == .success {
            logger.debug("AccessibilityWaker: warmed pid=\(pid, privacy: .public) bundleID=\(bundleID ?? "nil", privacy: .public) result=success")
            return true
        } else {
            logger.debug("AccessibilityWaker: warm attempt pid=\(pid, privacy: .public) result=\(result.rawValue, privacy: .public)")
            return false
        }
    }

    /// Test seam: injectable version for headless tests.
    static func wakeIfNeeded(bundleID: String?, pid: pid_t?, using fetcher: (pid_t) -> AXError) -> Bool {
        guard let pid else { return false }
        return fetcher(pid) == .success
    }
}
