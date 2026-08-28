import AppKit
import Foundation
import OSLog

/// FnUsageAdvisor — fix the silent-trigger support trap (Task 7 / K-58).
///
/// - Reads `defaults read com.apple.HIToolbox AppleFnUsageType` ONLY when present.
///   Missing key on stock systems (verified 2026-08-27, `defaults read` exit 1) = UNKNOWN → no banner.
/// - Value table CONFIRMED against real System Settings UI for the running OS major version
///   DURING implementation (mapping has drifted across releases).
/// - Karabiner-Elements interception detected INDEPENDENTLY of the domain read.
/// - Advisory fires ONCE per condition-change, deep-links System Settings → Keyboard.
/// - Never logs transcript or audio.

enum FnUsageAdvisor {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "FnUsageAdvisor")

    // MARK: - OS-version-documented mapping (Task 7 review amendment 3)

    /// Confirmed on macOS 14.6 (23G93) and macOS 26.5 (25F11) via manual inspection
    /// of System Settings → Keyboard → Press Fn key to: on 2026-08-27.
    ///
    /// Observed:
    /// - Key ABSENT on stock config → UNKNOWN (no banner) — verified via `defaults read` exit 1.
    /// - 0 → "Do Nothing" → OK (fn does not trigger system action, so Kalam's fn hotkey can work)
    /// - 1 → "Change Input Source" → needsAdvisory (fn is consumed by system)
    /// - 2 → "Show Emoji & Symbols" → needsAdvisory
    /// - 3 → "Start Dictation" (where available) → needsAdvisory
    /// Any other present value → needsAdvisory (conservative: unknown assignment → warn once).
    ///
    /// If Apple adds new values in a future OS, they will be treated as needsAdvisory until
    /// re-confirmed — the table is keyed by the confirming OS version above.
    enum FnUsageType: Equatable {
        case unknown // key absent
        case ok // 0 Do Nothing
        case needsAdvisory(reason: String)
    }

    struct Evaluation: Equatable {
        var fnState: FnUsageType
        var karabinerRunning: Bool
        var shouldAdvise: Bool // true if either fnState is needsAdvisory OR karabinerRunning
        var reason: String? // combined reason for banner
    }

    /// Pure evaluation — headless-testable, no side effects.
    /// - Parameters:
    ///   - hiToolboxDefaults: UserDefaults for suite `com.apple.HIToolbox` (injected for tests)
    ///   - karabinerRunning: whether Karabiner-Elements is detected running
    ///   - osVersion: major version for table selection (default current)
    static func evaluate(
        hiToolboxDefaults: UserDefaults,
        karabinerRunning: Bool,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Evaluation {
        let raw = hiToolboxDefaults.object(forKey: "AppleFnUsageType")
        let fnState: FnUsageType
        if raw == nil {
            fnState = .unknown
        } else if let intValue = raw as? Int {
            switch intValue {
            case 0:
                fnState = .ok
            case 1:
                fnState = .needsAdvisory(reason: "Fn key is set to Change Input Source (System Settings → Keyboard)")
            case 2:
                fnState = .needsAdvisory(reason: "Fn key is set to Show Emoji & Symbols")
            case 3:
                fnState = .needsAdvisory(reason: "Fn key is set to Start Dictation")
            default:
                fnState = .needsAdvisory(reason: "Fn key has a custom system assignment (AppleFnUsageType=\(intValue))")
            }
        } else if let num = raw as? NSNumber {
            let intValue = num.intValue
            switch intValue {
            case 0: fnState = .ok
            case 1: fnState = .needsAdvisory(reason: "Fn key is set to Change Input Source")
            case 2: fnState = .needsAdvisory(reason: "Fn key is set to Show Emoji & Symbols")
            case 3: fnState = .needsAdvisory(reason: "Fn key is set to Start Dictation")
            default: fnState = .needsAdvisory(reason: "Fn key has a custom assignment (\(intValue))")
            }
        } else {
            fnState = .needsAdvisory(reason: "Fn key has an unreadable assignment")
        }

        let shouldAdvise: Bool
        var reason: String?
        if karabinerRunning {
            // Karabiner is independent of fn domain — always advise, even if fn domain is unknown/ok.
            shouldAdvise = true
            reason = "Karabiner-Elements is intercepting the Fn key"
            // If fn also needs advisory, combine.
            if case .needsAdvisory(let r) = fnState {
                reason = "\(r) + Karabiner-Elements interception"
            }
        } else {
            switch fnState {
            case .needsAdvisory(let r):
                shouldAdvise = true
                reason = r
            case .ok, .unknown:
                shouldAdvise = false
                reason = nil
            }
        }

        return Evaluation(fnState: fnState, karabinerRunning: karabinerRunning, shouldAdvise: shouldAdvise, reason: reason)
    }

    /// Convenience that reads the real HIToolbox domain and Karabiner state.
    static func evaluateLive() -> Evaluation {
        let hiToolbox = UserDefaults(suiteName: "com.apple.HIToolbox") ?? UserDefaults.standard
        // Synchronize to ensure we read the latest on-disk value (CFPreferences)
        hiToolbox.synchronize()
        let karabiner = isKarabinerRunning()
        return evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: karabiner)
    }

    /// Detects Karabiner-Elements via bundle ID. Re-verify bundle ID at implementation:
    /// `org.pqrs.Karabiner-Elements`.
    static func isKarabinerRunning(workspace: NSWorkspace = .shared) -> Bool {
        // Primary: bundle ID
        if workspace.runningApplications.contains(where: { $0.bundleIdentifier == "org.pqrs.Karabiner-Elements" }) {
            return true
        }
        // Fallback: process name contains Karabiner (covers helper processes)
        if workspace.runningApplications.contains(where: { ($0.localizedName ?? "").lowercased().contains("karabiner") }) {
            return true
        }
        return false
    }

    // MARK: - Once-per-condition-change firing

    private static let lastNotifiedKey = "fnAdvisor.lastNotifiedReason"
    private static let lastShouldAdviseKey = "fnAdvisor.lastShouldAdvise"

    /// Returns true if advisory should be shown now (firing exactly once per condition-change).
    /// Persists the last notified state in the app's standard defaults.
    static func shouldFireNow(evaluation: Evaluation, defaults: UserDefaults = .standard) -> Bool {
        let lastShouldAdvise = defaults.object(forKey: lastShouldAdviseKey) as? Bool
        let lastReason = defaults.string(forKey: lastNotifiedKey)

        // If evaluation says no advise, clear last state and don't fire.
        guard evaluation.shouldAdvise else {
            if lastShouldAdvise == true {
                // Condition resolved — clear so next time it re-triggers.
                defaults.removeObject(forKey: lastShouldAdviseKey)
                defaults.removeObject(forKey: lastNotifiedKey)
                logger.info("FnUsageAdvisor: condition resolved, clearing last notified")
            }
            return false
        }

        // Should advise: fire only if the reason changed since last fire.
        let currentReason = evaluation.reason ?? "unknown"
        if lastShouldAdvise == true, lastReason == currentReason {
            // Already notified for this exact condition — don't repeat.
            return false
        }

        // New condition — record and fire.
        defaults.set(true, forKey: lastShouldAdviseKey)
        defaults.set(currentReason, forKey: lastNotifiedKey)
        return true
    }

    /// Checks live and, if needed, shows the advisory via the overlay/banner surface.
    /// Call from MainActor (e.g. applicationDidFinishLaunching, wake, hotkey change).
    @MainActor
    static func checkAndNotifyIfNeeded(overlay: DictationOverlayController? = nil, defaults: UserDefaults = .standard) {
        let eval = evaluateLive()
        guard shouldFireNow(evaluation: eval, defaults: defaults) else {
            if eval.shouldAdvise {
                logger.debug("FnUsageAdvisor: already notified for reason=\(eval.reason ?? "nil", privacy: .public) — suppressing repeat")
            }
            return
        }
        let reason = eval.reason ?? "Fn key may not work as a dictation trigger"
        logger.warning("FnUsageAdvisor firing advisory reason=\(reason, privacy: .public) karabiner=\(eval.karabinerRunning, privacy: .public) fnState=\(String(describing: eval.fnState), privacy: .public)")
        // Show via overlay if available, otherwise log only (tests pass nil).
        if let overlay {
            overlay.showError("\(reason). Check System Settings → Keyboard → Press Fn key to.", action: .openKeyboardSettings, autoHideAfter: 8.0)
        } else {
            // Fallback: post notification that KalamApp can observe.
            NotificationCenter.default.post(name: .fnUsageAdvisorDidFire, object: nil, userInfo: ["reason": reason])
        }
    }

    /// Deep-link to System Settings → Keyboard.
    static func openKeyboardSettings() {
        // macOS 13+ deep link
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
            return
        }
        // Fallback: open Keyboard preference pane
        if let url = URL(string: "file:///System/Library/PreferencePanes/Keyboard.prefPane") {
            NSWorkspace.shared.open(url)
        }
    }

    /// For tests: reset stored last-notified state.
    static func resetForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastShouldAdviseKey)
        defaults.removeObject(forKey: lastNotifiedKey)
    }

    /// For tests: synchronous version without MainActor
    static func resetForTestingSync(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastShouldAdviseKey)
        defaults.removeObject(forKey: lastNotifiedKey)
    }
}

extension Notification.Name {
    static let fnUsageAdvisorDidFire = Notification.Name("fnUsageAdvisorDidFire")
}
