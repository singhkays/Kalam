import Foundation
import AppKit
import ApplicationServices
import SwiftUI
import OSLog

/// Xcode-console diagnostics for the indicator ring/shimmer (geometry + flags only,
/// never transcript content). `.debug` level: visible when run from Xcode.
private let indicatorDiag = Logger(subsystem: "singhkays.Kalam", category: "Indicator")

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
        case openKeyboardSettings
        /// record-time paste target capture: paste a held transcript into the current frontmost app (explicit user action).
        case pasteHeldTranscript
        /// K-52 discard: drop a held transcript without delivering it.
        case destroyHeldTranscript
    }

    private enum OverlayState {
        case recordingHold
        case recordingToggle
        case transcribing
        case info(message: String)
        case error(message: String, action: OverlayAction?)
    }

    /// Presentation value built per transition and published to the SwiftUI
    /// surfaces. Formerly nested on the deleted OverlayCapsuleView; promoted
    /// here at the Phase 4 cutover.
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

    private var window: NSWindow?
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
    /// Phase 2/3: published presentation for the (sole) SwiftUI surfaces.
    private let presentationState = IndicatorPresentationState()
    private var capsuleHostingView: NSHostingView<IndicatorCapsuleRootView>?
    private var chipHostingView: NSHostingView<IndicatorChipRootView>?

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
        // K-52: the held notice must show its full message + Paste + Discard row
        // (never clipped). The AppKit path measured this with Auto Layout
        // fittingSize; the SwiftUI surfaces measure via the tokens' point sizes.
        let intended = Self.heldRowWidth(
            message: message,
            primaryTitle: "Paste",
            secondaryTitle: "Discard")
        guard let w = window, intended > w.frame.width else { return }
        let screen = placementScreen ?? fallbackScreen()
        let maxW = (screen?.visibleFrame.width ?? Metrics.overlayWidth) * 0.7
        let width = min(max(intended, Metrics.overlayWidth), maxW)
        w.setContentSize(NSSize(width: width, height: Metrics.compactHeight))
        if let s = screen { positionWindow(on: s) }
    }

    /// Text measurement for the held-transcript grow, using the same point
    /// sizes as IndicatorTokens (deck message 13pt semibold, buttons 11pt
    /// semibold) plus row padding, so the window fits the full line exactly
    /// where Auto Layout used to decide it.
    private static func heldRowWidth(message: String, primaryTitle: String?, secondaryTitle: String?) -> CGFloat {
        let messageFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let buttonFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var width = (message as NSString).size(withAttributes: [.font: messageFont]).width
        width += 2 * 12 // horizontal padding (IndicatorTokens.hPadding)
        if let secondaryTitle {
            width += ((secondaryTitle as NSString).size(withAttributes: [.font: buttonFont]).width) + 12
        }
        if let primaryTitle {
            width += ((primaryTitle as NSString).size(withAttributes: [.font: buttonFont]).width) + 16
        }
        return ceil(width)
    }

    func hide() {
        stateTask?.cancel()
        stateTask = nil
        stopWaveformUpdates()
        stopTimerUpdates()
        caretAnchorElement = nil
        hideCaretChip()
        // No session-scoped CAAnimation teardown needed: the SwiftUI surfaces
        // carry no infinitely-running Core Animation layers (animations are
        // view-lifetime scoped there); the old hideGreenRing/
        // removeSessionAnimations guards belonged to the deleted AppKit views.
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
        guard let w = window else { return }
        // Corner-halo geometry diagnostics removed (hunt is over): re-add behind
        // KalamDiagnosticFlags.verboseAudio if window geometry is ever suspect again.
        // K-48 Task 7: when the caret chip owns feedback, the corner window stays hidden
        // but BOTH feedback loops still run — they drive the chip's clock, level glyph,
        // and 500ms re-anchoring. If anchoring fails, the fallback law applies: hide the
        // chip attempt and let the machined deck take the state (review R1/R3).
        if caretChipOwnsFeedback(for: state) {
            updateCaretChip(state: state, element: caretAnchorElement)
            if caretChipWindow?.isVisible == true {
                // Chip is live: corner window stays hidden; loops drive clock/levels/re-anchor.
                // Ring law lives in IndicatorTokens (transcribing-only) and the
                // published state — no per-view ring calls anymore.
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
        currentStateSetTime = CFAbsoluteTimeGetCurrent()
        // overlay action buttons unclickable: the overlay is click-through EXCEPT while an actionable state
        // (held-transcript "Paste", error "Open") is presented — with
        // ignoresMouseEvents stuck on, those buttons can never be clicked.
        w.ignoresMouseEvents = (presentation.action == nil)
        publish(to: presentationState, overlayState: state, presentation: presentation)
        // Telemetry (DEBUG, Xcode console): confirms the transition reached the
        // SwiftUI surfaces. The ring/glow law is the published state's: ringPeriod
        // is non-nil only for transcribing; listening/pausing/held/blocked
        // carry no ring and no glow in ANY style (owner ruling 2026-09-09).
        let canonical = indicatorState(for: state)
        let ringOn = IndicatorTokens.ringPeriod(style: sessionStyle, canonicalState: canonical) != nil
        let glowOn = IndicatorTokens.ringGlowVisible(style: sessionStyle, canonicalState: canonical)
        indicatorDiag.debug("SwiftUI indicator presented style=\(self.sessionStyle.rawValue, privacy: .public) state=\(String(describing: canonical), privacy: .public) ring=\(ringOn, privacy: .public) glow=\(glowOn, privacy: .public)")
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
            presentationState.waveform.reset()
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
        case .info, .error: return nil
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
                              targetAppIcon: NSImage? = nil) -> Presentation {
        switch state {
        case .recordingHold:
            return .init(message: "Release to stop", actionTitle: nil, action: nil,
                         targetAppName: targetAppName, targetAppIcon: targetAppIcon, isRecording: true)
        case .recordingToggle:
            return .init(message: "Tap hotkey to stop", actionTitle: nil, action: nil,
                         targetAppName: targetAppName, targetAppIcon: targetAppIcon, isRecording: true)
        case .transcribing:
            return .init(message: "Transcribing…", actionTitle: nil, action: nil)
        case .info(let message):
            return .init(message: message, actionTitle: nil, action: nil)
        case .error(let message, let action):
            // K-52 held chip: the Discard link belongs to the held presentation
            // itself (pasteHeldTranscript), so the published state always
            // carries Paste + Discard — the old AppKit-only side channel
            // (setHeldChipSecondaryAction after apply) never reached SwiftUI.
            if action == .pasteHeldTranscript {
                return .init(
                    message: message,
                    actionTitle: actionTitle(for: action),
                    action: { [weak self] in
                        self?.handle(action: action)
                    },
                    secondaryActionTitle: "Discard",
                    secondaryAction: { [weak self] in
                        self?.handle(action: .destroyHeldTranscript)
                    })
            }
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
        case .openKeyboardSettings:
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
        case .openKeyboardSettings:
            _ = SystemSettingsNavigator.open(.keyboard)
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
                    self.presentationState.waveform.ingest(samples: samples, active: true)
                    self.presentationState.waveform.ingestGlyph(samples: samples)
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
                    self.presentationState.publishElapsed(formatted)
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
        // Review finding: the record-time capture lands AFTER indicator-up, so the first
        // transition almost always renders the deck; promote/demote here so exactly one
        // surface is ever visible. Ring law needs no per-view calls: the SwiftUI
        // surfaces gate the ring off IndicatorTokens (listening never rings).
        if chipVisibleNow() && !chipVisibleBefore {
            // Chip went live: retire the corner window.
            window?.alphaValue = 0.0
        } else if !chipVisibleNow() && chipVisibleBefore {
            // Anchor died mid-recording: restore the deck, never indicator-less.
            window?.alphaValue = 1.0
        }
    }

    private func chipVisibleNow() -> Bool {
        caretChipWindow?.isVisible == true
    }

    /// Phase 2: exactly one publish per transition. The SwiftUI parity surfaces
    /// read this; the AppKit path keeps its direct view calls while the flag is
    /// off (plan §3.6, §10 Phase 2).
    private func publish(to state: IndicatorPresentationState,
                         overlayState: OverlayState,
                         presentation: Presentation) {
        state.publish(
            presentation: IndicatorPresentationState.Presentation(
                message: presentation.message,
                primaryActionTitle: presentation.actionTitle,
                secondaryActionTitle: presentation.secondaryActionTitle,
                primaryAction: presentation.action,
                secondaryAction: presentation.secondaryAction,
                targetAppName: presentation.targetAppName,
                targetAppIcon: presentation.targetAppIcon,
                isRecording: presentation.isRecording,
                canonicalState: indicatorState(for: overlayState)
            ),
            session: IndicatorPresentationState.Session(
                style: sessionStyle,
                usesDarkAppearance: sessionUsesDarkAppearance,
                reduceMotion: sessionReduceMotion
            )
        )
    }

    private func ensureWindow() {
        guard window == nil else { return }
        // Telemetry (DEBUG, Xcode console): confirms the SwiftUI content path
        // built this window. Sole content path since the Phase 4 cutover.
        indicatorDiag.debug("SwiftUI indicator surfaces ACTIVE (capsule hosting view)")
        let host = NSHostingView(rootView: IndicatorCapsuleRootView(state: presentationState))
        host.frame = NSRect(origin: .zero, size: currentWindowSize)
        capsuleHostingView = host
        let view = host
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
        // Corner-halo fix: elevation moves to the WindowServer. A CALayer shadow on the
        // content view cannot render past the window's own backing rect, so it was clipped
        // SQUARE at the frame edges — that was the translucent rectangle behind the pill.
        // A window shadow is composited OUTSIDE the frame and derives from the content's
        // alpha shape (the stadium) automatically; invalidateShadow() after setFrame keeps
        // the shape synced across the 290<->200<->150 width switches.
        w.hasShadow = true
        w.contentView = view
        window = w
    }

    private func positionWindow(on screen: NSScreen) {
        guard let w = window else { return }
        let screenFrame = screen.visibleFrame
        let placement = GeneralSettingsConfiguration.load().indicatorPlacement
        let frame = frameForPlacement(placement, visibleFrame: screenFrame)
        w.setFrame(frame, display: false)
        // Re-derive the WindowServer shadow from the content alpha after every frame
        // change (surface switches resize the window; stale shape = wrong halo).
        w.invalidateShadow()
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
        guard let chipWindow = caretChipWindow else { return }
        chipWindow.setFrame(
            NSRect(x: anchor.x, y: anchor.y, width: Metrics.caretChipWidth, height: Metrics.pillHeight),
            display: true)
        // Shadow shape follows the content alpha; re-derive after any frame change.
        chipWindow.invalidateShadow()
        // Review gap 1: the chip carries its own full visibility — ordered front here,
        // ordered out by hideCaretChip(). It must NOT mirror the corner window's alpha,
        // which is 0 while the chip owns feedback.
        if chipWindow.alphaValue < 1.0 { chipWindow.alphaValue = 1.0 }
        if !chipWindow.isVisible { chipWindow.orderFrontRegardless() }
    }

    private func ensureCaretChipWindow() {
        guard caretChipWindow == nil else { return }
        // Telemetry (DEBUG, Xcode console): caret chip on the SwiftUI path.
        indicatorDiag.debug("SwiftUI indicator surfaces ACTIVE (chip hosting view)")
        let host = NSHostingView(rootView: IndicatorChipRootView(state: presentationState))
        host.frame = NSRect(origin: .zero,
                            size: CGSize(width: Metrics.caretChipWidth, height: Metrics.pillHeight))
        chipHostingView = host
        let view: NSView = host
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
        // WindowServer shadow (see ensureWindow) — no CALayer shadow anywhere.
        w.hasShadow = true
        w.contentView = view
        caretChipWindow = w
    }

    private func hideCaretChip() {
        guard let w = caretChipWindow else { return }
        w.orderOut(nil)
    }
}

