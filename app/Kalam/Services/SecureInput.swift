import ApplicationServices
import Foundation
import IOKit
import OSLog

@_silgen_name("IsSecureEventInputEnabled") func IsSecureEventInputEnabled() -> Bool

/// Secure-input probe — mirrors Jot's SecureInput with IORegistry fallback.
///
/// - `isSecureEventInputEnabled` is the global flag (CGEvent).
/// - `secureInputOwnerPID` probes `IORegistry` `IOConsoleUsers` for the PID that
///   currently holds secure input, degrading gracefully if the registry is
///   unavailable. Never logs transcript or audio content.
enum SecureInput {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "SecureInput")

    /// Whether the system is in secure-input mode (password field, etc.).
    /// Zero call sites in Kalam until Task 5 — this is the first.
    static func isSecureEventInputEnabled() -> Bool {
        // ApplicationServices/CGEvent.h
        IsSecureEventInputEnabled()
    }

    /// Best-effort PID that currently owns secure input via IORegistry.
    /// Returns nil if the registry entry or property is unavailable (graceful
    /// degradation — caller falls back to `isSecureEventInputEnabled()`).
    static func secureInputOwnerPID() -> pid_t? {
        // Mirrors Jot's IORegistry IOConsoleUsers probe.
        // Path: IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOConsoleUsers")
        // Property: "IOConsoleUsers" is an array of dictionaries, each with
        // "kCGSSecureInputPID" or similar. We probe defensively and never crash.
        let mainPort: mach_port_t = kIOMainPortDefault
        let entry = IORegistryEntryFromPath(mainPort, "IOService:/IOResources/IOConsoleUsers")
        guard entry != MACH_PORT_NULL else {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("SecureInput probe: IOConsoleUsers entry not found") }
            return nil
        }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("SecureInput probe: failed to read properties") }
            return nil
        }

        // IOConsoleUsers is typically an array under key "IOConsoleUsers"
        // Each user dict may contain "kCGSSessionSecureInputPID" (int).
        // We scan for any secure PID; exact key name varies by OS — probe
        // both known variants.
        if let users = dict["IOConsoleUsers"] as? [[String: Any]] {
            for user in users {
                // Jot's key is often "kCGSSecureInputPID" or "SecureInputPID"
                if let pid = user["kCGSSecureInputPID"] as? pid_t, pid != 0 {
                    return pid
                }
                if let pidNum = user["kCGSSecureInputPID"] as? Int, pidNum != 0 {
                    return pid_t(pidNum)
                }
                if let pid = user["SecureInputPID"] as? pid_t, pid != 0 {
                    return pid
                }
                if let pidNum = user["SecureInputPID"] as? Int, pidNum != 0 {
                    return pid_t(pidNum)
                }
                // Some OS versions store it under "kCGSSessionSecureInputPID"
                if let pid = user["kCGSSessionSecureInputPID"] as? pid_t, pid != 0 {
                    return pid
                }
                if let pidNum = user["kCGSSessionSecureInputPID"] as? Int, pidNum != 0 {
                    return pid_t(pidNum)
                }
            }
        }

        // Fallback: check top-level keys directly (some configs flatten it)
        for key in ["kCGSSecureInputPID", "SecureInputPID", "kCGSSessionSecureInputPID"] {
            if let pid = dict[key] as? pid_t, pid != 0 { return pid }
            if let pidNum = dict[key] as? Int, pidNum != 0 { return pid_t(pidNum) }
        }

        if KalamDiagnosticFlags.verboseAudio { logger.debug("SecureInput probe: no secure PID found in IOConsoleUsers") }
        return nil
    }

    /// Whether secure input is active for the given PID (or globally if PID probe unavailable).
    /// If the IORegistry probe returns a PID, we compare it to the target; otherwise we
    /// fall back to the global `IsSecureEventInputEnabled()` flag.
    static func isSecureInputActive(for pid: pid_t?) -> Bool {
        if let securePID = secureInputOwnerPID() {
            // If we know the owner, only that PID is considered secure.
            if let pid, pid == securePID { return true }
            // Global flag still matters: some secure fields don't register via IORegistry
            return isSecureEventInputEnabled()
        }
        return isSecureEventInputEnabled()
    }
}
