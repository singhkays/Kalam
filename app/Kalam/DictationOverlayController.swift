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

    /// K-48 Task 5: whisper (and later caret) render listening/transcribing as the compact pill.
    private func usesCompactSurface(for state: OverlayState) -> Bool {
        guard sessionStyle != .machined,
              let mapped = indicatorState(for: state),
              IndicatorStateModel.usesCompactSurface(style: sessionStyle, state: mapped) else { return false }
        // Caret reuses pill sizing until Task 7 differentiates its chip window.
        return true
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
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopTimerUpdates() {
        timerTask?.cancel()
        timerTask = nil
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

    // K-48 Task 5: whisper pill — three-bar level glyph + transcribing shimmer dots.
    private let pillLevelBar0 = NSView()
    private let pillLevelBar1 = NSView()
    private let pillLevelBar2 = NSView()
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
    private var pillBarHeightConstraints: [NSLayoutConstraint] = []
    private var pillLevelStack: NSStackView?
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
            recordingDotView.isHidden = false
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
            pillLevelStack?.isHidden = !isCompactSurface
        } else {
            // Standard compact row
            appIconView.isHidden = true
            appNameLabel.isHidden = true
            recordingDotView.isHidden = true
            timerLabel.isHidden = true
            pillLevelStack?.isHidden = true
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

    /// K-48 Task 5: builds the pill-only chrome (level glyph bars, shimmer dots) and
    /// pill-specific layout adjustments. Hidden by default; the machined deck stays
    /// the default surface until setCompactSurface(active:) flips the session style.
    private func setupPillChrome() {
        let barViews = [pillLevelBar0, pillLevelBar1, pillLevelBar2]
        for bar in barViews {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = Metrics.pillBarWidth / 2
            bar.layer?.masksToBounds = false
            bar.isHidden = true
            blurView.addSubview(bar)
        }
        NSLayoutConstraint.activate([
            pillLevelBar0.widthAnchor.constraint(equalToConstant: Metrics.pillBarWidth),
            pillLevelBar1.widthAnchor.constraint(equalToConstant: Metrics.pillBarWidth),
            pillLevelBar2.widthAnchor.constraint(equalToConstant: Metrics.pillBarWidth)
        ])
        // Heights start pinned and are later replaced by updatePillLevel(sample:) —
        // the active set is tracked in pillBarHeightConstraints so they swap cleanly.
        pillBarHeightConstraints = [pillLevelBar0, pillLevelBar1, pillLevelBar2].map {
            $0.heightAnchor.constraint(equalToConstant: Metrics.pillGlyphHeight)
        }
        NSLayoutConstraint.activate(pillBarHeightConstraints)
        pillLevelStack = NSStackView(views: barViews)
        if let stack = pillLevelStack {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 2.5
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.isHidden = true
            blurView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: blurView.centerYAnchor),
                stack.trailingAnchor.constraint(equalTo: timerLabel.leadingAnchor, constant: -8)
            ])
        }

        let dots = [shimmerDot0, shimmerDot1, shimmerDot2]
        for (index, dot) in dots.enumerated() {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = indicatorBrandGreen.cgColor
            dot.layer?.cornerRadius = Metrics.shimmerDotSize / 2
            dot.alphaValue = 0.35
            dot.isHidden = true
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
    func setCompactSurface(active: Bool, darkAppearance: Bool, reduceMotion: Bool) {
        usesDarkAppearanceForSession = darkAppearance
        sessionReduceMotion = reduceMotion
        if active {
            // Re-apply on every transition: cheap, idempotent, and covers appearance flips.
            applySurfaceStyling()
            updateBreatheAnimation()
        } else if isCompactSurface {
            isCompactSurface = false
        }
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
            pillLevelStack?.isHidden = false
            refreshPillBarColors()
        } else {
            // Machined deck defaults.
            layer.cornerRadius = Metrics.cornerRadius
            tintView.layer?.backgroundColor = NSColor(srgbRed: 20/255.0, green: 20/255.0, blue: 18/255.0, alpha: 0.55).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            appNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            pillLevelStack?.isHidden = true
            shimmerStack?.isHidden = true
        }
        // Recording dot color follows the surface ink in light appearance.
        recordingDotView.layer?.backgroundColor =
            isCompactSurface && !usesDarkAppearanceForSession ? NSColor.black.cgColor : indicatorBrandGreen.cgColor
    }

    private func refreshPillBarColors() {
        let ink = usesDarkAppearanceForSession ? indicatorBrandGreen : NSColor.black
        [pillLevelBar0, pillLevelBar1, pillLevelBar2].forEach { $0.layer?.backgroundColor = ink.cgColor }
    }

    /// K-48 review finding I-1: the dot's breathing animation follows the PER-SESSION
    /// Reduce Motion value (captured in showRecording), not a one-time app-lifetime check.
    func updateBreatheAnimation() {
        if isCompactSurface || sessionReduceMotion {
            recordingDotView.layer?.removeAnimation(forKey: "breathe")
            dots.forEach { $0.layer?.removeAnimation(forKey: "shimmer") }
            return
        }
        guard recordingDotView.layer?.animation(forKey: "breathe") == nil else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1.0
        breathe.duration = 1.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.0, 1.0)
        recordingDotView.layer?.add(breathe, forKey: "breathe")
        for (index, dot) in dots.enumerated() {
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
    }

    /// K-48 Task 5: compact glyph bars track the last three waveform samples.
    func updatePillLevel(samples: [Float]) {
        guard isCompactSurface else { return }
        let values = samples.suffix(3)
        let heights: [CGFloat] = (0..<3).map { index in
            guard !values.isEmpty else { return 4 }
            let v = values[min(index, values.count - 1)]
            return 4 + CGFloat(max(0, min(1, v))) * (Metrics.pillGlyphHeight - 4)
        }
        NSLayoutConstraint.deactivate(pillBarHeightConstraints)
        pillBarHeightConstraints = zip([pillLevelBar0, pillLevelBar1, pillLevelBar2], heights).map { bar, height in
            bar.heightAnchor.constraint(equalToConstant: height)
        }
        NSLayoutConstraint.activate(pillBarHeightConstraints)
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
