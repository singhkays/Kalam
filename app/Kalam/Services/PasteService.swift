import AppKit
import ApplicationServices
import Foundation
import OSLog

enum PasteServiceError: LocalizedError {
    case accessibilityNotTrusted
    case pasteExecutionFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required to insert text."
        case .pasteExecutionFailed(let reason):
            return "Failed to insert text via Accessibility: \(reason)"
        }
    }
}

@MainActor
final class PasteService {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "PasteService")

    /// Injectable behavior for paste strategies. Production defaults are the real
    /// CGEvent/AX implementations; tests inject fakes so no real keystrokes or
    /// accessibility calls are ever posted (K-02 regression coverage).
    @MainActor
    struct PasteStrategies {
        var isProcessTrusted: () -> Bool = { AXIsProcessTrusted() }
        var postUnicodeText: (String) -> Bool = { PasteService.postUnicodeTextIfPossible($0) }
        var postCmdV: () -> Bool = { PasteService.postCmdV() }
        var insertTextViaAccessibility: (String) -> String? = { PasteService.insertTextViaAccessibility($0) }
        var pasteboard: NSPasteboard = .general
        /// Grace delay before restoring the user's clipboard after a Cmd+V
        /// paste, giving the target app time to read the pasteboard. Only the
        /// Cmd+V path uses this; AX/failure paths restore immediately (K-08).
        var restoreDelay: TimeInterval = 0.15
    }

    private let strategies: PasteStrategies

    init(strategies: PasteStrategies = PasteStrategies()) {
        self.strategies = strategies
    }

    struct PasteboardSnapshot {
        let items: [[String: Data]]

        init(pasteboard: NSPasteboard) {
            var saved: [[String: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var itemDict: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemDict[type.rawValue] = data
                    }
                }
                saved.append(itemDict)
            }
            self.items = saved
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            for itemDict in items {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                }
                pasteboard.writeObjects([item])
            }
        }
    }

    /// Which strategy consumed the transcript, deciding how long it may sit on
    /// the pasteboard before the snapshot restore (K-08). Only the Cmd+V path
    /// hands the pasteboard to the target app, so only it keeps a grace delay.
    enum PasteOutcome {
        case cmdV              // target app is expected to read the pasteboard
        case accessibility     // text delivered via AX — pasteboard never consumed
        case failed            // every strategy failed — nothing consumed it
    }

    func paste(_ text: String) async throws {
        // Check Accessibility without prompting in the hot path.
        guard strategies.isProcessTrusted() else {
            Self.logger.warning("Accessibility not trusted; aborting paste")
            throw PasteServiceError.accessibilityNotTrusted
        }

        if strategies.postUnicodeText(text) {
            Self.logger.info("Paste succeeded via CGEvent unicode")
            return
        }

        let pasteboard = strategies.pasteboard
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let insertedPasteboardState = writeAndTrackPasteboardState(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(pasteboard: pasteboard, targetChangeCount: insertedPasteboardState.changeCount)

        // K-02: the transcript now sits on the user's pasteboard. Restoring the
        // original clipboard content is unconditional from this point — every
        // exit path (Cmd+V success, AX insert success, any failure, or
        // cancellation) schedules the restore. The defer must be registered
        // before the cancellation check so a canceled paste still restores.
        var outcome = PasteOutcome.failed
        defer { restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState, outcome: outcome) }

        // K-09/K-01: the wait is cooperative, so a canceled transcription task
        // (new recording started) reaches this point — abort the paste; the
        // defer above still restores the clipboard.
        try Task.checkCancellation()

        if strategies.postCmdV() {
            Self.logger.info("Paste succeeded via Cmd+V")
            outcome = .cmdV
            return
        }

        if let error = strategies.insertTextViaAccessibility(text) {
            Self.logger.warning("Paste failed after AX fallback: \(error, privacy: .public)")
            throw PasteServiceError.pasteExecutionFailed(reason: error)
        }

        Self.logger.info("Paste succeeded via Accessibility")
        outcome = .accessibility
    }

    struct InsertedPasteboardState {
        let text: String
        let changeCount: Int
    }

    func restoreClipboardIfNeeded(
        _ snapshot: PasteboardSnapshot,
        insertedState: InsertedPasteboardState,
        outcome: PasteOutcome
    ) {
        // K-08: only the Cmd+V path hands the pasteboard to the target app, so
        // only it keeps a (short) grace delay for the app to read it. The AX
        // path and failures restore immediately — the transcript never needs to
        // linger. The changeCount + string-equality guard is unchanged.
        //
        // NSPasteboard commits writes asynchronously, so a restore that runs
        // before the commit lands (immediate path, or a canceled wait) retries
        // briefly until the guard matches. A user copy that replaced the
        // transcript never matches the guard and is left alone — retrying only
        // restores when the pasteboard still holds exactly what Kalam wrote.
        let delay: TimeInterval = outcome == .cmdV ? strategies.restoreDelay : 0
        let retryInterval: TimeInterval = 0.02
        let maxAttempts = 10   // ~200 ms retry budget for a slow commit

        func attemptRestore(attempt: Int) {
            let pasteboard = self.strategies.pasteboard
            guard pasteboard.changeCount == insertedState.changeCount,
                  pasteboard.string(forType: .string) == insertedState.text
            else {
                guard attempt < maxAttempts else {
                    Self.logger.info("Clipboard restore skipped: pasteboard no longer matches Kalam's write")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
                    attemptRestore(attempt: attempt + 1)
                }
                return
            }
            snapshot.restore(to: pasteboard)
            Self.logger.info("Clipboard restored after paste")
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                attemptRestore(attempt: 0)
            }
        } else {
            attemptRestore(attempt: 0)
        }
    }

    func writeAndTrackPasteboardState(pasteboard: NSPasteboard, text: String) -> InsertedPasteboardState {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        let effectiveChangeCount = after == before ? after + 1 : after
        return InsertedPasteboardState(text: text, changeCount: effectiveChangeCount)
    }

    func waitForPasteboardCommit(
        pasteboard: NSPasteboard,
        targetChangeCount: Int,
        timeoutSeconds: TimeInterval = 0.15,
        pollIntervalSeconds: TimeInterval = 0.005
    ) async -> Bool {
        if targetChangeCount <= pasteboard.changeCount {
            return true
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // K-09: cooperative sleep — yields the MainActor between polls so
            // the UI and overlay animations never stall. Cancellation aborts
            // promptly; the caller decides what that means.
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            if Task.isCancelled { return false }
            if pasteboard.changeCount >= targetChangeCount {
                return true
            }
        }
        return false
    }

    private static func postCmdV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 55
        let vKey: CGKeyCode = 9
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            Self.logger.warning("Failed to create Cmd+V CGEvents")
            return false
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicodeTextIfPossible(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)
        if utf16Array.isEmpty {
            return false
        }
        if utf16Array.count > 200 {
            Self.logger.info("CGEvent unicode skipped due to length=\(utf16Array.count)")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            Self.logger.warning("Failed to create CGEvent unicode events")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func insertTextViaAccessibility(_ text: String) -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application found"
        }

        let resolution: AccessibilityFocusedElementResolution
        switch AccessibilityFocusResolver.resolveFocusedElement(frontmostApp: frontmostApp) {
        case .success(let focusedElementResolution):
            resolution = focusedElementResolution
        case .failure(let error):
            return error.reason
        }

        let insertResult = AXUIElementSetAttributeValue(
            resolution.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if insertResult == .success {
            return nil
        }

        let valueResult = AXUIElementSetAttributeValue(
            resolution.element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        if valueResult == .success {
            return nil
        }

        return "Resolved focused element in \(resolution.appName) via \(resolution.strategy), "
            + "but kAXSelectedTextAttribute failed with \(insertResult.debugName) and "
            + "kAXValueAttribute failed with \(valueResult.debugName)."
    }
}
