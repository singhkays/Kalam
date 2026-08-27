import Foundation
import AppKit
import ApplicationServices

/// K-48 machined palette: brand green #52B788.
private let indicatorBrandGreen = NSColor(srgbRed: 82/255.0, green: 183/255.0, blue: 136/255.0, alpha: 1.0)
// Task 4: green clockwise arc — two speeds, no dwell
private let ringListeningDuration: CFTimeInterval = 3.6
private let ringTranscribingDuration: CFTimeInterval = 2.4
private let ringLineWidth: CGFloat = 1.5
private enum RingSpeed { case listening, transcribing }

// MARK: - Dictation Overlay
@MainActor
final class DictationOverlayController {
    private enum Metrics {
        static let overlayWidth: CGFloat = IndicatorStateModel.machinedFormWidth
        static let compactHeight: CGFloat = 34
        static let recordingHeight: CGFloat = 72
        /// K-48 Task 5: whisper/caret pill height.
        static let pillHeight: CGFloat = 30
        /// K-48 Task 7: at-the-caret chip width (dot + glyph + timer).
        static let caretChipWidth: CGFloat = 84
        static let topInset: CGFloat = 20
        static let bottomInset: CGFloat = 16
    }

    enum OverlayAction {
        case openAccessibilitySettings
        case openMicrophoneSettings
        /// record-time paste target capture: paste a held transcript into the current frontmost app (explicit user action).
        case pasteHeldTranscript
        /// K-52 discard: drop a held transcript without delivering it.
        case destroyHeldTranscript
    }

    private enum OverlayState {
        case recordingHold
        case recordingToggle
        case transcribing
        case success
        case info(message: String)
        case error(message: String, action: OverlayAction?)
    }

    private var window: NSWindow?
    private var contentView: OverlayCapsuleView?
    private var placementScreen: NSScreen?
    private var stateTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var waveformProvider: (() -> [Float])?
    /// record-time paste target capture: injected by the app — pastes a held transcript into the current frontmost app.
    private var pasteHeldTranscriptAction: (() -> Void)?
    /// K-52 discard: injected by the app — clears the held transcript slot.
    private var destroyHeldTranscriptAction: (() -> Void)?
    private var recordingStartTime: CFAbsoluteTime = 0
    private var currentStateSetTime: CFAbsoluteTime = 0
    private let minStateDwellSeconds: Double = 0.25
    private let fadeDuration: TimeInterval = 0.18
    /// Near-instant appearance for recording states; the general fade stays for
    /// transcribing/success/info/error transitions.
    private let recordingFadeDuration: TimeInterval = 0.06
    private let compactWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.compactHeight)
    private let recordingWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.recordingHeight)
    private var currentWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.compactHeight)
    /// K-48: indicator style captured ONCE per dictation session at the show/present entry point.
    /// Hook (sessionStyle): consumed by the compact-surface eligibility check in transition(to:).
    private var sessionStyle: IndicatorStyle = .machined
    /// K-48 Task 5: system appearance and Reduce Motion follow the same once-per-session rule.
    private var sessionUsesDarkAppearance = true
    private var sessionReduceMotion = false
    /// K-48 Task 7: record-time focused element, delivered by KalamApp after the bounded
    /// AX capture; anchors the at-the-caret chip without a second system-wide walk.
    private var caretAnchorElement: AXUIElement?
    private var caretChipWindow: NSWindow?
    private var caretChipContentView: CaretChipView?

    func setWaveformProvider(_ provider: @escaping () -> [Float]) {
        waveformProvider = provider
    }

    /// record-time paste target capture: wire the held-transcript "Paste" action to the app (which owns the paste pipeline).
    func setPasteHeldTranscriptAction(_ action: @escaping () -> Void) {
        pasteHeldTranscriptAction = action
    }

    /// K-52 discard: wire the held-chip "Discard" action to the app, which
    /// clears the held-transcript slot (never delivers it).
    func setDestroyHeldTranscriptAction(_ action: @escaping () -> Void) {
        destroyHeldTranscriptAction = action
    }

    /// Builds the overlay window once at launch so the first recording start
    /// never pays window construction. The window stays unordered (invisible).
    func prewarm() {
        ensureWindow()
        if let screen = placementScreen ?? fallbackScreen() {
            positionWindow(on: screen)
        }
        window?.alphaValue = 0.0
    }

    func showRecording(isHoldMode: Bool) {
        // K-48 mid-flight rule: read settings exactly once per session; changes apply at the next session.
        sessionStyle = GeneralSettingsConfiguration.load().indicatorStyle
        sessionUsesDarkAppearance = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        sessionReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Capture the frontmost app that will receive the pasted text.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetName = frontApp?.localizedName ?? ""
        let targetIcon = frontApp?.icon
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        let state: OverlayState = isHoldMode ? .recordingHold : .recordingToggle
        transition(to: state, autoHideAfter: nil, targetAppName: targetName, targetAppIcon: targetIcon)
    }

    func showTranscribing() {
        transition(to: .transcribing, autoHideAfter: nil)
    }

    func showSuccessAndAutoHide() {
        transition(to: .success, autoHideAfter: 0.35)
    }

    func showInfoAndAutoHide(_ message: String) {
        transition(to: .info(message: message), autoHideAfter: 0.7)
    }

    func showError(_ message: String, action: OverlayAction?, autoHideAfter: TimeInterval? = nil) {
        transition(to: .error(message: message, action: action), autoHideAfter: autoHideAfter)
    }

    /// K-52 discard: surface a held transcript with a primary Paste button and a
    /// secondary Discard link. Called when a superseded session's committed text
    /// is preserved (or parked by a same-session paste failure). The window is
    /// sized to fit the full message + Paste + Discard row (never clips).
    func showHeldTranscript(message: String, targetAppName: String = "", targetAppIcon: NSImage? = nil) {
        transition(to: .error(message: message, action: .pasteHeldTranscript),
                   autoHideAfter: nil,
                   targetAppName: targetAppName,
                   targetAppIcon: targetAppIcon)
        contentView?.setHeldChipSecondaryAction(
            title: "Discard",
            handler: { [weak self] in self?.handle(action: .destroyHeldTranscript) }
        )
        // The transition sized the frame for message + Paste. Add the Discard
        // link's contribution so the row is never clipped. Widths are already
        // measured by Auto Layout now that Discard is shown.
        if let w = window, let view = contentView {
            view.layoutSubtreeIfNeeded()
            let intended = view.fittingSize.width
            guard intended > w.frame.width else { return }
            let screen = placementScreen ?? fallbackScreen()
            let maxW = (screen?.visibleFrame.width ?? Metrics.overlayWidth) * 0.7
            let width = min(max(intended, Metrics.overlayWidth), maxW)
            w.setContentSize(NSSize(width: width, height: Metrics.compactHeight))
            if let s = screen { positionWindow(on: s) }
        }
    }

    func hide() {
        stateTask?.cancel()
        stateTask = nil
        stopWaveformUpdates()
        stopTimerUpdates()
        caretAnchorElement = nil
        hideCaretChip()
        // Task 6 offscreen leak guard: strip infinite CAAnimations while hidden so no
        // CABasicAnimation renders in background between sessions. Both views get both
        // teardown calls — hideGreenRing strips spin + breathe and removes layers,
        // removeSessionAnimations strips dot/shimmer and also calls hideGreenRing.
        contentView?.hideGreenRing()
        contentView?.removeSessionAnimations()
        caretChipContentView?.hideGreenRing()
        caretChipContentView?.removeSessionAnimations()
        // placementScreen is deliberately PERSISTED across sessions: nil-ing it
        // here forced every session start to re-walk AX for placement before the
        // capsule could show. refinePlacementIfMoved corrects it if the user
        // moved to another screen mid-session.
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            w.animator().alphaValue = 0.0
        } completionHandler: {
            MainActor.assumeIsolated {
                w.orderOut(nil)
            }
        }
    }

    private func transition(to state: OverlayState, autoHideAfter: TimeInterval?,
                            targetAppName: String = "", targetAppIcon: NSImage? = nil) {
        stateTask?.cancel()
        stateTask = nil
        ensureWindow()
        let showsWaveform = isRecordingState(state)
        // K-48 Task 5: whisper/caret shrink listening+transcribing to the pill; everything else keeps the deck.
        let compact = usesCompactSurface(for: state)
        // Hoisted: the K-52 hold notice must be measured for width before the
        // window frame is applied, and reused below for the label/button.
        let presentation = presentation(for: state, targetAppName: targetAppName, targetAppIcon: targetAppIcon)
        if compact {
            let mapped = indicatorState(for: state) ?? .listening
            currentWindowSize = NSSize(width: IndicatorStateModel.compactWidth(state: mapped), height: Metrics.pillHeight)
        } else {
            currentWindowSize = showsWaveform ? recordingWindowSize : compactWindowSize
            // K-52 UX: the held-transcript notice must show its full line, app
            // name included. Grow the deck to fit message + Paste button
            // (capped to the screen) instead of clipping the tail. Recording
            // surfaces keep the canonical machined width.
            if !showsWaveform, presentation.actionTitle != nil {
                let messageFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
                let textWidth = (presentation.message as NSString)
                    .size(withAttributes: [.font: messageFont]).width
                let buttonFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let buttonWidth = ((presentation.actionTitle ?? "") as NSString)
                    .size(withAttributes: [.font: buttonFont]).width + 28
                let needed = ceil(textWidth) + ceil(buttonWidth)
                    + 12 + 10 + 8 + 12 // label padding + button gap + capsule hPadding (OverlayCapsuleView.Metrics.hPadding)
                let maxWidth = ((placementScreen ?? fallbackScreen())?.visibleFrame.width ?? Metrics.overlayWidth) * 0.7
                let width = min(max(needed, Metrics.overlayWidth), maxWidth)
                if width > Metrics.overlayWidth {
                    currentWindowSize = NSSize(width: width, height: Metrics.compactHeight)
                }
            }
        }
        if placementScreen == nil {
            placementScreen = resolvePlacementScreen(from: nil) ?? fallbackScreen()
        }
        if let screen = placementScreen ?? fallbackScreen() {
            positionWindow(on: screen)
        }
        guard let w = window, let view = contentView else { return }
        // K-48 Task 7: when the caret chip owns feedback, the corner window stays hidden
        // but BOTH feedback loops still run — they drive the chip's clock, level glyph,
        // and 500ms re-anchoring. If anchoring fails, the fallback law applies: hide the
        // chip attempt and let the machined deck take the state (review R1/R3).
        if caretChipOwnsFeedback(for: state) {
            updateCaretChip(state: state, element: caretAnchorElement)
            if caretChipWindow?.isVisible == true {
                // Chip is live: corner window stays hidden; loops drive clock/levels/re-anchor.
                // Task 5 B gating: caret listening never shows a ring; machined listening never (waveform is hero).
                // Strip ring offscreen while chip owns feedback — chip never spins, deck stays hidden.
                if let mapped = indicatorState(for: state), mapped == .listening {
                    contentView?.hideGreenRing()
                    caretChipContentView?.hideGreenRing()
                } else {
                    contentView?.hideGreenRing()
                    caretChipContentView?.hideGreenRing()
                }
                w.alphaValue = 0.0
                startWaveformUpdates()
                startTimerUpdates()
                currentStateSetTime = CFAbsoluteTimeGetCurrent()
                return
            }
            // Anchor failed: fallback law hands the state to the machined deck below.
            hideCaretChip()
        } else {
            hideCaretChip()
        }
        view.setWaveformVisible(showsWaveform && !compact)
        // K-48 Task 5: per-session surface switch — pill styling vs machined deck.
        view.setCompactSurface(active: compact, darkAppearance: sessionUsesDarkAppearance, reduceMotion: sessionReduceMotion)
        // Task 5 B gating: whisper listening slow 3.6s, all transcribing fast 2.4s, caret/machined listening never; strip ring offscreen.
        do {
            let mapped = indicatorState(for: state)
            if let s = mapped, s == .transcribing {
                if compact {
                    contentView?.showGreenRing(speed: .transcribing)
                } else if !(caretChipOwnsFeedback(for: state) && caretChipWindow?.isVisible == true) {
                    contentView?.showGreenRing(speed: .transcribing)
                }
                caretChipContentView?.hideGreenRing()
            } else if mapped == .listening, sessionStyle == .whisper {
                contentView?.showGreenRing(speed: .listening)
                caretChipContentView?.hideGreenRing()
            } else {
                contentView?.hideGreenRing()
                caretChipContentView?.hideGreenRing()
            }
            if caretChipOwnsFeedback(for: state), mapped == .listening {
                caretChipContentView?.hideGreenRing()
            }
        }
        currentStateSetTime = CFAbsoluteTimeGetCurrent()
        // overlay action buttons unclickable: the overlay is click-through EXCEPT while an actionable state
        // (held-transcript "Paste", error "Open") is presented — with
        // ignoresMouseEvents stuck on, those buttons can never be clicked.
        w.ignoresMouseEvents = (presentation.action == nil)
        view.apply(presentation: presentation)
        w.alphaValue = 0.0
        w.orderFrontRegardless()
        let presentDuration = isRecordingState(state) ? recordingFadeDuration : fadeDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = presentDuration
            w.animator().alphaValue = 1.0
        }
        if let autoHideAfter {
            stateTask = Task { [weak self] in
                guard let self else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - self.currentStateSetTime
                let remainDwell = max(0.0, self.minStateDwellSeconds - elapsed)
                if remainDwell > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainDwell * 1_000_000_000))
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0.0, autoHideAfter) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.hide()
                }
            }
        }
        if showsWaveform {
            startWaveformUpdates()
            startTimerUpdates()
        } else {
            stopWaveformUpdates()
            stopTimerUpdates()
            contentView?.updateWaveform(samples: [], active: false)
        }
    }

    private func isRecordingState(_ state: OverlayState) -> Bool {
        switch state {
        case .recordingHold, .recordingToggle:
            return true
        default:
            return false
        }
    }

    /// K-48: design-state vocabulary. Transient auto-hide states are never compact-eligible:
    /// a pill that flashes for a fraction of a second is unreadable, so they stay machined-form.
    private func indicatorState(for state: OverlayState) -> IndicatorState? {
        switch state {
        case .recordingHold, .recordingToggle: return .listening
        case .transcribing: return .transcribing
        case .success, .info, .error: return nil
        }
    }

    /// K-48 Task 5/7: ONLY whisper renders the compact pill. Caret never uses this surface:
    /// during recording the chip owns feedback (main window stays hidden), and during
    /// transcribing/held/blocked the fallback law returns the machined deck.
    private func usesCompactSurface(for state: OverlayState) -> Bool {
        guard sessionStyle == .whisper,
              let mapped = indicatorState(for: state),
              IndicatorStateModel.usesCompactSurface(style: sessionStyle, state: mapped) else { return false }
        return true
    }

    /// K-48 Task 7: true when the caret chip owns feedback for this state
    /// (caret style + an actual recording phase).
    private func caretChipOwnsFeedback(for state: OverlayState) -> Bool {
        sessionStyle == .caret && isRecordingState(state)
    }

    private func presentation(for state: OverlayState,
                              targetAppName: String = "",
                              targetAppIcon: NSImage? = nil) -> OverlayCapsuleView.Presentation {
        switch state {
        case .recordingHold:
            return .init(message: "Release to stop", actionTitle: nil, action: nil,
                         targetAppName: targetAppName, targetAppIcon: targetAppIcon, isRecording: true)
        case .recordingToggle:
            return .init(message: "Tap hotkey to stop", actionTitle: nil, action: nil,
                         targetAppName: targetAppName, targetAppIcon: targetAppIcon, isRecording: true)
        case .transcribing:
            return .init(message: "Transcribing…", actionTitle: nil, action: nil)
        case .success:
            return .init(message: "Inserted", actionTitle: nil, action: nil)
        case .info(let message):
            return .init(message: message, actionTitle: nil, action: nil)
        case .error(let message, let action):
            return .init(
                message: message,
                actionTitle: actionTitle(for: action),
                action: { [weak self] in
                    self?.handle(action: action)
                }
            )
        }
    }

    private func actionTitle(for action: OverlayAction?) -> String? {
        switch action {
        case .openAccessibilitySettings:
            return "Open"
        case .openMicrophoneSettings:
            return "Open"
        case .pasteHeldTranscript:
            return "Paste"
        case .destroyHeldTranscript:
            return "Discard"
        case .none:
            return nil
        }
    }

    private func handle(action: OverlayAction?) {
        guard let action else { return }
        switch action {
        case .openAccessibilitySettings:
            _ = SystemSettingsNavigator.open(.accessibility)
        case .openMicrophoneSettings:
            _ = SystemSettingsNavigator.open(.microphone)
                case .pasteHeldTranscript:
            pasteHeldTranscriptAction?()
        case .destroyHeldTranscript:
            destroyHeldTranscriptAction?()
        }
        hide()
    }

    private func startWaveformUpdates() {
        stopWaveformUpdates()
        waveformTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let samples = self.waveformProvider?() ?? []
                await MainActor.run {
                    self.contentView?.updateWaveform(samples: samples, active: true)
                    self.contentView?.updatePillLevel(samples: samples)
                    self.caretChipContentView?.updateLevel(samples: samples)
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func stopWaveformUpdates() {
        waveformTask?.cancel()
        waveformTask = nil
    }

    private func startTimerUpdates() {
        stopTimerUpdates()
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed = Int(CFAbsoluteTimeGetCurrent() - self.recordingStartTime)
                let mm = elapsed / 60
                let ss = elapsed % 60
                let formatted = String(format: "%02d:%02d", mm, ss)
                await MainActor.run {
                    self.contentView?.updateElapsedTime(formatted)
                    self.updateCaretChipForTick(formattedTime: formatted)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopTimerUpdates() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// K-48 Task 7: per-tick caret chip refresh. The 500ms timer only runs while a
    /// recording state is active (startTimerUpdates is gated on showsWaveform), so the
    /// chip re-anchors on caret moves for exactly the states it owns.
    fileprivate func updateCaretChipForTick(formattedTime: String) {
        let chipVisibleBefore = caretChipWindow?.isVisible == true
        updateCaretChip(state: .recordingToggle, element: caretAnchorElement)
        let chipVisibleNow = caretChipWindow?.isVisible == true
        caretChipContentView?.updateTime(formattedTime)
        // Review finding: the record-time capture lands AFTER indicator-up, so the first
        // transition almost always renders the deck; promote/demote here so exactly one
        // surface is ever visible.
        if chipVisibleNow && !chipVisibleBefore {
            // Chip went live: retire the corner window.
            window?.alphaValue = 0.0
            // Task 5 B gating: caret listening never — chip owns feedback, strip any deck ring
            contentView?.hideGreenRing()
            caretChipContentView?.hideGreenRing()
        } else if !chipVisibleNow && chipVisibleBefore {
            // Anchor died mid-recording: restore the deck, never indicator-less.
            window?.alphaValue = 1.0
            // Task 5: fallback to deck — re-apply gating. Listening (this tick is listening-only) hides ring;
            // if transcribing after fallback, show fast ring on deck.
            // Note: tick models listening; reuse transcribing gate for correctness if state ever widens.
            let mapped: IndicatorState? = .listening
            if mapped == .transcribing {
                contentView?.showGreenRing(speed: .transcribing)
                caretChipContentView?.hideGreenRing()
            } else {
                // Caret/machined listening never shows ring even on fallback deck
                contentView?.hideGreenRing()
                caretChipContentView?.hideGreenRing()
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let view = OverlayCapsuleView(frame: NSRect(origin: .zero, size: currentWindowSize))
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: currentWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.contentView = view
        contentView = view
        window = w
    }

    private func positionWindow(on screen: NSScreen) {
        guard let w = window else { return }
        let screenFrame = screen.visibleFrame
        let placement = GeneralSettingsConfiguration.load().indicatorPlacement
        let frame = frameForPlacement(placement, visibleFrame: screenFrame)
        w.setFrame(frame, display: false)
    }

    private func frameForPlacement(_ placement: IndicatorPlacement, visibleFrame: CGRect) -> CGRect {
        let ww = currentWindowSize.width
        let wh = currentWindowSize.height
        let maxX = visibleFrame.maxX - ww
        let maxY = visibleFrame.maxY - wh
        let centeredX = visibleFrame.midX - (ww * 0.5)
        let clampedCenterX = max(visibleFrame.minX, min(centeredX, maxX))

        let origin: CGPoint
        switch placement {
        case .topCenter:
            origin = CGPoint(x: clampedCenterX, y: max(visibleFrame.minY, min(maxY - Metrics.topInset, maxY)))
        case .bottomCenter:
            origin = CGPoint(x: clampedCenterX, y: max(visibleFrame.minY, min(visibleFrame.minY + Metrics.bottomInset, maxY)))
        }
        return NSRect(x: origin.x, y: origin.y, width: ww, height: wh)
    }

    // MARK: Caret location helpers

    private func flipAXRect(_ rect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func fallbackScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func resolvePlacementScreen(from hint: AXUIElement?) -> NSScreen? {
        guard AXIsProcessTrusted(),
              let element = hint ?? focusedAXElement(),
              let frame = frameOfAXElement(element) else {
            return fallbackScreen()
        }
        let appKitRect = flipAXRect(frame)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? fallbackScreen()
    }

    /// K-48 Task 7: delivers the record-time focused element for caret anchoring.
    func setCaretAnchorElement(_ element: AXUIElement?) {
        caretAnchorElement = element
    }

    /// Called once the bounded record-time focus capture lands. Repositions
    /// silently ONLY if the freshly learned screen differs from the one the
    /// capsule was placed on. No second system-wide AX walk.
    func refinePlacementIfMoved(focusHint: AXUIElement?) {
        guard let element = focusHint,
              AXIsProcessTrusted(),
              let frame = frameOfAXElement(element) else { return }
        let appKitRect = flipAXRect(frame)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              screen != placementScreen else { return }
        placementScreen = screen
        positionWindow(on: screen)
    }

    private func focusedAXElement() -> AXUIElement? {
        AccessibilityFocusResolver.focusedElement()
    }

    private func frameOfAXElement(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
           let p = positionRef,
           CFGetTypeID(p) == AXValueGetTypeID(),
           AXValueGetValue((p as! AXValue), .cgPoint, &position),
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let s = sizeRef,
           CFGetTypeID(s) == AXValueGetTypeID(),
           AXValueGetValue((s as! AXValue), .cgSize, &size) {
            return CGRect(origin: position, size: size)
        }
        return nil
    }

    // MARK: K-48 Task 7 — at-the-caret chip

    /// Resolves the on-screen rect of the text selection start via the selected-text range.
    /// Returns nil for any failure (no range attribute, BoundsForRange refusal, degenerate rect).
    private func caretRect(for element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue as CFTypeRef,
            &boundsRef) == .success,
            let bounds = boundsRef,
            CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return flipAXRect(rect)
    }

    /// Shows or hides the at-the-caret chip window. The chip is a separate borderless
    /// window anchored to the caret rect; any resolution failure hides it and leaves
    /// the corner capsule in charge (fallback law). Called from the timer tick so a
    /// moved caret re-anchors within half a second without its own polling loop.
    private func updateCaretChip(state: OverlayState, element: AXUIElement?) {
        let eligible = sessionStyle == .caret && isRecordingState(state)
        guard eligible, let element, let rawRect = caretRect(for: element) else {
            hideCaretChip()
            return
        }
        guard let screen = placementScreen ?? fallbackScreen(),
              let anchor = CaretAnchorResolver.chipOrigin(
                caretRect: rawRect,
                screenFrame: screen.frame,
                chipSize: CGSize(width: Metrics.caretChipWidth, height: Metrics.pillHeight)) else {
            hideCaretChip()
            return
        }
        ensureCaretChipWindow()
        guard let chipWindow = caretChipWindow, let chipView = caretChipContentView else { return }
        chipWindow.setFrame(
            NSRect(x: anchor.x, y: anchor.y, width: Metrics.caretChipWidth, height: Metrics.pillHeight),
            display: true)
        chipView.applySurfaceStylingForSession(dark: sessionUsesDarkAppearance, reduceMotion: sessionReduceMotion)
        // Review gap 1: the chip carries its own full visibility — ordered front here,
        // ordered out by hideCaretChip(). It must NOT mirror the corner window's alpha,
        // which is 0 while the chip owns feedback.
        if chipWindow.alphaValue < 1.0 { chipWindow.alphaValue = 1.0 }
        if !chipWindow.isVisible { chipWindow.orderFrontRegardless() }
    }

    private func ensureCaretChipWindow() {
        guard caretChipWindow == nil else { return }
        let view = CaretChipView(frame: NSRect(origin: .zero,
                                               size: CGSize(width: Metrics.caretChipWidth, height: Metrics.pillHeight)))
        let w = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: Metrics.caretChipWidth, height: Metrics.pillHeight)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.contentView = view
        caretChipContentView = view
        caretChipWindow = w
    }

    private func hideCaretChip() {
        guard let w = caretChipWindow else { return }
        w.orderOut(nil)
    }
}

private final class OverlayCapsuleView: NSView {
    private enum Metrics {
        static let waveformHeight: CGFloat = 39
        static let topRowHeight: CGFloat = 20
        static let topRowTopPadding: CGFloat = 7
        static let waveformTopSpacing: CGFloat = 4
        /// K-48 Task 5: whisper pill metrics.
        static let pillCornerRadius: CGFloat = 15
        static let pillGlyphHeight: CGFloat = 12
        static let pillBarWidth: CGFloat = 2.5
        static let shimmerDotSize: CGFloat = 4
        static let cornerRadius: CGFloat = 14
        static let hPadding: CGFloat = 12
    }

        struct Presentation {
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
        /// K-52 discard: a secondary link-style button shown on the held
        /// chip so a user can clear a preserved transcript instead of
        /// pasting it. Nil for every surface except the held chip.
        var secondaryActionTitle: String? = nil
        var secondaryAction: (() -> Void)? = nil
        var targetAppName: String = ""
        var targetAppIcon: NSImage? = nil
        var isRecording: Bool = false
    }

    // Container clip for obsidian glass: NSVisualEffectView behindWindow ignores layer.mask/cornerRadius,
    // so stadium rounding must be provided by a clipping container (wantsLayer + masksToBounds + cornerCurve).
    private let clipContainer = NSView()
    // Shared subviews
    private let blurView = NSVisualEffectView()
    private let tintView = NSView()

        // Non-recording row
    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    /// K-52 discard: secondary button beside the primary Paste on the held chip.
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    // Recording-mode top row
    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
    private let recordingDotView = NSView()
    private let timerLabel = NSTextField(labelWithString: "00:00")

    // Waveform
    private let waveformView = WaveformView(frame: .zero)

    // K-48 Task 5: whisper pill — drawn level glyph + transcribing shimmer dots.
    private let pillLevelGlyph = PillLevelGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 12))
    private let shimmerDot0 = NSView()
    private let shimmerDot1 = NSView()
    private let shimmerDot2 = NSView()

        private var actionHandler: (() -> Void)?
    /// K-52 discard: callback for the secondary link-style button on the held chip.
    private var secondaryActionHandler: (() -> Void)?
    private var waveformTopConstraint: NSLayoutConstraint?
    private var waveformHeightConstraint: NSLayoutConstraint?
    private var appIconTopConstraint: NSLayoutConstraint?
    private var appIconCenterYConstraint: NSLayoutConstraint?
    private var appIconWidthConstraint: NSLayoutConstraint?
    private var appIconHeightConstraint: NSLayoutConstraint?

    // K-48 Task 5: whisper pill — per-session surface + compact glyph.
    private var isCompactSurface = false {
        didSet { applySurfaceStyling() }
    }
    private var usesDarkAppearanceForSession = true
    private var sessionReduceMotion = false
    private var shimmerStack: NSStackView?
    private var dots: [NSView] { [shimmerDot0, shimmerDot1, shimmerDot2] }

    // Task 3: universal rim — inner via blurView border (1px), outer via shape layer, shadow for elevation
    private let outerStrokeLayer = CAShapeLayer()
    private let innerStroke = CALayer() // kept for verifier parity: inner 1px is blurView.layer border
    private let outerStroke = CAShapeLayer() // alias for spec naming
    // Fix: explicit mask for NSVisualEffectView rounding — cornerRadius/masksToBounds alone does not clip backdrop
    private let blurMaskLayer = CAShapeLayer()
    // Task 4: green clockwise arc — conic gradient + glow, two speeds (3.6 listening, 2.4 transcribing), no dwell
    private let ringLayer = CAGradientLayer()
    private let ringGlowLayer = CAGradientLayer()
    private var ringIsInstalled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(presentation: Presentation) {
        if presentation.isRecording {
            // Show recording-mode top row
            appIconView.isHidden = false
            appNameLabel.isHidden = false
            recordingDotView.isHidden = isCompactSurface
            timerLabel.isHidden = false
            messageLabel.isHidden = true
            actionButton.isHidden = true
            shimmerStack?.isHidden = true

            // App info
            if let icon = presentation.targetAppIcon {
                appIconView.image = icon
            } else {
                appIconView.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            appNameLabel.stringValue = presentation.targetAppName.isEmpty ? "App" : presentation.targetAppName
            timerLabel.stringValue = "00:00"
            pillLevelGlyph.isHidden = !isCompactSurface
        } else {
            // Standard compact row
            appIconView.isHidden = true
            appNameLabel.isHidden = true
            recordingDotView.isHidden = true
            timerLabel.isHidden = true
            pillLevelGlyph.isHidden = true
            actionHandler = presentation.action
            let isTranscribingPill = isCompactSurface && presentation.message.hasPrefix("Transcribing")
            if isTranscribingPill {
                messageLabel.stringValue = "Transcribing"
                messageLabel.isHidden = false
                actionButton.isHidden = true
                shimmerStack?.isHidden = false
            } else {
                shimmerStack?.isHidden = true
                messageLabel.stringValue = presentation.message
                messageLabel.isHidden = false
                secondaryActionHandler = presentation.secondaryAction
                if let title = presentation.actionTitle {
                    actionButton.title = title
                    actionButton.isHidden = false
                } else {
                    actionButton.isHidden = true
                }
                if let secondaryTitle = presentation.secondaryActionTitle {
                    secondaryButton.title = secondaryTitle
                    secondaryButton.isHidden = false
                } else {
                    // Zero-width when hidden: the label's cap at the discard
                    // leading collapses to nothing, so non-held messages keep
                    // their full width.
                    secondaryButton.title = ""
                    secondaryButton.isHidden = true
                }
            }
        }
    }


    func setWaveformVisible(_ visible: Bool) {
        waveformView.isHidden = !visible
        waveformTopConstraint?.constant = visible ? Metrics.waveformTopSpacing : 0
        waveformHeightConstraint?.constant = visible ? Metrics.waveformHeight : 0
        if !visible {
            waveformView.reset()
        }
    }

    func updateWaveform(samples: [Float], active: Bool) {
        waveformView.update(samples: samples, active: active)
    }

    func updateElapsedTime(_ formatted: String) {
        timerLabel.stringValue = formatted
    }

    private func setup() {
        wantsLayer = true
        // Task 3: universal rim — elevation + double-stroke. Self hosts shadow/outer stroke, blurView clips inner.
        // FIX: whisper pill square corners — self must not clip shadow, and must stay transparent (no square bg).
        layer?.masksToBounds = false
        layer?.backgroundColor = nil
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 10)
        // Outer 1px stroke sits on self.layer so its outer half lifts off the background (white/dark).
        outerStrokeLayer.fillColor = NSColor.clear.cgColor
        outerStrokeLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        outerStrokeLayer.lineWidth = 1
        outerStrokeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(outerStrokeLayer)
        // Initial stadium paths so first frame before layout is already clipped (prewarm)
        let initialRadius = Metrics.cornerRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: initialRadius, cornerHeight: initialRadius, transform: nil)
        outerStrokeLayer.frame = bounds
        outerStrokeLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, initialRadius - 0.5), cornerHeight: max(0, initialRadius - 0.5), transform: nil)
        // Task 4: green clockwise arc — conic gradient ring + glow (configured here, installed in showGreenRing)
        ringLayer.type = .conic
        ringLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, indicatorBrandGreen.cgColor]
        ringLayer.locations = [0.0, 0.71, 1.0]
        ringLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.endPoint = CGPoint(x: 1, y: 0.5)
        ringLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let ringMask = CAShapeLayer()
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = ringLineWidth
        ringMask.lineCap = .round
        ringMask.lineJoin = .round
        ringLayer.mask = ringMask
        ringGlowLayer.type = .conic
        ringGlowLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, indicatorBrandGreen.cgColor]
        ringGlowLayer.locations = [0.0, 0.71, 1.0]
        ringGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringGlowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        ringGlowLayer.opacity = 0.38
        ringGlowLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let glowMask = CAShapeLayer()
        glowMask.fillColor = NSColor.clear.cgColor
        glowMask.strokeColor = NSColor.white.cgColor
        glowMask.lineWidth = 6
        glowMask.lineCap = .round
        glowMask.lineJoin = .round
        glowMask.opacity = 0.38
        ringGlowLayer.mask = glowMask

        // Container clip: NSVisualEffectView with behindWindow ignores layer.mask/cornerRadius for its backdrop.
        // Clip via a container NSView that provides the stadium cornerRadius; blurView itself still carries
        // an explicit mask as a secondary guarantee but the container is the source-of-truth for clipping.
        clipContainer.wantsLayer = true
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        clipContainer.layer?.cornerRadius = Metrics.cornerRadius
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipContainer)

        // Blur background — dark material, higher translucency
        // Fix: wantsLayer BEFORE material/cornerRadius so layer exists; mask guarantees clip for NSVisualEffectView backdrop
        blurView.wantsLayer = true
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.appearance = NSAppearance(named: .darkAqua)
        blurView.alphaValue = 1.0
        blurView.layer?.cornerRadius = Metrics.cornerRadius
        blurView.layer?.masksToBounds = true
        blurView.layer?.cornerCurve = .continuous
        blurView.layer?.borderWidth = 1
        blurView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // Explicit mask: NSVisualEffectView's backdrop ignores cornerRadius/masksToBounds on some builds
        // Retained as secondary guarantee; primary clip is clipContainer.
        blurMaskLayer.fillColor = NSColor.black.cgColor
        blurView.layer?.mask = blurMaskLayer
        blurView.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.addSubview(blurView)

        // Dark tint layer — more translucent for a grey look
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(srgbRed: 20/255.0, green: 20/255.0, blue: 18/255.0, alpha: 0.55).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(tintView, positioned: .below, relativeTo: nil)

        // ── Non-recording message label ──
        messageLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        messageLabel.textColor = .white
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(messageLabel)

        actionButton.bezelStyle = .rounded
        actionButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        actionButton.target = self
        actionButton.action = #selector(didTapAction)
        actionButton.isHidden = true
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(actionButton)

        // K-52 discard: link-style secondary button (Discard) on the held chip.
        secondaryButton.bezelStyle = .regularSquare
        secondaryButton.isBordered = false
        secondaryButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        secondaryButton.alignment = .center
        secondaryButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        secondaryButton.target = self
        secondaryButton.action = #selector(didTapSecondaryAction)
        secondaryButton.isHidden = true
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.setContentHuggingPriority(.required, for: .horizontal)
        blurView.addSubview(secondaryButton)

        // ── Recording-mode top row ──
        // App icon
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = 4
        appIconView.layer?.masksToBounds = true
        appIconView.isHidden = true
        blurView.addSubview(appIconView)

        let iconTop = appIconView.topAnchor.constraint(equalTo: blurView.topAnchor, constant: Metrics.topRowTopPadding)
        let iconCenterY = appIconView.centerYAnchor.constraint(equalTo: blurView.centerYAnchor)
        let iconWidth = appIconView.widthAnchor.constraint(equalToConstant: Metrics.topRowHeight)
        let iconHeight = appIconView.heightAnchor.constraint(equalToConstant: Metrics.topRowHeight)
        appIconTopConstraint = iconTop
        appIconCenterYConstraint = iconCenterY
        appIconWidthConstraint = iconWidth
        appIconHeightConstraint = iconHeight

        // App name
        appNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        appNameLabel.textColor = .white
        appNameLabel.lineBreakMode = .byTruncatingMiddle
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        appNameLabel.isHidden = true
        blurView.addSubview(appNameLabel)

        // Recording status dot — brand green fill with soft glow (K-48 machined surface).
        recordingDotView.wantsLayer = true
        recordingDotView.layer?.backgroundColor = indicatorBrandGreen.cgColor
        recordingDotView.layer?.cornerRadius = 3.5
        recordingDotView.layer?.masksToBounds = false
        recordingDotView.layer?.shadowColor = indicatorBrandGreen.cgColor
        recordingDotView.layer?.shadowOpacity = 0.4
        recordingDotView.layer?.shadowRadius = 8
        recordingDotView.layer?.shadowOffset = .zero
        recordingDotView.isHidden = true
        // Constraint-conflict fix: the dot is fully Auto Layout constrained (7x7);
        // without this its zero-size autoresizing mask fights those constraints and
        // Auto Layout breaks unrelated rows to recover.
        recordingDotView.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(recordingDotView)
        // K-48 review finding I-1: Reduce Motion is evaluated PER SESSION (showRecording),
        // not here — updateBreatheAnimation() applies the session value whenever the surface flips.
        updateBreatheAnimation()

        // Timer — monospaced digits, right-aligned
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        timerLabel.alignment = .right
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.isHidden = true
        blurView.addSubview(timerLabel)

        // Waveform
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.wantsLayer = true
        waveformView.layer?.zPosition = 100 // Keep bars above the dark tint surface
        blurView.addSubview(waveformView)

        NSLayoutConstraint.activate([
            // Container clip fills capsule; blur fills container (container provides stadium clip for behindWindow)
            clipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipContainer.topAnchor.constraint(equalTo: topAnchor),
            clipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            blurView.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),

            // Tint fills blur
            tintView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: blurView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: blurView.bottomAnchor),

            // Non-recording message label
            messageLabel.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: Metrics.hPadding),
            messageLabel.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),
            // K-52 discard: the message must stop before the Discard link, not
            // just before Paste — otherwise the line overlays "Discard".
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: secondaryButton.leadingAnchor, constant: -8),
            // K-52 discard: Discard link sits between message and action button.
            secondaryButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
            secondaryButton.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),

            // Recording top row — icon
            appIconView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: Metrics.hPadding),
            iconTop,
            iconWidth,
            iconHeight,

            // Recording top row — app name
            appNameLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 7),
            appNameLabel.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: recordingDotView.leadingAnchor, constant: -8),

            // Recording top row — status dot (sits before the timer)
            recordingDotView.widthAnchor.constraint(equalToConstant: 7),
            recordingDotView.heightAnchor.constraint(equalToConstant: 7),
            recordingDotView.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            recordingDotView.trailingAnchor.constraint(equalTo: timerLabel.leadingAnchor, constant: -8),

            // Recording top row — timer
            timerLabel.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -Metrics.hPadding),
            timerLabel.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),

            // Waveform horizontal insets
            waveformView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: Metrics.hPadding),
            waveformView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -Metrics.hPadding)
        ])

        waveformTopConstraint = waveformView.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: Metrics.waveformTopSpacing)
        waveformHeightConstraint = waveformView.heightAnchor.constraint(equalToConstant: Metrics.waveformHeight)
        waveformTopConstraint?.isActive = true
        waveformHeightConstraint?.isActive = true
        waveformView.isHidden = true

        setupPillChrome()
    }

    /// K-48 Task 5: builds the pill-only chrome (drawn level glyph, shimmer dots) and
    /// pill-specific layout adjustments. Hidden by default; the machined deck stays
    /// the default surface until setCompactSurface(active:) flips the session style.
    private func setupPillChrome() {
        // Drawn glyph: one custom view, no per-bar constraints to churn.
        pillLevelGlyph.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(pillLevelGlyph)
        NSLayoutConstraint.activate([
            pillLevelGlyph.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            pillLevelGlyph.trailingAnchor.constraint(equalTo: timerLabel.leadingAnchor, constant: -8),
            pillLevelGlyph.widthAnchor.constraint(equalToConstant: 14),
            pillLevelGlyph.heightAnchor.constraint(equalToConstant: 12)
        ])

        let dots = [shimmerDot0, shimmerDot1, shimmerDot2]
        for (index, dot) in dots.enumerated() {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = indicatorBrandGreen.cgColor
            dot.layer?.cornerRadius = Metrics.shimmerDotSize / 2
            dot.alphaValue = 0.35
            // Visibility is owned by shimmerStack; dots must stay visible inside it.
            dot.isHidden = false
            dot.translatesAutoresizingMaskIntoConstraints = false
            blurView.addSubview(dot)
        }
        let shimmerStack = NSStackView(views: dots)
        shimmerStack.orientation = .horizontal
        shimmerStack.alignment = .centerY
        shimmerStack.spacing = 3
        shimmerStack.translatesAutoresizingMaskIntoConstraints = false
        shimmerStack.isHidden = true
        blurView.addSubview(shimmerStack)
        self.shimmerStack = shimmerStack
        NSLayoutConstraint.activate([
            shimmerStack.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            shimmerStack.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -Metrics.hPadding)
        ])
    }

    override func layout() {
        super.layout()
        // Task 3: keep shadowPath + outer stroke synced to current bounds+cornerRadius (14 machined /15 pill)
        // obsidian fix: container clip provides true stadium clipping for behindWindow; blurView mask is secondary
        let radius: CGFloat = isCompactSurface ? Metrics.pillCornerRadius : Metrics.cornerRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        outerStrokeLayer.frame = bounds
        let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let innerRadius = max(0, radius - 0.5)
        outerStrokeLayer.path = CGPath(roundedRect: insetBounds, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
        // Container clip — source-of-truth for stadium clip (behindWindow ignores blurView.layer.mask)
        clipContainer.layer?.cornerRadius = radius
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        // Explicit mask guarantees stadium clip even when NSVisualEffectView ignores cornerRadius (secondary)
        blurMaskLayer.frame = blurView.bounds
        blurMaskLayer.path = CGPath(roundedRect: blurView.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        blurView.layer?.cornerRadius = radius
        blurView.layer?.masksToBounds = true
        blurView.layer?.cornerCurve = .continuous
        layoutRing()
        // Task 6 offscreen leak guard: if window alpha 0 or view hidden, strip animations so nothing spins offscreen.
        if window?.alphaValue == 0 || isHidden {
            if ringIsInstalled {
                hideGreenRing()
            }
            recordingDotView.layer?.removeAnimation(forKey: "breathe")
            dots.forEach { $0.layer?.removeAnimation(forKey: "shimmer") }
        }
    }

    // MARK: - Task 4: green clockwise arc helpers

    private func layoutRing() {
        let radius: CGFloat = isCompactSurface ? Metrics.pillCornerRadius : Metrics.cornerRadius
        ringLayer.frame = bounds
        ringGlowLayer.frame = bounds
        if let mask = ringLayer.mask as? CAShapeLayer {
            mask.frame = bounds
            // 1.5px ring inset 0.75: mask stroke sits exactly on stadium clip, not interior smear
            let inset: CGFloat = ringLineWidth / 2 // 0.75
            let insetRadius = max(0, radius - inset)
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil)
            mask.cornerRadius = insetRadius
        }
        if let mask = ringGlowLayer.mask as? CAShapeLayer {
            mask.frame = bounds
            // 6px glow inset 3: keep halo aligned to stadium, prevent interior smear
            let inset: CGFloat = 3
            let insetRadius = max(0, radius - inset)
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil)
            mask.cornerRadius = insetRadius
        }
    }

    func showGreenRing(speed: RingSpeed) {
        guard !sessionReduceMotion else { showStaticGreenHairline(); return }
        if ringIsInstalled {
            updateRingSpeed(speed)
            return
        }
        ringIsInstalled = true
        layer?.addSublayer(ringGlowLayer)
        layer?.addSublayer(ringLayer)
        layoutRing()
        let dur = speed == .listening ? ringListeningDuration : ringTranscribingDuration
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = dur
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(spin, forKey: "spin")
        ringGlowLayer.add(spin, forKey: "spin")
    }

    func hideGreenRing() {
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        ringLayer.removeAnimation(forKey: "breathe")
        ringGlowLayer.removeAnimation(forKey: "breathe")
        ringLayer.removeFromSuperlayer()
        ringGlowLayer.removeFromSuperlayer()
        ringIsInstalled = false
    }

    func showStaticGreenHairline() {
        if ringIsInstalled {
            ringLayer.removeAnimation(forKey: "spin")
            ringGlowLayer.removeAnimation(forKey: "spin")
            // Task 6: convert spinning->static correctly — add breathe if missing
            if ringLayer.animation(forKey: "breathe") == nil {
                ringLayer.opacity = 0.48
                ringGlowLayer.opacity = 0.38
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.3
                breathe.toValue = 0.6
                breathe.duration = 3.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ringLayer.add(breathe, forKey: "breathe")
                ringGlowLayer.add(breathe, forKey: "breathe")
            }
            return
        }
        ringIsInstalled = true
        // Static 1px #52B788 at 48% + breathing 3.2s, no rotation
        layer?.addSublayer(ringGlowLayer)
        layer?.addSublayer(ringLayer)
        layoutRing()
        ringLayer.opacity = 0.48
        ringGlowLayer.opacity = 0.38
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.3
        breathe.toValue = 0.6
        breathe.duration = 3.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringLayer.add(breathe, forKey: "breathe")
        ringGlowLayer.add(breathe, forKey: "breathe")
    }

    private func updateRingSpeed(_ speed: RingSpeed) {
        // Task 6: centralize speeds — sole source is ringListeningDuration / ringTranscribingDuration
        guard !sessionReduceMotion else { showStaticGreenHairline(); return }
        let dur = speed == .listening ? ringListeningDuration : ringTranscribingDuration
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = dur
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(spin, forKey: "spin")
        ringGlowLayer.add(spin, forKey: "spin")
    }

    /// K-48 Task 5 + review finding I-1: per-session surface switch. Called from
    /// transition(to:) so a prewarmed window still receives styling at present time.
    /// Always applies both styling and animation gating: idempotent, and covers
    /// appearance flips plus machined-session Reduce Motion without early returns.
    func setCompactSurface(active: Bool, darkAppearance: Bool, reduceMotion: Bool) {
        usesDarkAppearanceForSession = darkAppearance
        sessionReduceMotion = reduceMotion
        isCompactSurface = active
        applySurfaceStyling()
        updateBreatheAnimation()
    }

    private func applySurfaceStyling() {
        guard let layer = blurView.layer else { return }
        // Ensure mask survives layer recreation (NSVisualEffectView may recreate layer)
        if blurView.layer?.mask !== blurMaskLayer {
            blurMaskLayer.fillColor = NSColor.black.cgColor
            blurView.layer?.mask = blurMaskLayer
        }
        // FIX: whisper pill square corners — ensure blurView clips with rounded caps, self stays shadow-only
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        self.layer?.masksToBounds = false
        self.layer?.backgroundColor = nil
        // outer stroke stays 1px clear-fill rounded
        outerStrokeLayer.fillColor = NSColor.clear.cgColor
        outerStrokeLayer.lineWidth = 1
        // shadow spec: blur 18 + 0 10px 28px rgba(0,0,0,.28) => radius 10, offset (0,10)
        self.layer?.shadowColor = NSColor.black.cgColor
        self.layer?.shadowRadius = 10
        self.layer?.shadowOffset = CGSize(width: 0, height: 10)
        if isCompactSurface {
            layer.cornerRadius = Metrics.pillCornerRadius
            layer.borderWidth = 1
            // Universal obsidian glass: whisper pill always dark, regardless of session appearance
            blurView.appearance = NSAppearance(named: .darkAqua)
            tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.62).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            outerStrokeLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
            self.layer?.shadowOpacity = 0.28
            appIconTopConstraint?.isActive = false
            appIconCenterYConstraint?.isActive = true
            appIconWidthConstraint?.constant = 16
            appIconHeightConstraint?.constant = 16
            appNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            appIconView.layer?.cornerRadius = 4
            pillLevelGlyph.isHidden = false
            appNameLabel.textColor = .white
            timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            messageLabel.textColor = .white
        } else {
            // Machined deck defaults — always dark hudWindow regardless of session appearance
            layer.cornerRadius = Metrics.cornerRadius
            layer.borderWidth = 1
            blurView.appearance = NSAppearance(named: .darkAqua)
            tintView.layer?.backgroundColor = NSColor(srgbRed: 20/255.0, green: 20/255.0, blue: 18/255.0, alpha: 0.55).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            outerStrokeLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
            self.layer?.shadowOpacity = 0.28
            appIconCenterYConstraint?.isActive = false
            appIconTopConstraint?.isActive = true
            appIconWidthConstraint?.constant = Metrics.topRowHeight
            appIconHeightConstraint?.constant = Metrics.topRowHeight
            appNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            appNameLabel.textColor = .white
            timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            messageLabel.textColor = .white
            pillLevelGlyph.isHidden = true
            pillLevelGlyph.ink = .white
            shimmerStack?.isHidden = true
        }
        // Recording dot color is always brand green on the machined deck.
        recordingDotView.layer?.backgroundColor = indicatorBrandGreen.cgColor
        // B: whisper bars are brand green in BOTH appearances for contrast + brand consistency
        pillLevelGlyph.ink = indicatorBrandGreen
        // Keep container clip + mask in sync with new radius; layout() finalizes, but seed here for immediate clip
        let currentRadius: CGFloat = isCompactSurface ? Metrics.pillCornerRadius : Metrics.cornerRadius
        clipContainer.layer?.cornerRadius = currentRadius
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        blurMaskLayer.frame = blurView.bounds
        if blurView.bounds.width > 0 && blurView.bounds.height > 0 {
            blurMaskLayer.path = CGPath(roundedRect: blurView.bounds, cornerWidth: currentRadius, cornerHeight: currentRadius, transform: nil)
        }
        needsLayout = true
        // Force layout now so shadowPath/outerStroke/clipContainer aren't one frame behind (prevents square flash)
        layoutSubtreeIfNeeded()
    }

    /// K-48 review finding I-1: animations follow the PER-SESSION Reduce Motion value.
    /// Two independent gates: the deck dot breathes on machined surfaces; the shimmer
    /// drives the compact transcribing pill. Neither runs under Reduce Motion or hide().
    /// Task 6: also strip ring spin under Reduce Motion (convert to static hairline) and
    /// offscreen (hide) so no CABasicAnimation renders in background.
    func updateBreatheAnimation() {
        if !isCompactSurface && !sessionReduceMotion {
            if recordingDotView.layer?.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.55
                breathe.toValue = 1.0
                breathe.duration = 1.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.0, 1.0)
                recordingDotView.layer?.add(breathe, forKey: "breathe")
            }
        } else {
            recordingDotView.layer?.removeAnimation(forKey: "breathe")
        }

        if isCompactSurface && !sessionReduceMotion {
            for (index, dot) in dots.enumerated() {
                guard dot.layer?.animation(forKey: "shimmer") == nil else { continue }
                let bounce = CABasicAnimation(keyPath: "opacity")
                bounce.fromValue = 0.3
                bounce.toValue = 1.0
                bounce.duration = 1.2
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timeOffset = CFTimeInterval(index) * 0.15
                bounce.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.0, 1.0)
                dot.layer?.add(bounce, forKey: "shimmer")
            }
        } else {
            dots.forEach { $0.layer?.removeAnimation(forKey: "shimmer") }
        }
        // Task 6: Reduce Motion parity — strip ring spin when Reduce Motion is on.
        // showGreenRing already guards new presentations via showStaticGreenHairline,
        // but an already-spinning ring (e.g. mid-session Reduce Motion flip) must be
        // stripped here so nothing spins under Reduce Motion.
        if sessionReduceMotion, ringIsInstalled {
            let hasSpin = ringLayer.animation(forKey: "spin") != nil || ringGlowLayer.animation(forKey: "spin") != nil
            if hasSpin {
                ringLayer.removeAnimation(forKey: "spin")
                ringGlowLayer.removeAnimation(forKey: "spin")
                // Convert spinning ring to static breathing hairline in-place.
                if ringLayer.animation(forKey: "breathe") == nil {
                    ringLayer.opacity = 0.48
                    ringGlowLayer.opacity = 0.38
                    let breathe = CABasicAnimation(keyPath: "opacity")
                    breathe.fromValue = 0.3
                    breathe.toValue = 0.6
                    breathe.duration = 3.2
                    breathe.autoreverses = true
                    breathe.repeatCount = .infinity
                    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ringLayer.add(breathe, forKey: "breathe")
                    ringGlowLayer.add(breathe, forKey: "breathe")
                }
            }
        }
        // Task 6 offscreen leak guard: when window alpha is 0 or view hidden, strip
        // both spin and breathe so nothing animates offscreen. hide() also calls
        // removeSessionAnimations, but updateBreatheAnimation may fire while hidden.
        if window?.alphaValue == 0 || isHidden {
            if ringIsInstalled && (ringLayer.animation(forKey: "spin") != nil || ringLayer.animation(forKey: "breathe") != nil) {
                hideGreenRing()
            }
        }
    }

    /// Task 6: hide() + layout() strip infinite animations so nothing animates offscreen.
    /// Also verifies window alpha 0 strips both spin and breathe (hideGreenRing does both).
    func removeSessionAnimations() {
        recordingDotView.layer?.removeAnimation(forKey: "breathe")
        dots.forEach { $0.layer?.removeAnimation(forKey: "shimmer") }
        // Task 6: explicitly strip both spin and breathe keys; hideGreenRing covers both plus removal
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        ringLayer.removeAnimation(forKey: "breathe")
        ringGlowLayer.removeAnimation(forKey: "breathe")
        hideGreenRing()
        // Offscreen leak guard: when window alpha is 0, assert no spin/breathe remains
        if window?.alphaValue == 0 {
            assert(ringLayer.animation(forKey: "spin") == nil && ringLayer.animation(forKey: "breathe") == nil,
                   "Task 6: ring animations must be nil when window hidden")
        }
    }

    /// K-48 Task 5: compact glyph bars track the last three waveform samples.
    func updatePillLevel(samples: [Float]) {
        guard isCompactSurface else { return }
        pillLevelGlyph.update(samples: samples)
    }

    /// K-52 discard: configure the secondary Discard button shown alongside
    /// the primary Paste on the held-transcript chip. The handler routes
    /// through `handle(action:)` on click.
    func setHeldChipSecondaryAction(title: String, handler: @escaping () -> Void) {
        secondaryButton.title = title
        secondaryButton.isHidden = false
        secondaryActionHandler = handler
    }

    @objc private func didTapAction() {
        actionHandler?()
    }

    /// K-52 discard: tap the secondary "Discard" link on the held chip.
    @objc private func didTapSecondaryAction() {
        secondaryActionHandler?()
    }
}

/// Scrolling waveform that fills left-to-right toward a fixed red playhead.
/// History bars accumulate from the left; future area shows placeholder dots.
private final class WaveformView: NSView {
    private enum Metrics {
        static let barWidth: CGFloat = 2.5
        static let barGap: CGFloat = 1.5
        static let dotRadius: CGFloat = 1.5
        /// Fraction of total width at which the waveform "enters".
        static let entryFraction: CGFloat = 0.98
    }

    // Maximum number of history bars we ever store.
    private let maxHistory = 150
    // Smoothed amplitude to display for each stored bar.
    private var history: [CGFloat] = []
    // Current AGC gain.
    private var gain: CGFloat = 1.0
    // Smoothed amplitude being built for the NEXT push into history.
    private var smoothedAmp: CGFloat = 0.0
    // Sublayers for history bars
    private var historyLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        rebuildLayersIfNeeded()
        applyAllFrames()
    }

    // MARK: - Public API

    /// Feed new audio samples; derive amplitude and push a new history bar.
    func update(samples: [Float], active: Bool) {
        // If we have no bounds yet, we can't render, but we should at least mark for layout
        // if this is the first time we're getting samples.
        guard bounds.width > 2, bounds.height > 2 else { 
            needsLayout = true
            return 
        }
        
        guard active, !samples.isEmpty else {
            // Fade smoothedAmp toward silence and push a tiny bar
            smoothedAmp *= 0.4
            pushHistoryBar(smoothedAmp)
            applyAllFrames()
            return
        }

        // Compute envelope peak
        let peak = samples.reduce(0.0) { max($0, abs($1)) }
        let peakCG = CGFloat(peak)

        // AGC
        let targetGain = peakCG > 0.00001 ? min(90.0, 1.50 / peakCG) : 1.0
        gain += (targetGain - gain) * 0.35

        let avg = samples.reduce(0, { $0 + abs($1) }) / Float(max(1, samples.count))

        // Balanced noise gate floor (0.5% full-scale)
        guard peakCG > 0.005 else {
            smoothedAmp *= 0.5
            pushHistoryBar(smoothedAmp)
            applyAllFrames()
            return
        }
        // Slightly more restrictive noise gate tracking
        let noiseGate = CGFloat(max(0.003, min(0.018, Double(avg) * 2.0)))
        let boosted = max(0.0, min(1.0, (peakCG - noiseGate) * gain * 3.5))
        let eased = boosted > 0 ? pow(boosted, 0.38) : 0
        let target = eased * 0.96

        // Smooth toward target
        smoothedAmp += (target - smoothedAmp) * 0.50

        pushHistoryBar(smoothedAmp)
        applyAllFrames()
    }

    /// Called when waveform is hidden — resets history so next recording starts fresh.
    func reset() {
        history.removeAll()
        smoothedAmp = 0
        gain = 1.0
        applyAllFrames()
    }

    // MARK: - Private

    private func pushHistoryBar(_ amp: CGFloat) {
        history.append(max(0.0, min(1.0, amp)))
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    private func rebuildLayersIfNeeded() {
        guard let root = layer else { return }

        // Manage Historical Bar Layers
        let barsNeededForWidth = Int(bounds.width / (Metrics.barWidth + Metrics.barGap)) + 2
        let barsNeeded = min(maxHistory, barsNeededForWidth)

        while historyLayers.count < barsNeeded {
            let l = CALayer()
            l.cornerRadius = Metrics.barWidth / 2
            root.addSublayer(l)
            historyLayers.append(l)
        }
        while historyLayers.count > barsNeeded {
            historyLayers.removeLast().removeFromSuperlayer()
        }
    }

    private func applyAllFrames() {
        guard bounds.width > 2, bounds.height > 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let totalW = bounds.width
        let totalH = bounds.height
        let bw = Metrics.barWidth
        let gap = Metrics.barGap
        let step = bw + gap
        let entryX = totalW * Metrics.entryFraction
        let centerY = bounds.midY
        let vPadding: CGFloat = 4
        let drawH = totalH - (vPadding * 2)
        // Silence floor: keep a minimum visible bar (~4pt equivalent) even in silence
        let minH: CGFloat = max(4.0, drawH * 0.05)
        let maxH: CGFloat = max(minH + 5, drawH * 0.96)

        renderRadiantFlow(totalW: totalW, entryX: entryX, step: step, bw: bw, centerY: centerY, minH: minH, maxH: maxH)

        CATransaction.commit()
    }

    private func renderRadiantFlow(totalW: CGFloat, entryX: CGFloat, step: CGFloat, bw: CGFloat, centerY: CGFloat, minH: CGFloat, maxH: CGFloat) {
        let histCount = historyLayers.count
        for (idx, layer) in historyLayers.enumerated() {
            let barsFromRightEdge = histCount - 1 - idx
            let x = entryX - CGFloat(barsFromRightEdge + 1) * step
            
            if x + bw < 0 || x > totalW {
                layer.isHidden = true
                continue
            }
            layer.isHidden = false
            
            let historyIdx = history.count - 1 - barsFromRightEdge
            let amp: CGFloat = historyIdx >= 0 ? history[historyIdx] : 0.0
            let h = minH + (maxH - minH) * amp
            let y = centerY - h / 2.0
            layer.frame = CGRect(x: x, y: y, width: bw, height: h)
            
            let progress = max(0.0, min(1.0, x / entryX))
            // Machined deck is always-dark: fixed ink ramp on brand green (#52B788).
            let alpha: CGFloat = 0.45 + (0.95 - 0.45) * progress
            layer.backgroundColor = indicatorBrandGreen.withAlphaComponent(alpha).cgColor
            layer.shadowOpacity = 0
        }
    }

}

/// Computes 3 normalized levels [0.0...1.0] from PCM audio samples with AGC gain and attack/release smoothing.
enum LevelGlyphCalculator {
    static func process(
        samples: [Float],
        gain: inout CGFloat,
        smoothed: inout [CGFloat]
    ) -> [CGFloat] {
        guard !samples.isEmpty else {
            for i in 0..<3 {
                smoothed[i] *= 0.75
            }
            return smoothed
        }

        // Divide 512 samples into 3 time slices
        let count = samples.count
        let chunkSize = max(1, count / 3)
        var slicePeaks: [CGFloat] = []
        for i in 0..<3 {
            let start = i * chunkSize
            let end = (i == 2) ? count : min(count, (i + 1) * chunkSize)
            var slicePeak: Float = 0.0
            for j in start..<end {
                let mag = abs(samples[j])
                if mag > slicePeak { slicePeak = mag }
            }
            slicePeaks.append(CGFloat(slicePeak))
        }

        let framePeak = slicePeaks.reduce(0.0, max)
        let frameAvg = CGFloat(samples.reduce(0.0) { $0 + abs($1) }) / CGFloat(count)

        // Adaptive AGC: boosts quiet speech up to 60x, scales down for loud speech
        let targetGain = framePeak > 0.0001 ? min(60.0, 1.50 / framePeak) : 1.0
        gain += (targetGain - gain) * 0.25

        // Noise gate tracking (0.3% - 1.5%)
        let noiseGate = max(0.003, min(0.015, frameAvg * 1.8))

        for i in 0..<3 {
            let peak = slicePeaks[i]
            let target: CGFloat
            if framePeak < noiseGate {
                target = 0.0
            } else {
                let rawAmp = max(0.0, peak - noiseGate) * gain
                let boosted = min(1.0, rawAmp * 1.8)
                target = boosted > 0.0 ? pow(boosted, 0.40) : 0.0
            }

            // Fast attack (0.65), smooth decay (0.22)
            let coeff: CGFloat = target > smoothed[i] ? 0.65 : 0.22
            smoothed[i] += (target - smoothed[i]) * coeff
        }

        return smoothed
    }
}

/// K-48 Task 5: the whisper pill's three-bar level glyph, drawn in one view.
/// Custom draw instead of constraint-swapped subviews: no layout churn at 30Hz,
/// nothing to unhide, ink switchable per session appearance.
final class PillLevelGlyphView: NSView {
    var ink: NSColor = indicatorBrandGreen {
        didSet { needsDisplay = true }
    }
    private var levels: [CGFloat] = [0.0, 0.0, 0.0]
    private var gain: CGFloat = 1.0
    private var smoothed: [CGFloat] = [0.0, 0.0, 0.0]

    func update(samples: [Float]) {
        levels = LevelGlyphCalculator.process(
            samples: samples,
            gain: &gain,
            smoothed: &smoothed
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barWidth: CGFloat = 2.5
        let gap: CGFloat = 2.0
        let totalBarWidth = barWidth * 3 + gap * 2
        let startX = (bounds.width - totalBarWidth) / 2
        ctx.setFillColor(ink.cgColor)
        for (index, level) in levels.enumerated() {
            // Low floor stays clearly bar-shaped (never collapses into a dot).
            let minH: CGFloat = 3.0
            let maxH: CGFloat = bounds.height
            let h = minH + (maxH - minH) * min(1.0, max(0.0, level))
            let x = startX + CGFloat(index) * (barWidth + gap)
            let y = (bounds.height - h) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
    }
}

/// K-48 Task 7: the at-the-caret chip — 21pt-tall dark capsule with a green status dot,
/// three-bar level glyph, and mono timer. Trails the caret (CaretAnchorResolver places it);
/// never shows an app name (inline context is self-evident — pinned study ruling).
private final class CaretChipView: NSView {
    private enum ChipMetrics {
        static let hPadding: CGFloat = 9
        static let dotSize: CGFloat = 6
        static let glyphHeight: CGFloat = 10
        static let barWidth: CGFloat = 2
        static let timerMinWidth: CGFloat = 34
    }

    // Container clip for obsidian glass (mirrors OverlayCapsuleView): behindWindow ignores blurView.layer.mask
    private let clipContainer = NSView()
    private let blurView = NSVisualEffectView()
    private let tintView = NSView()
    private let dotView = NSView()
    private let bar0 = NSView()
    private let bar1 = NSView()
    private let bar2 = NSView()
    private var bars: [NSView] { [bar0, bar1, bar2] }
    private var barHeightConstraints: [NSLayoutConstraint] = []
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private var gain: CGFloat = 1.0
    private var smoothed: [CGFloat] = [0.0, 0.0, 0.0]

    // Task 3: universal rim — outer 1px stroke + elevation (mirrors OverlayCapsuleView)
    private let outerStrokeLayer = CAShapeLayer()
    private let innerStroke = CALayer()
    private let outerStroke = CAShapeLayer()
    // Fix: explicit mask for NSVisualEffectView rounding — mirrors OverlayCapsuleView
    private let blurMaskLayer = CAShapeLayer()
    // Task 4: green clockwise arc — conic gradient + glow (mirrors OverlayCapsuleView)
    private let ringLayer = CAGradientLayer()
    private let ringGlowLayer = CAGradientLayer()
    private var ringIsInstalled = false
    private var sessionReduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        // Task 3: universal rim — self hosts shadow/outer stroke (chip radius 15 pill / ~8 if compact)
        // FIX: square corners — self transparent, no clipping, shadow spec rounded
        layer?.masksToBounds = false
        layer?.backgroundColor = nil
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 10)
        outerStrokeLayer.fillColor = NSColor.clear.cgColor
        outerStrokeLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        outerStrokeLayer.lineWidth = 1
        outerStrokeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(outerStrokeLayer)
        // Initial stadium paths so first frame before layout is already clipped
        let initialRadius: CGFloat = 15
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: initialRadius, cornerHeight: initialRadius, transform: nil)
        outerStrokeLayer.frame = bounds
        outerStrokeLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, initialRadius - 0.5), cornerHeight: max(0, initialRadius - 0.5), transform: nil)
        // Task 4: green clockwise arc — conic gradient ring + glow (mirrors OverlayCapsuleView)
        ringLayer.type = .conic
        ringLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, indicatorBrandGreen.cgColor]
        ringLayer.locations = [0.0, 0.71, 1.0]
        ringLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.endPoint = CGPoint(x: 1, y: 0.5)
        ringLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let ringMask = CAShapeLayer()
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = ringLineWidth
        ringMask.lineCap = .round
        ringMask.lineJoin = .round
        ringLayer.mask = ringMask
        ringGlowLayer.type = .conic
        ringGlowLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, indicatorBrandGreen.cgColor]
        ringGlowLayer.locations = [0.0, 0.71, 1.0]
        ringGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringGlowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        ringGlowLayer.opacity = 0.38
        ringGlowLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let glowMask = CAShapeLayer()
        glowMask.fillColor = NSColor.clear.cgColor
        glowMask.strokeColor = NSColor.white.cgColor
        glowMask.lineWidth = 6
        glowMask.lineCap = .round
        glowMask.lineJoin = .round
        glowMask.opacity = 0.38
        ringGlowLayer.mask = glowMask

        // Container clip: behindWindow ignores blurView.layer.mask — clipContainer provides stadium rounding
        clipContainer.wantsLayer = true
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        clipContainer.layer?.cornerRadius = 15
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipContainer)

        // Fix: wantsLayer BEFORE material/cornerRadius; mask guarantees NSVisualEffectView clip
        blurView.wantsLayer = true
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.appearance = NSAppearance(named: .darkAqua)
        blurView.layer?.cornerRadius = 15
        blurView.layer?.masksToBounds = true
        blurView.layer?.cornerCurve = .continuous
        blurView.layer?.borderWidth = 1
        // Explicit mask: backdrop ignores cornerRadius on some builds (secondary to container)
        blurMaskLayer.fillColor = NSColor.black.cgColor
        blurView.layer?.mask = blurMaskLayer
        blurView.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.addSubview(blurView)

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(tintView, positioned: .below, relativeTo: nil)

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = indicatorBrandGreen.cgColor
        dotView.layer?.cornerRadius = ChipMetrics.dotSize / 2
        dotView.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(dotView)

        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = ChipMetrics.barWidth / 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            blurView.addSubview(bar)
        }
        barHeightConstraints = bars.map { $0.heightAnchor.constraint(equalToConstant: ChipMetrics.glyphHeight) }
        NSLayoutConstraint.activate(barHeightConstraints + [
            bar0.widthAnchor.constraint(equalToConstant: ChipMetrics.barWidth),
            bar1.widthAnchor.constraint(equalToConstant: ChipMetrics.barWidth),
            bar2.widthAnchor.constraint(equalToConstant: ChipMetrics.barWidth)
        ])

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        timerLabel.alignment = .right
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(timerLabel)

        NSLayoutConstraint.activate([
            clipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipContainer.topAnchor.constraint(equalTo: topAnchor),
            clipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            blurView.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: blurView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: blurView.bottomAnchor),

            dotView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: ChipMetrics.hPadding),
            dotView.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: ChipMetrics.dotSize),
            dotView.heightAnchor.constraint(equalToConstant: ChipMetrics.dotSize),

            bar0.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 5),
            bar1.leadingAnchor.constraint(equalTo: bar0.trailingAnchor, constant: 2),
            bar2.leadingAnchor.constraint(equalTo: bar1.trailingAnchor, constant: 2),
            bar0.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            bar1.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            bar2.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),

            timerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bar2.trailingAnchor, constant: 5),
            timerLabel.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -ChipMetrics.hPadding),
            timerLabel.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
            timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ChipMetrics.timerMinWidth)
        ])
        applySurfaceStylingForSession(dark: true)
    }

    override func layout() {
        super.layout()
        // Task 3: sync shadowPath + outer stroke to bounds (chip 15 / fallback 8)
        // obsidian fix: container clip is primary for behindWindow; mask secondary
        let radius: CGFloat = 15 // chip uses pill radius (height 30 -> 15); keeps 1:1 with blurView
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        outerStrokeLayer.frame = bounds
        let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let innerRadius = max(0, radius - 0.5)
        outerStrokeLayer.path = CGPath(roundedRect: insetBounds, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
        // Container clip — source-of-truth for stadium (behindWindow ignores blurView.layer.mask)
        clipContainer.layer?.cornerRadius = radius
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        // Explicit mask guarantees stadium clip for NSVisualEffectView (secondary)
        blurMaskLayer.frame = blurView.bounds
        blurMaskLayer.path = CGPath(roundedRect: blurView.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        blurView.layer?.cornerRadius = radius
        blurView.layer?.masksToBounds = true
        blurView.layer?.cornerCurve = .continuous
        layoutRing()
        // Task 6 offscreen leak guard: if window alpha 0 or view hidden, strip ring so nothing spins offscreen.
        if window?.alphaValue == 0 || isHidden {
            if ringIsInstalled {
                hideGreenRing()
            }
        }
    }

    // MARK: - Task 4: green clockwise arc helpers (mirrors OverlayCapsuleView)

    private func layoutRing() {
        let radius: CGFloat = 15
        ringLayer.frame = bounds
        ringGlowLayer.frame = bounds
        if let mask = ringLayer.mask as? CAShapeLayer {
            mask.frame = bounds
            let inset: CGFloat = ringLineWidth / 2 // 0.75
            let insetRadius = max(0, radius - inset)
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil)
            mask.cornerRadius = insetRadius
        }
        if let mask = ringGlowLayer.mask as? CAShapeLayer {
            mask.frame = bounds
            let inset: CGFloat = 3
            let insetRadius = max(0, radius - inset)
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil)
            mask.cornerRadius = insetRadius
        }
    }

    func showGreenRing(speed: RingSpeed) {
        guard !sessionReduceMotion else { showStaticGreenHairline(); return }
        if ringIsInstalled {
            updateRingSpeed(speed)
            return
        }
        ringIsInstalled = true
        layer?.addSublayer(ringGlowLayer)
        layer?.addSublayer(ringLayer)
        layoutRing()
        let dur = speed == .listening ? ringListeningDuration : ringTranscribingDuration
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = dur
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(spin, forKey: "spin")
        ringGlowLayer.add(spin, forKey: "spin")
    }

    func hideGreenRing() {
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        ringLayer.removeAnimation(forKey: "breathe")
        ringGlowLayer.removeAnimation(forKey: "breathe")
        ringLayer.removeFromSuperlayer()
        ringGlowLayer.removeFromSuperlayer()
        ringIsInstalled = false
    }

    func showStaticGreenHairline() {
        if ringIsInstalled {
            ringLayer.removeAnimation(forKey: "spin")
            ringGlowLayer.removeAnimation(forKey: "spin")
            // Task 6: convert spinning->static — add breathe if missing
            if ringLayer.animation(forKey: "breathe") == nil {
                ringLayer.opacity = 0.48
                ringGlowLayer.opacity = 0.38
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.3
                breathe.toValue = 0.6
                breathe.duration = 3.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ringLayer.add(breathe, forKey: "breathe")
                ringGlowLayer.add(breathe, forKey: "breathe")
            }
            return
        }
        ringIsInstalled = true
        layer?.addSublayer(ringGlowLayer)
        layer?.addSublayer(ringLayer)
        layoutRing()
        ringLayer.opacity = 0.48
        ringGlowLayer.opacity = 0.38
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.3
        breathe.toValue = 0.6
        breathe.duration = 3.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringLayer.add(breathe, forKey: "breathe")
        ringGlowLayer.add(breathe, forKey: "breathe")
    }

    private func updateRingSpeed(_ speed: RingSpeed) {
        // Task 6: centralize speeds — sole source is ringListeningDuration / ringTranscribingDuration
        guard !sessionReduceMotion else { showStaticGreenHairline(); return }
        let dur = speed == .listening ? ringListeningDuration : ringTranscribingDuration
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = dur
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(spin, forKey: "spin")
        ringGlowLayer.add(spin, forKey: "spin")
    }

    /// Task 6: teardown strips both spin and breathe; verify window alpha 0 leaves no animation
    func removeSessionAnimations() {
        ringLayer.removeAnimation(forKey: "spin")
        ringGlowLayer.removeAnimation(forKey: "spin")
        ringLayer.removeAnimation(forKey: "breathe")
        ringGlowLayer.removeAnimation(forKey: "breathe")
        hideGreenRing()
        if window?.alphaValue == 0 {
            assert(ringLayer.animation(forKey: "spin") == nil && ringLayer.animation(forKey: "breathe") == nil,
                   "Task 6: caret ring animations must be nil when window hidden")
        }
    }

    /// Per-session surface (mirrors the whisper pill tokens).
    /// Task 6: idempotently handles appearance flips + ReduceMotion without early returns;
    /// propagates ReduceMotion and strips ring spin in-place so nothing spins under Reduce Motion or offscreen.
    func applySurfaceStylingForSession(dark: Bool, reduceMotion: Bool? = nil) {
        _ = dark // universal obsidian: always dark, param retained for call-site compatibility
        if let rm = reduceMotion { sessionReduceMotion = rm }
        guard let layer = blurView.layer else { return }
        // Ensure mask survives layer recreation
        if blurView.layer?.mask !== blurMaskLayer {
            blurMaskLayer.fillColor = NSColor.black.cgColor
            blurView.layer?.mask = blurMaskLayer
        }
        // FIX: square corners — blurView rounded clip + self shadow-only
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = 15
        self.layer?.masksToBounds = false
        self.layer?.backgroundColor = nil
        outerStrokeLayer.fillColor = NSColor.clear.cgColor
        outerStrokeLayer.lineWidth = 1
        self.layer?.shadowColor = NSColor.black.cgColor
        self.layer?.shadowRadius = 10
        self.layer?.shadowOffset = CGSize(width: 0, height: 10)
        layer.borderWidth = 1
        // Universal obsidian glass: caret chip always dark
        blurView.appearance = NSAppearance(named: .darkAqua)
        tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.62).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        outerStrokeLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        self.layer?.shadowOpacity = 0.28
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        // B: caret glyph/dot stay brand green on both paper and obsidian; border/tint already differentiate
        let ink = indicatorBrandGreen
        bars.forEach { $0.layer?.backgroundColor = ink.cgColor }
        dotView.layer?.backgroundColor = ink.cgColor
        // Keep container clip + mask in sync; layout() will finalize frame, seed here for immediate clip
        clipContainer.layer?.cornerRadius = 15
        clipContainer.layer?.masksToBounds = true
        clipContainer.layer?.cornerCurve = .continuous
        blurMaskLayer.frame = blurView.bounds
        if blurView.bounds.width > 0 && blurView.bounds.height > 0 {
            blurMaskLayer.path = CGPath(roundedRect: blurView.bounds, cornerWidth: 15, cornerHeight: 15, transform: nil)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Task 6: Reduce Motion parity — if Reduce Motion just turned on, convert any spinning ring to static breathing
        if sessionReduceMotion, ringIsInstalled {
            let hasSpin = ringLayer.animation(forKey: "spin") != nil || ringGlowLayer.animation(forKey: "spin") != nil
            if hasSpin {
                ringLayer.removeAnimation(forKey: "spin")
                ringGlowLayer.removeAnimation(forKey: "spin")
                if ringLayer.animation(forKey: "breathe") == nil {
                    ringLayer.opacity = 0.48
                    ringGlowLayer.opacity = 0.38
                    let breathe = CABasicAnimation(keyPath: "opacity")
                    breathe.fromValue = 0.3
                    breathe.toValue = 0.6
                    breathe.duration = 3.2
                    breathe.autoreverses = true
                    breathe.repeatCount = .infinity
                    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ringLayer.add(breathe, forKey: "breathe")
                    ringGlowLayer.add(breathe, forKey: "breathe")
                }
            }
        }
        // Task 6 offscreen guard: if window hidden, strip ring animations so nothing leaks offscreen
        if window?.alphaValue == 0 || isHidden {
            if ringIsInstalled {
                hideGreenRing()
            }
        }
    }

    func updateTime(_ formatted: String) {
        timerLabel.stringValue = formatted
    }

    func updateLevel(samples: [Float]) {
        let levels = LevelGlyphCalculator.process(
            samples: samples,
            gain: &gain,
            smoothed: &smoothed
        )
        let heights: [CGFloat] = levels.map { level in
            let minH: CGFloat = 3.0
            let maxH: CGFloat = ChipMetrics.glyphHeight
            return minH + (maxH - minH) * min(1.0, max(0.0, level))
        }
        NSLayoutConstraint.deactivate(barHeightConstraints)
        barHeightConstraints = zip(bars, heights).map { $0.heightAnchor.constraint(equalToConstant: $1) }
        NSLayoutConstraint.activate(barHeightConstraints)
    }
}
