import AppKit
import Foundation

/// Bundle-ID registry for apps where Tier-1 AX insertion is known-broken and must
/// be skipped in favor of the pasteboard/Cmd+V route.
///
/// Governance: entries are added ONLY from reproduced issues, each citing its
/// bug ID in the comment. Seeded EMPTY per plan Task 5. See
/// `app/docs/dev-design/2026-08-26-k52-k58-jot-adoption-plan.md` Task 5.
///
/// Example future entry (do not add without reproduction):
///   // #12345 — Electron 22: AXSetAttributeValue returns success but value unchanged; verified on 2026-08-27
///   "com.example.brokenApp": true
enum AppQuirks {
    /// Set of bundle IDs that must bypass Tier-1 and use force-paste (Cmd+V) directly.
    /// Empty at ship; populated only from reproduced bugs with citations.
    static let forcePasteBundleIDs: Set<String> = [
        // Intentionally empty — see governance note above.
    ]

    /// Whether the given bundleID should skip Tier-1 AX insertion.
    static func shouldForcePaste(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return forcePasteBundleIDs.contains(bundleID)
    }

    /// Convenience for a PID: resolves bundleID via NSRunningApplication and checks the table.
    /// Returns false if PID unknown or bundleID not in table.
    static func shouldForcePaste(pid: pid_t?) -> Bool {
        guard let pid else { return false }
        let app = NSRunningApplication(processIdentifier: pid)
        return shouldForcePaste(bundleID: app?.bundleIdentifier)
    }
}
