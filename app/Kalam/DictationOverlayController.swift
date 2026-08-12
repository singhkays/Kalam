import Foundation
import AppKit
import ApplicationServices

// MARK: - Dictation Overlay
@MainActor
final class DictationOverlayController {
    private enum Metrics {
        static let overlayWidth: CGFloat = 290
        static let compactHeight: CGFloat = 34
        static let recordingHeight: CGFloat = 72
        static let topInset: CGFloat = 20
        static let bottomInset: CGFloat = 16
    }

    enum OverlayAction {
        case openAccessibilitySettings
        case openMicrophoneSettings
        /// K-23: paste a held transcript into the current frontmost app (explicit user action).
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
    /// K-23: injected by the app — pastes a held transcript into the current frontmost app.
    private var pasteHeldTranscriptAction: (() -> Void)?
    private var recordingStartTime: CFAbsoluteTime = 0
    private var currentStateSetTime: CFAbsoluteTime = 0
    private let minStateDwellSeconds: Double = 0.25
    private let fadeDuration: TimeInterval = 0.18
    private let compactWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.compactHeight)
    private let recordingWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.recordingHeight)
    private var currentWindowSize = NSSize(width: Metrics.overlayWidth, height: Metrics.compactHeight)

    func setWaveformProvider(_ provider: @escaping () -> [Float]) {
        waveformProvider = provider
    }

    /// K-23: wire the held-transcript "Paste" action to the app (which owns the paste pipeline).
    func setPasteHeldTranscriptAction(_ action: @escaping () -> Void) {
        pasteHeldTranscriptAction = action
    }

    func showRecording(isHoldMode: Bool) {
        // Capture the frontmost app that will receive the pasted text.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetName = frontApp?.localizedName ?? ""
        let targetIcon = frontApp?.icon
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        let state: OverlayState = isHoldMode ? .recordingHold : .recordingToggle
        transition(to: state, lockAnchor: true, autoHideAfter: nil, targetAppName: targetName, targetAppIcon: targetIcon)
    }

    func showTranscribing() {
        transition(to: .transcribing, lockAnchor: false, autoHideAfter: nil)
    }

    func showSuccessAndAutoHide() {
        transition(to: .success, lockAnchor: false, autoHideAfter: 0.35)
    }

    func showInfoAndAutoHide(_ message: String) {
        transition(to: .info(message: message), lockAnchor: false, autoHideAfter: 0.7)
    }

    func showError(_ message: String, action: OverlayAction?, autoHideAfter: TimeInterval? = nil) {
        transition(to: .error(message: message, action: action), lockAnchor: false, autoHideAfter: autoHideAfter)
    }


    func hide() {
        stateTask?.cancel()
        stateTask = nil
        stopWaveformUpdates()
        stopTimerUpdates()
        placementScreen = nil
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

    private func transition(to state: OverlayState, lockAnchor: Bool, autoHideAfter: TimeInterval?,
                            targetAppName: String = "", targetAppIcon: NSImage? = nil) {
        stateTask?.cancel()
        stateTask = nil
        ensureWindow()
        let showsWaveform = isRecordingState(state)
        currentWindowSize = showsWaveform ? recordingWindowSize : compactWindowSize
        if lockAnchor || placementScreen == nil {
            placementScreen = resolvePlacementScreen() ?? placementScreen ?? fallbackScreen()
        }
        if let screen = placementScreen ?? fallbackScreen() {
            positionWindow(on: screen)
        }
        guard let w = window, let view = contentView else { return }
        view.setWaveformVisible(showsWaveform)
        currentStateSetTime = CFAbsoluteTimeGetCurrent()
        let presentation = presentation(for: state, targetAppName: targetAppName, targetAppIcon: targetAppIcon)
        view.apply(presentation: presentation)
        w.alphaValue = 0.0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
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
        let preset = GeneralSettingsConfiguration.load().indicatorPlacementPreset
        let frame = frameForPreset(preset, visibleFrame: screenFrame)
        w.setFrame(frame, display: false)
    }

    private func frameForPreset(_ preset: IndicatorPlacementPreset, visibleFrame: CGRect) -> CGRect {
        let ww = currentWindowSize.width
        let wh = currentWindowSize.height
        let maxX = visibleFrame.maxX - ww
        let maxY = visibleFrame.maxY - wh
        let centeredX = visibleFrame.midX - (ww * 0.5)
        let clampedCenterX = max(visibleFrame.minX, min(centeredX, maxX))

        let origin: CGPoint
        switch preset {
        case .topCenter:
            origin = CGPoint(x: clampedCenterX, y: max(visibleFrame.minY, min(maxY - Metrics.topInset, maxY)))
        case .bottomCenter:
            let y = max(visibleFrame.minY, min(visibleFrame.minY + Metrics.bottomInset, maxY))
            origin = CGPoint(x: clampedCenterX, y: y)
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

    private func resolvePlacementScreen() -> NSScreen? {
        guard AXIsProcessTrusted(),
              let element = focusedAXElement(),
              let frame = frameOfAXElement(element) else {
            return fallbackScreen()
        }
        let appKitRect = flipAXRect(frame)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? fallbackScreen()
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
        static let cornerRadius: CGFloat = 12
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
    private let timerLabel = NSTextField(labelWithString: "00:00")

    // Waveform
    private let waveformView = WaveformView(frame: .zero)

    private var actionHandler: (() -> Void)?
    private var waveformTopConstraint: NSLayoutConstraint?
    private var waveformHeightConstraint: NSLayoutConstraint?
    private var recordingRowTopConstraint: NSLayoutConstraint?
    private var recordingRowHeightConstraint: NSLayoutConstraint?
    private var messageLabelTopConstraint: NSLayoutConstraint?

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
            timerLabel.isHidden = false
            messageLabel.isHidden = true
            actionButton.isHidden = true

            // App info
            if let icon = presentation.targetAppIcon {
                appIconView.image = icon
            } else {
                appIconView.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            appNameLabel.stringValue = presentation.targetAppName.isEmpty ? "App" : presentation.targetAppName
            timerLabel.stringValue = "00:00"
        } else {
            // Standard compact row
            appIconView.isHidden = true
            appNameLabel.isHidden = true
            timerLabel.isHidden = true
            messageLabel.isHidden = false
            messageLabel.stringValue = presentation.message
            actionHandler = presentation.action
            if let title = presentation.actionTitle {
                actionButton.title = title
                actionButton.isHidden = false
            } else {
                actionButton.isHidden = true
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
        blurView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        // Dark tint layer — more translucent for a grey look
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        blurView.addSubview(tintView, positioned: .below, relativeTo: nil)

        // ── Rainbow Gradient Border (Static Mask + Rotating Colors) ──
        let maskContainer = CALayer()
        maskContainer.masksToBounds = true
        blurView.layer?.addSublayer(maskContainer)
        self.gradientContainerLayer = maskContainer

        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            NSColor(red: 1.00, green: 0.50, blue: 0.20, alpha: 0.9).cgColor, // Vibrant Orange
            NSColor(red: 0.40, green: 1.00, blue: 0.40, alpha: 0.9).cgColor, // Vibrant Green
            NSColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 0.9).cgColor, // Vibrant Blue
            NSColor(red: 0.80, green: 0.40, blue: 1.00, alpha: 0.9).cgColor, // Vibrant Purple
            NSColor(red: 1.00, green: 0.50, blue: 0.20, alpha: 0.9).cgColor  // Loop back
        ]
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        maskContainer.addSublayer(gradientLayer)
        self.gradientBorderLayer = gradientLayer

        // Glow effect on the container (visible through the mask)
        maskContainer.shadowColor = NSColor.white.cgColor
        maskContainer.shadowOffset = .zero
        maskContainer.shadowRadius = 4.0
        maskContainer.shadowOpacity = 0.5

        let shapeLayer = CAShapeLayer()
        shapeLayer.lineWidth = 2.0
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = NSColor.black.cgColor // Mask color
        maskContainer.mask = shapeLayer
        self.gradientShapeLayer = shapeLayer

        // Constant clockwise rotation animation on the gradient colors
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 3.5
        rotation.repeatCount = .infinity
        gradientLayer.add(rotation, forKey: "rotateColors")

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

        // Timer — monospaced digits, right-aligned
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        timerLabel.alignment = .right
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.isHidden = true
        blurView.addSubview(timerLabel)

        // Waveform
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.wantsLayer = true
        waveformView.layer?.zPosition = 100 // Ensure it's on top of everything including rainbow border
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
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timerLabel.leadingAnchor, constant: -8),

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
    }

    private var gradientContainerLayer: CALayer?
    private var gradientBorderLayer: CAGradientLayer?
    private var gradientShapeLayer: CAShapeLayer?

    override func layout() {
        super.layout()
        if let container = gradientContainerLayer, let gradient = gradientBorderLayer, let shape = gradientShapeLayer {
            container.frame = blurView.bounds
            
            // Gradient is a square larger than the capsule so it can rotate without gaps
            let side = max(blurView.bounds.width, blurView.bounds.height) * 1.5
            gradient.frame = CGRect(x: (blurView.bounds.width - side) / 2, y: (blurView.bounds.height - side) / 2, width: side, height: side)
            
            let path = NSBezierPath(roundedRect: blurView.bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
            shape.path = path.cgPath
            shape.frame = blurView.bounds
        }
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
        // Reduced minH slightly for a cleaner look in silence
        let minH: CGFloat = max(2.0, drawH * 0.05)
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
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let minAlpha: CGFloat = isDark ? 0.45 : 0.18
            let maxAlpha: CGFloat = isDark ? 0.95 : 0.40
            let alpha = minAlpha + (maxAlpha - minAlpha) * progress
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            layer.shadowOpacity = 0
        }
    }

}
