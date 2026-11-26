import AppKit
import ApplicationServices
import Foundation
import OSLog

enum PasteServiceError: LocalizedError {
    case accessibilityNotTrusted
    case pasteExecutionFailed(reason: String)
    case secureField
    case secureInputActive
    case pidMismatch
    case frontmostChanged
    case destinationUnavailable
    case deliveryUnconfirmed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required to insert text."
        case .pasteExecutionFailed(let reason):
            return "Failed to insert text via Accessibility: \(reason)"
        case .secureField:
            return "Refused to paste into secure field."
        case .secureInputActive:
            return "Secure input is active; pasteboard exposure refused."
        case .pidMismatch:
            return "Focused element PID mismatch — hold."
        case .frontmostChanged:
            return "The destination is no longer focused."
        case .destinationUnavailable:
            return "The original destination is unavailable."
        case .deliveryUnconfirmed:
            return "The editor may have received the transcript."
        }
    }
}

@MainActor
final class PasteService {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "PasteService")

    /// Injectable behavior for paste strategies. Production defaults are the real
    /// CGEvent/AX implementations; tests inject fakes so no real keystrokes or
    /// accessibility calls are ever posted (clipboard restore on failed paste regression coverage).
    @MainActor
    struct PasteStrategies {
        var isProcessTrusted: () -> Bool = { AXIsProcessTrusted() }
        var postUnicodeText: ((String) -> Bool)?
        var postCmdV: () -> Bool = { PasteService.postCmdV() }
        /// K-50 experiment: deliver the Cmd+V chord directly to a PID instead
        /// of posting globally. Some apps drop unfocused injected events —
        /// gated behind `internal.latency.pidPasteEnabled` (default OFF) with
        /// automatic fallback to the global post.
        var postCmdVToPid: (pid_t) -> Bool = { PasteService.postCmdVToPid($0) }
        var pasteboard: NSPasteboard = .general
        /// Grace delay before restoring the user's clipboard after a Cmd+V
        /// paste, giving the target app time to read the pasteboard. Only the
        /// Cmd+V path uses this; AX/failure paths restore immediately (pasteboard exposure minimization).
        var restoreDelay: TimeInterval = 0.15
        var afterClipboardWrite: (() async -> Void)?

        // MARK: Task 5 additions — Tier-1 hardening
        var getElementRole: (AXUIElement) -> String? = { PasteService.stringAttribute(kAXRoleAttribute, of: $0) }
        var getElementSubrole: (AXUIElement) -> String? = { PasteService.stringAttribute(kAXSubroleAttribute, of: $0) }
        var getSelection: (AXUIElement) -> NSRange? = { PasteService.selectedRange($0) }
        var getElementValue: (AXUIElement) -> String? = { PasteService.getElementValue($0) }
        var axSetSelectedText: (AXUIElement, String) -> AXError = { PasteService.axSetSelectedText($0, $1) }
        var axGetPid: (AXUIElement) -> pid_t? = { PasteService.axGetPid($0) }
        var bundleIDForPID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        var isSecureEventInputEnabled: () -> Bool = { SecureInput.isSecureEventInputEnabled() }
        var secureInputOwnerPID: () -> pid_t? = { SecureInput.secureInputOwnerPID() }
        var setMessagingTimeout: (AXUIElement, Float) -> Void = { AXUIElementSetMessagingTimeout($0, $1); _ = $0 }
        var resolveFocusedElement: (NSRunningApplication?) -> Result<AccessibilityFocusedElementResolution, AccessibilityFocusResolutionError> = { app in
            AccessibilityFocusResolver.resolveFocusedElement(frontmostApp: app)
        }
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
            let objects = items.map { itemDict in
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                }
                return item
            }
            if !objects.isEmpty { pasteboard.writeObjects(objects) }
        }
    }

    /// Which strategy consumed the transcript, deciding how long it may sit on
    /// the pasteboard before the snapshot restore (pasteboard exposure minimization). Only the Cmd+V path
    /// hands the pasteboard to the target app, so only it keeps a grace delay.
    enum PasteOutcome {
        case cmdV              // target app is expected to read the pasteboard
        case accessibility     // text delivered via AX — pasteboard never consumed
        case failed            // every strategy failed — nothing consumed it
    }

    @MainActor
    struct Destination {
        let pid: pid_t
        let name: String
        let isAlive: () -> Bool

        init(_ app: NSRunningApplication) {
            self.init(pid: app.processIdentifier, name: app.localizedName ?? "the original app",
                      isAlive: { !app.isTerminated })
        }

        init(pid: pid_t, name: String, isAlive: @escaping () -> Bool) {
            self.pid = pid
            self.name = name
            self.isAlive = isAlive
        }
    }

    @MainActor
    struct HeldTranscript {
        let session: SessionID
        let text: String
        let destination: Destination?
        var deliveryUnconfirmed = false

        func deliver(
            using service: PasteService,
            bringToFront: (Destination) async -> Bool,
            stillOwned: @escaping () -> Bool = { true }
        ) async throws {
            guard let destination else { throw PasteServiceError.destinationUnavailable }
            let guarded = Destination(pid: destination.pid, name: destination.name) {
                stillOwned() && destination.isAlive()
            }
            try await service.pasteAfterActivation(text, destination: guarded, bringToFront: bringToFront)
        }
    }

    func pasteAfterActivation(
        _ text: String,
        destination: Destination,
        expectedElement: AXUIElement? = nil,
        bringToFront: (Destination) async -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard destination.isAlive() else { throw PasteServiceError.destinationUnavailable }
        if strategies.frontmostPID() != destination.pid {
            guard await bringToFront(destination) else {
                try Task.checkCancellation()
                throw PasteServiceError.destinationUnavailable
            }
        }
        try await paste(text, preferPid: destination.pid, pidPostingEnabled: false,
                        targetIsAlive: destination.isAlive, expectedElement: expectedElement)
    }

    func paste(_ text: String) async throws {
        try await paste(text, preferPid: nil, pidPostingEnabled: false)
    }

    func paste(
        _ text: String,
        preferPid: pid_t?,
        pidPostingEnabled: Bool,
        targetIsAlive: () -> Bool = { true },
        expectedElement: AXUIElement? = nil
    ) async throws {
        guard strategies.isProcessTrusted() else { throw PasteServiceError.accessibilityNotTrusted }
        let expectedPID = preferPid ?? strategies.frontmostPID()

        func validateFrontmost() throws {
            try validateSecureInput()
            guard targetIsAlive() else { throw PasteServiceError.destinationUnavailable }
            guard strategies.frontmostPID() == expectedPID else { throw PasteServiceError.frontmostChanged }
        }

        func resolveAndValidateFocus() throws -> AXUIElement? {
            try validateFrontmost()
            let element = focusedElement()
            if let element { try validateElement(element, expectedPID: expectedPID) }
            if let expectedElement, element.map({ CFEqual(expectedElement, $0) }) != true {
                throw PasteServiceError.frontmostChanged
            }
            try validateFrontmost()
            return element
        }

        let element = try resolveAndValidateFocus()
        let forcePaste = AppQuirks.shouldForcePaste(bundleID: strategies.frontmostBundleID()) ||
            AppQuirks.shouldForcePaste(bundleID: preferPid.flatMap(strategies.bundleIDForPID))
        if let element, !forcePaste,
           try await insertAndVerify(into: element, text: text, validate: validateFrontmost) {
            logLeg("ax", count: text.count)
            return
        }

        _ = try resolveAndValidateFocus()
        let unicodePosted: Bool
        if let postUnicodeText = strategies.postUnicodeText {
            unicodePosted = postUnicodeText(text)
        } else {
            unicodePosted = try Self.postUnicodeTextIfPossible(text, validate: validateFrontmost)
        }
        if unicodePosted {
            logLeg("unicode", count: text.count)
            return
        }

        let pasteboard = strategies.pasteboard
        let snapshotChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        _ = try resolveAndValidateFocus()
        guard pasteboard.changeCount == snapshotChangeCount else {
            throw PasteServiceError.pasteExecutionFailed(reason: "The clipboard changed before the write.")
        }
        let inserted = writeAndTrackPasteboardState(pasteboard: pasteboard, text: text)
        var outcome = PasteOutcome.failed
        defer { restoreClipboardIfNeeded(snapshot, insertedState: inserted, outcome: outcome) }
        await strategies.afterClipboardWrite?()
        let committed = await waitForPasteboardCommit(pasteboard: pasteboard, targetChangeCount: inserted.changeCount)
        let currentElement = try resolveAndValidateFocus()
        guard committed, pasteboardMatches(inserted) else {
            throw PasteServiceError.pasteExecutionFailed(reason: "The clipboard changed before posting.")
        }
        try validateFrontmost()
        if pidPostingEnabled, let preferPid, strategies.postCmdVToPid(preferPid) {
            outcome = .cmdV
            logLeg("cmd-v-pid", count: text.count)
            return
        }
        try validateFrontmost()
        guard pasteboardMatches(inserted) else {
            throw PasteServiceError.pasteExecutionFailed(reason: "The clipboard changed before posting.")
        }
        if strategies.postCmdV() {
            outcome = .cmdV
            logLeg("cmd-v", count: text.count)
            return
        }

        // Try AX here if focus became resolvable or the app prefers key events.
        if let currentElement, forcePaste || element.map({ CFEqual($0, currentElement) }) != true {
            if try await insertAndVerify(into: currentElement, text: text, validate: validateFrontmost) {
                outcome = .accessibility
                logLeg("ax-fallback", count: text.count)
                return
            }
        }
        throw PasteServiceError.pasteExecutionFailed(reason: "The insertion methods declined the request.")
    }

    func paste(into element: AXUIElement, text: String, destination: Destination? = nil) async throws {
        guard strategies.isProcessTrusted() else { throw PasteServiceError.accessibilityNotTrusted }
        func validate() throws {
            try validateSecureInput()
            if let destination, !destination.isAlive() { throw PasteServiceError.destinationUnavailable }
            try validateElement(element, expectedPID: destination?.pid)
        }
        try validate()
        let pid = destination?.pid ?? strategies.axGetPid(element)
        guard !AppQuirks.shouldForcePaste(bundleID: pid.flatMap(strategies.bundleIDForPID)),
              try await insertAndVerify(into: element, text: text, validate: validate) else {
            throw PasteServiceError.pasteExecutionFailed(reason: "The captured field declined insertion.")
        }
        logLeg("ax-captured", count: text.count)
    }

    private func focusedElement() -> AXUIElement? {
        try? strategies.resolveFocusedElement(NSWorkspace.shared.frontmostApplication).get().element
    }

    private func validateElement(_ element: AXUIElement, expectedPID: pid_t?) throws {
        if let expectedPID, strategies.axGetPid(element) != expectedPID {
            throw PasteServiceError.pidMismatch
        }
        if strategies.getElementSubrole(element) == kAXSecureTextFieldSubrole ||
            strategies.getElementRole(element) == kAXSecureTextFieldSubrole {
            throw PasteServiceError.secureField
        }
    }

    private func validateSecureInput() throws {
        try Task.checkCancellation()
        if strategies.isSecureEventInputEnabled() || (strategies.secureInputOwnerPID() ?? 0) != 0 {
            throw PasteServiceError.secureInputActive
        }
        try Task.checkCancellation()
    }

    private func logLeg(_ leg: String, count: Int) {
        Self.logger.info("Paste leg=\(leg, privacy: .public) length=\(count, privacy: .public)")
    }

    /// Where a transcript should be pasted (record-time paste target capture).
    enum PasteTarget: Equatable {
        /// No capture, or the frontmost app is still the record-time target — existing pipeline.
        case frontmost
        /// The user switched apps during transcription — insert into the captured element.
        case capturedElement(AXUIElement)
        /// partial-AX target capture no-op: the record-time app has partial AX support (no element resolvable),
        /// but its pid was captured — reactivate it and paste via the frontmost path.
        case capturedApp(pid_t)
    }

    /// Pure decision for the paste target (headless-testable).
    enum PasteRouting {
        static func target(capturedPID: pid_t?, capturedElement: AXUIElement?, frontmostPID: pid_t?) -> PasteTarget {
            guard let capturedPID, capturedPID != frontmostPID else {
                return .frontmost
            }
            if let capturedElement {
                return .capturedElement(capturedElement)
            }
            // partial-AX target capture no-op: element unavailable (partial-AX app) — the pid alone still
            // identifies the record-time target.
            return .capturedApp(capturedPID)
        }
    }

    /// K-50: only the frontmost CGEvent route depends on the frontmost app
    /// having settled. Captured-element pastes via AX set-value are focus-
    /// independent; captured-app performs its own activate + settle poll.
    static func requiresFrontmostSettle(_ target: PasteTarget) -> Bool {
        if case .frontmost = target { return true }
        return false
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
        // pasteboard exposure minimization: only the Cmd+V path hands the pasteboard to the target app, so
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
            guard self.pasteboardMatches(insertedState) else {
                guard attempt < maxAttempts else {
                    if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("Clipboard restore skipped: pasteboard no longer matches Kalam's write") }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
                    attemptRestore(attempt: attempt + 1)
                }
                return
            }
            snapshot.restore(to: pasteboard)
            if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("Clipboard restored after paste") }
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                attemptRestore(attempt: 0)
            }
        } else {
            attemptRestore(attempt: 0)
        }
    }

    private func pasteboardMatches(_ inserted: InsertedPasteboardState) -> Bool {
        strategies.pasteboard.changeCount == inserted.changeCount &&
            strategies.pasteboard.string(forType: .string) == inserted.text
    }

    func writeAndTrackPasteboardState(pasteboard: NSPasteboard, text: String) -> InsertedPasteboardState {
        let changeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        return InsertedPasteboardState(text: text, changeCount: changeCount)
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
            // cooperative pasteboard polling: cooperative sleep — yields the MainActor between polls so
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

    /// A successful SET with uncertain readback or a messaging failure
    /// may already have inserted. Only definitive refusals can fall through.
    private func insertAndVerify(
        into element: AXUIElement,
        text: String,
        validate: () throws -> Void
    ) async throws -> Bool {
        let overrideMs = UserDefaults.standard.integer(forKey: "internal.paste.setVerifyTimeoutOverrideMs")
        if overrideMs > 0 { strategies.setMessagingTimeout(element, Float(overrideMs) / 1000) }
        let before = strategies.getElementValue(element)
        let selected = strategies.getSelection(element)
        let expected: String? = if let before, let selected, let range = Range(selected, in: before) {
            before.replacingCharacters(in: range, with: text)
        } else {
            nil
        }
        try validate()
        switch strategies.axSetSelectedText(element, text) {
        case .success:
            break
        case .attributeUnsupported, .noValue, .illegalArgument, .invalidUIElement, .notImplemented:
            return false
        default:
            throw PasteServiceError.deliveryUnconfirmed
        }
        for _ in 0..<3 {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                throw PasteServiceError.deliveryUnconfirmed
            }
            if let after = strategies.getElementValue(element), after != before {
                if let expected, after == expected { return true }
                if expected == nil, before != nil, after == text { return true }
            }
        }
        throw PasteServiceError.deliveryUnconfirmed
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

    /// K-50 experiment: post the Cmd+V chord directly to a PID. Honesty note:
    /// like `postCmdV`, a `true` return means EVENTS WERE POSTED, not that
    /// the target consumed them — the compatibility matrix (manual gate) is
    /// what earns the `internal.latency.pidPasteEnabled` flag being flipped
    /// ON, and the kill-switch is the instant rollback.
    private static func postCmdVToPid(_ pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 55
        let vKey: CGKeyCode = 9
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            Self.logger.warning("Failed to create PID-posted Cmd+V CGEvents")
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdDown.postToPid(pid)
        vDown.postToPid(pid)
        vUp.postToPid(pid)
        cmdUp.postToPid(pid)
        return true
    }

    private static func postUnicodeTextIfPossible(_ text: String, validate: () throws -> Void) throws -> Bool {
        let utf16Array = Array(text.utf16)
        if utf16Array.isEmpty {
            return false
        }
        if utf16Array.count > 200 {
            if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("CGEvent unicode skipped due to length=\(utf16Array.count)") }
            return false
        }

        // Chromium-host hardening (Vivaldi denies AX, so Tier-1 verification
        // never runs and a dropped burst logs a false `inserted`): one giant
        // keyDown/keyUp pair carrying 100+ units is unlike real typing and is
        // intermittently swallowed by the browser pipeline. Post ≤64-unit
        // bursts mimicking keystrokes, with a 4ms gap so the runloop drains.
        // Total main-block stays under ~15ms; the paste path already sleeps
        // 50-80ms around this call.
        let chunkSize = 64
        let gapMicros: useconds_t = 4_000
        var offset = 0
        var chunks = 0
        while offset < utf16Array.count {
            let end = min(offset + chunkSize, utf16Array.count)
            let chunk = Array(utf16Array[offset..<end])
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                Self.logger.warning("Failed to create CGEvent unicode events")
                if chunks > 0 { throw PasteServiceError.deliveryUnconfirmed }
                return false
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            do {
                try validate()
            } catch {
                if chunks > 0 { throw PasteServiceError.deliveryUnconfirmed }
                throw error
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            chunks += 1
            offset = end
            if offset < utf16Array.count {
                usleep(gapMicros)
            }
        }
        if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("CGEvent unicode posted chunks=\(chunks, privacy: .public) length=\(utf16Array.count, privacy: .public)") }
        return true
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func getElementValue(_ element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, of: element)
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location < Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func axSetSelectedText(_ element: AXUIElement, _ text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }

    private static func axGetPid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }
}
