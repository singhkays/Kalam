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
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "PasteService")

    private struct PasteboardSnapshot {
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

    func paste(_ text: String) throws {
        // Check Accessibility without prompting in the hot path.
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility not trusted; aborting paste")
            throw PasteServiceError.accessibilityNotTrusted
        }

        if postUnicodeTextIfPossible(text) {
            logger.info("Paste succeeded via CGEvent unicode")
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let insertedPasteboardState = writeAndTrackPasteboardState(pasteboard: pasteboard, text: text)
        _ = waitForPasteboardCommit(targetChangeCount: insertedPasteboardState.changeCount)

        if postCmdV() {
            logger.info("Paste succeeded via Cmd+V")
            restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState)
            return
        }

        if let error = insertTextViaAccessibility(text) {
            logger.warning("Paste failed after AX fallback: \(error, privacy: .public)")
            throw PasteServiceError.pasteExecutionFailed(reason: error)
        }

        logger.info("Paste succeeded via Accessibility")
        restoreClipboardIfNeeded(snapshot, insertedState: insertedPasteboardState)
    }

    private struct InsertedPasteboardState {
        let text: String
        let changeCount: Int
    }

    private func restoreClipboardIfNeeded(_ snapshot: PasteboardSnapshot, insertedState: InsertedPasteboardState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == insertedState.changeCount,
                  pasteboard.string(forType: .string) == insertedState.text
            else {
                self.logger.info("Clipboard restore skipped because pasteboard changed after Kalam write")
                return
            }
            snapshot.restore(to: pasteboard)
            self.logger.info("Clipboard restored after paste")
        }
    }

    private func writeAndTrackPasteboardState(pasteboard: NSPasteboard, text: String) -> InsertedPasteboardState {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        let effectiveChangeCount = after == before ? after + 1 : after
        return InsertedPasteboardState(text: text, changeCount: effectiveChangeCount)
    }

    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeoutSeconds: TimeInterval = 0.15,
        pollIntervalSeconds: TimeInterval = 0.005
    ) -> Bool {
        if targetChangeCount <= NSPasteboard.general.changeCount {
            return true
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            usleep(useconds_t(pollIntervalSeconds * 1_000_000))
        }
        return false
    }

    private func postCmdV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 55
        let vKey: CGKeyCode = 9
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            logger.warning("Failed to create Cmd+V CGEvents")
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

    private func postUnicodeTextIfPossible(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)
        if utf16Array.isEmpty {
            return false
        }
        if utf16Array.count > 200 {
            logger.info("CGEvent unicode skipped due to length=\(utf16Array.count)")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            logger.warning("Failed to create CGEvent unicode events")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func insertTextViaAccessibility(_ text: String) -> String? {
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
