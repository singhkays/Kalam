import Foundation
import AppKit
import ApplicationServices

/// K-48 machined palette: brand green #52B788.
private let indicatorBrandGreen = NSColor(srgbRed: 82/255.0, green: 183/255.0, blue: 136/255.0, alpha: 1.0)

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


    func hide() {
        stateTask?.cancel()
        stateTask = nil
        stopWaveformUpdates()
        stopTimerUpdates()
        caretAnchorElement = nil
        hideCaretChip()
        // Quality review: strip infinite CAAnimations while hidden so nothing
        // renders in the background between sessions.
        contentView?.removeSessionAnimations()
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
        if compact {
            let mapped = indicatorState(for: state) ?? .listening
            currentWindowSize = NSSize(width: IndicatorStateModel.compactWidth(state: mapped), height: Metrics.pillHeight)
        } else {
            currentWindowSize = showsWaveform ? recordingWindowSize : compactWindowSize
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
        currentStateSetTime = CFAbsoluteTimeGetCurrent()
        let presentation = presentation(for: state, targetAppName: targetAppName, targetAppIcon: targetAppIcon)
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
        } else if !chipVisibleNow && chipVisibleBefore {
            // Anchor died mid-recording: restore the deck, never indicator-less.
            window?.alphaValue = 1.0
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
        chipView.applySurfaceStylingForSession(dark: sessionUsesDarkAppearance)
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
        var targetAppName: String = ""
        var targetAppIcon: NSImage? = nil
        var isRecording: Bool = false
    }

    // Shared subviews
    private let blurView = NSVisualEffectView()
    private let tintView = NSView()

    // Non-recording row
    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)

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
    private var waveformTopConstraint: NSLayoutConstraint?
    private var waveformHeightConstraint: NSLayoutConstraint?
    private var recordingRowTopConstraint: NSLayoutConstraint?
    private var recordingRowHeightConstraint: NSLayoutConstraint?
    private var messageLabelTopConstraint: NSLayoutConstraint?

    // K-48 Task 5: whisper pill — per-session surface + compact glyph.
    private var isCompactSurface = false {
        didSet { applySurfaceStyling() }
    }
    private var usesDarkAppearanceForSession = true
    private var sessionReduceMotion = false
    private var shimmerStack: NSStackView?
    private var dots: [NSView] { [shimmerDot0, shimmerDot1, shimmerDot2] }

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
            recordingDotView.isHidden = !isCompactSurface
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
                if let title = presentation.actionTitle {
                    actionButton.title = title
                    actionButton.isHidden = false
                } else {
                    actionButton.isHidden = true
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

        // Blur background — dark material, higher translucency
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.alphaValue = 1.0
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = Metrics.cornerRadius
        blurView.layer?.masksToBounds = true
        blurView.layer?.borderWidth = 0.5
        blurView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

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

        // ── Recording-mode top row ──
        // App icon
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = 4
        appIconView.layer?.masksToBounds = true
        appIconView.isHidden = true
        blurView.addSubview(appIconView)

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
            // Blur fills capsule
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

            // Recording top row — icon
            appIconView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: Metrics.hPadding),
            appIconView.topAnchor.constraint(equalTo: blurView.topAnchor, constant: Metrics.topRowTopPadding),
            appIconView.widthAnchor.constraint(equalToConstant: Metrics.topRowHeight),
            appIconView.heightAnchor.constraint(equalToConstant: Metrics.topRowHeight),

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
        if isCompactSurface {
            layer.cornerRadius = Metrics.pillCornerRadius
            if usesDarkAppearanceForSession {
                tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.62).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            } else {
                tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.74).cgColor
                layer.borderColor = NSColor.black.withAlphaComponent(0.13).cgColor
            }
            appNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            appIconView.layer?.cornerRadius = 4
            pillLevelGlyph.isHidden = false
            // Review gap 4: light-appearance pill needs dark-on-light label ink.
            let nameInk = usesDarkAppearanceForSession ? NSColor.white : NSColor.black
            appNameLabel.textColor = nameInk
            timerLabel.textColor = usesDarkAppearanceForSession
                ? NSColor.white.withAlphaComponent(0.55)
                : NSColor.black.withAlphaComponent(0.65)
            // Re-review residual: the transcribing pill's message label needs the same treatment.
            messageLabel.textColor = usesDarkAppearanceForSession
                ? NSColor.white
                : NSColor.black.withAlphaComponent(0.85)
        } else {
            // Machined deck defaults.
            layer.cornerRadius = Metrics.cornerRadius
            tintView.layer?.backgroundColor = NSColor(srgbRed: 20/255.0, green: 20/255.0, blue: 18/255.0, alpha: 0.55).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            appNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            appNameLabel.textColor = .white
            timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            messageLabel.textColor = .white
            pillLevelGlyph.isHidden = true
            pillLevelGlyph.ink = .white
            shimmerStack?.isHidden = true
        }
        // Recording dot color follows the surface ink in light appearance.
        recordingDotView.layer?.backgroundColor =
            isCompactSurface && !usesDarkAppearanceForSession ? NSColor.black.cgColor : indicatorBrandGreen.cgColor
        // Glyph ink follows the surface too.
        pillLevelGlyph.ink = isCompactSurface && !usesDarkAppearanceForSession ? NSColor.black : indicatorBrandGreen
    }

    /// K-48 review finding I-1: animations follow the PER-SESSION Reduce Motion value.
    /// Two independent gates: the deck dot breathes on machined surfaces; the shimmer
    /// drives the compact transcribing pill. Neither runs under Reduce Motion or hide().
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
    }

    /// Quality review: hide() strips infinite animations so nothing animates offscreen.
    func removeSessionAnimations() {
        recordingDotView.layer?.removeAnimation(forKey: "breathe")
        dots.forEach { $0.layer?.removeAnimation(forKey: "shimmer") }
    }

    /// K-48 Task 5: compact glyph bars track the last three waveform samples.
    func updatePillLevel(samples: [Float]) {
        guard isCompactSurface else { return }
        pillLevelGlyph.update(samples: samples)
    }

    @objc private func didTapAction() {
        actionHandler?()
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

/// K-48 Task 5: the whisper pill's three-bar level glyph, drawn in one view.
/// Custom draw instead of constraint-swapped subviews: no layout churn at 30Hz,
/// nothing to unhide, ink switchable per session appearance.
final class PillLevelGlyphView: NSView {
    var ink: NSColor = indicatorBrandGreen {
        didSet { needsDisplay = true }
    }
    private var levels: [CGFloat] = [0.3, 0.6, 0.45]
    /// Running peak with slow decay — mirrors the deck waveform's AGC so normal
    /// speech (~0.02-0.05 raw) renders as full bars instead of dots.
    private var referencePeak: CGFloat = 0.08
    /// Smoothed display values. Fast attack / slow release gives the fluid
    /// mockup motion instead of instant spike-and-snap-back.
    private var smoothed: [CGFloat] = [0.3, 0.6, 0.45]

    func update(samples: [Float]) {
        // ArraySlice keeps parent indices — index via startIndex offset.
        let values = samples.suffix(3)
        var framePeak: CGFloat = 0
        var targets: [CGFloat] = []
        for index in 0..<3 {
            guard !values.isEmpty else { targets.append(0.08); continue }
            let v = values[values.startIndex + min(index, values.count - 1)]
            framePeak = max(framePeak, CGFloat(v))
            targets.append(CGFloat(max(0, min(1, v))))
        }
        // Slow peak decay (2%/tick) so loud phrases set the ceiling for a while.
        referencePeak = max(framePeak, referencePeak * 0.98, 0.02)
        // Per-bar attack/release: rise quickly with the voice, fall gently after.
        for index in 0..<3 {
            let normalized = min(1, targets[index] / referencePeak)
            let coefficient = normalized > smoothed[index] ? CGFloat(0.5) : CGFloat(0.15)
            smoothed[index] += (normalized - smoothed[index]) * coefficient
        }
        levels = smoothed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barWidth: CGFloat = 2.5
        let gap: CGFloat = 2
        let totalBarWidth = barWidth * 3 + gap * 2
        let startX = (bounds.width - totalBarWidth) / 2
        ctx.setFillColor(ink.cgColor)
        for (index, level) in levels.enumerated() {
            // Low floor stays clearly bar-shaped (never collapses into a dot).
            let h = bounds.height * max(0.14, min(1, level))
            let x = startX + CGFloat(index) * (barWidth + gap)
            let rect = CGRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
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

    private let blurView = NSVisualEffectView()
    private let tintView = NSView()
    private let dotView = NSView()
    private let bar0 = NSView()
    private let bar1 = NSView()
    private let bar2 = NSView()
    private var bars: [NSView] { [bar0, bar1, bar2] }
    private var barHeightConstraints: [NSLayoutConstraint] = []
    private let timerLabel = NSTextField(labelWithString: "00:00")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 15
        blurView.layer?.masksToBounds = true
        blurView.layer?.borderWidth = 0.5
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

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
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    /// Per-session surface (mirrors the whisper pill tokens).
    func applySurfaceStylingForSession(dark: Bool) {
        guard let layer = blurView.layer else { return }
        if dark {
            tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.62).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            timerLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        } else {
            tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.74).cgColor
            layer.borderColor = NSColor.black.withAlphaComponent(0.13).cgColor
            timerLabel.textColor = NSColor.black.withAlphaComponent(0.65)
        }
        // B: caret glyph/dot stay brand green on both paper and obsidian; border/tint already differentiate
        let ink = indicatorBrandGreen
        bars.forEach { $0.layer?.backgroundColor = ink.cgColor }
        dotView.layer?.backgroundColor = ink.cgColor
    }

    func updateTime(_ formatted: String) {
        timerLabel.stringValue = formatted
    }

    func updateLevel(samples: [Float]) {
        // ArraySlice keeps parent indices — index via startIndex offset, never raw 0-based.
        let values = samples.suffix(3)
        let heights: [CGFloat] = (0..<3).map { index in
            guard !values.isEmpty else { return 3 }
            let v = values[values.startIndex + min(index, values.count - 1)]
            return 3 + CGFloat(max(0, min(1, v))) * (ChipMetrics.glyphHeight - 3)
        }
        NSLayoutConstraint.deactivate(barHeightConstraints)
        barHeightConstraints = zip(bars, heights).map { $0.heightAnchor.constraint(equalToConstant: $1) }
        NSLayoutConstraint.activate(barHeightConstraints)
    }
}
