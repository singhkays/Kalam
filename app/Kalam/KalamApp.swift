import SwiftUI
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import HotKey
import ApplicationServices
import CoreAudio
import AudioToolbox
import ServiceManagement
import OSLog
import KalamTextEngine

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

// MARK: - Fix: Missing Accessibility Attribute Constants
// Some AX attributes aren't exposed in Swift headers, add them manually.
// MARK: - App
private let pasteKeyCode: CGKeyCode = 9 // 'V' key (ANSI V) for Command+V


// MARK: - App
@main
struct KalamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // Settings redesign: the settings window is the AppDelegate-hosted custom NSWindow
        // (menu-bar "Settings…" → openSettings). The scene shell is inert: an empty
        // Settings scene never auto-opens a window, and replacing the appSettings
        // command group removes the system "Settings…" menu item that would otherwise
        // open the blank scene window (observed live 2026-08-13). Only the custom
        // menu item (Cmd+, → openSettings) remains.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum LatencyTuningOptions {
        static let postRollMinMsKey = "internal.latency.postRollMinMs"
        static let postRollMaxMsKey = "internal.latency.postRollMaxMs"
        static let pasteDelayShortMsKey = "internal.latency.pasteDelayShortMs"
        static let pasteDelayLongMsKey = "internal.latency.pasteDelayLongMs"
        static let pasteFallbackTotalMsKey = "internal.latency.pasteFallbackTotalMs"
        static let enableStageTimingKey = "internal.latency.enableStageTiming"
        static let startStageTimingKey = "internal.latency.startStageTiming"

        static let defaultPostRollMinMs = 100
        static let defaultPostRollMaxMs = 150
        static let defaultPasteDelayShortMs = 50
        static let defaultPasteDelayLongMs = 80
        static let defaultPasteFallbackTotalMs = 120
        static let defaultEnableStageTiming = true
    }

    /// Adaptive post-roll for the audio stop pipeline: estimate segment duration
    /// from PTT hold time, clamp to the configured 100–150 ms range (50–400/500
    /// hard bounds), floors at the min for short bursts to avoid over-trimming.
    static func postRollForSegment(
        pttDown: CFAbsoluteTime,
        pttUp: CFAbsoluteTime,
        defaults: UserDefaults,
        logger: Logger
    ) -> Int {
        let segmentEstimateMs = Int((pttUp - pttDown) * 1000)
        let configuredPostRollMin = max(50, min(400, defaults.integer(forKey: LatencyTuningOptions.postRollMinMsKey)))
        let configuredPostRollMax = max(configuredPostRollMin, min(500, defaults.integer(forKey: LatencyTuningOptions.postRollMaxMsKey)))
        let postRollMs = min(configuredPostRollMax, max(configuredPostRollMin, segmentEstimateMs))
        logger.info("Post-roll computed segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public)")
        return postRollMs
    }

    private var statusItem: NSStatusItem!
    private var setupMenuItem: NSMenuItem!
    private let asr = ASRService()
    private let audio = AudioRecorder()
    private let overlay = DictationOverlayController()
    private let hotkeys = HotkeyListener()
    private let paster = PasteService()
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "DictationRuntime")

    // record-time paste target capture: record-time paste target (app PID + focused element), and a held transcript
    // awaiting an explicit "Paste" action when the captured target is gone.
    private var dictationTargetPID: pid_t?
    private var dictationTargetElement: AXUIElement?
    private var heldTranscript: String?
    /// partial-AX target capture no-op: the app the hold capsule promised (pid), so the Paste button
    /// delivers THERE instead of whatever is frontmost when clicked.
    private var heldTranscriptTargetPID: pid_t?

    private var isRecording: Bool { pttState.isRecording }
    private var isASRReady = false
    private var isASRSetupIssue = false
    private var asrRecordingBlockMessage = "Model loading..."
    private var isAudioReady = false
    private var pttDownTime: CFAbsoluteTime = 0
    private var startLatencyProbe: RecordingStartLatencyProbe?
    private var cachedOnboardingSnapshot: OnboardingStatusSnapshot?
    private var cachedOnboardingSnapshotAt: Date?
    /// Freshness backstop; event-driven invalidation below is the primary mechanism.
    private static let onboardingSnapshotMaxAgeSeconds: TimeInterval = 2.0
    private var pttUpTime: CFAbsoluteTime = 0
    private var hotkeyConfiguration: PTTHotkeyConfiguration = .load()
    private var transcriptionTask: Task<Void, Never>?
    /// Audio teardown for the current stop/cancel (post-roll + drain + engine stop).
    /// New recordings await its completion before collecting, so sessions never
    /// overlap in the audio layer even when the transcription task is cancelled.
    private var recordingStopTask: Task<[Float], Never>?
    private var runtimePrepTask: Task<Void, Never>?
    private var recordingSessions = RecordingSessionTracker()
    private let ptt = PTTStateMachine()
    private var pttState = PTTStateMachine.State()
    
    private var settingsWC: NSWindowController?
    private var onboardingWC: NSWindowController?
    private var onboardingController: OnboardingFlowController?
    private var hotkeyObserver: NSObjectProtocol?
    private var modelsConfigObserver: NSObjectProtocol?
    private var generalSettingsObserver: NSObjectProtocol?
    private var microphonePriorityObserver: NSObjectProtocol?
    private var openSetupObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var localKeyDownMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var audioMonitor: AudioDeviceMonitor?
    private var selectedInputUID: String?
    private var duckingStartWorkItem: DispatchWorkItem?
    private let recordingChime = NSSound(named: NSSound.Name("Breeze"))
    private var recordingChimePlayer: AVAudioPlayer?
    private let recordingChimeVolume: Float = 0.15
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No-network invariant: set before any FluidAudio loader can run
        // (see ASRService.enforceOfflineMode and the adoption dev-design doc).
        ASRService.enforceOfflineMode()
        let generalSettings = GeneralSettingsConfiguration.load()
        NSApp.setActivationPolicy(generalSettings.showInDock ? .regular : .accessory)
        prepareRecordingChime()
        
        // Register user defaults for ducking
        UserDefaults.standard.register(defaults: [
            "duckEnabled": true,
            "duckFactor": 0.1,
            "fadeMs": 150,
            GeneralSettingsKeys.launchAtLogin: GeneralSettingsConfiguration.defaults.launchAtLogin,
            GeneralSettingsKeys.showInDock: GeneralSettingsConfiguration.defaults.showInDock,
            GeneralSettingsKeys.escapeCancelsRecording: GeneralSettingsConfiguration.defaults.escapeCancelsRecording,
            GeneralSettingsKeys.indicatorPlacementPreset: GeneralSettingsConfiguration.defaults.indicatorPlacement.rawValue,
            GeneralSettingsKeys.muteWhileRecording: GeneralSettingsConfiguration.defaults.muteWhileRecording,
            LatencyTuningOptions.postRollMinMsKey: LatencyTuningOptions.defaultPostRollMinMs,
            LatencyTuningOptions.postRollMaxMsKey: LatencyTuningOptions.defaultPostRollMaxMs,
            LatencyTuningOptions.pasteDelayShortMsKey: LatencyTuningOptions.defaultPasteDelayShortMs,
            LatencyTuningOptions.pasteDelayLongMsKey: LatencyTuningOptions.defaultPasteDelayLongMs,
            LatencyTuningOptions.pasteFallbackTotalMsKey: LatencyTuningOptions.defaultPasteFallbackTotalMs,
            LatencyTuningOptions.enableStageTimingKey: LatencyTuningOptions.defaultEnableStageTiming,
            LatencyTuningOptions.startStageTimingKey: true
        ])
        
        SystemAudioDucker.shared.initialize()
        overlay.setWaveformProvider { [weak self] in
            self?.audio.recentWaveform(sampleCount: 512) ?? []
        }
        overlay.setPasteHeldTranscriptAction { [weak self] in
            self?.pasteHeldTranscript()
        }
        
        // Status bar icon/menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 1. Load the image by its name from your Assets.xcassets file.
            if let image = NSImage(named: "MenuBarIcon") {
                
                button.image = image
            }
        }
        let menu = NSMenu()
        setupMenuItem = NSMenuItem(title: "Complete Setup…", action: #selector(openSetup), keyEquivalent: "")
        setupMenuItem.target = self
        menu.addItem(setupMenuItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let latestReleaseItem = NSMenuItem(title: "View Latest Release…", action: #selector(openLatestRelease), keyEquivalent: "")
        latestReleaseItem.target = self
        menu.addItem(latestReleaseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kalam", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Load custom dictionary at startup
        CustomDictionaryManager.shared.bootstrap()
        logITNStatusOnStartup()
        
        hotkeyConfiguration = PTTHotkeyConfiguration.load()
        selectedInputUID = UserDefaults.standard.string(forKey: GeneralSettingsKeys.selectedInputUID)

        hotkeys.onPTTChanged = { [weak self] isDown in
            guard let self = self else { return }
            self.handleHotkeyEvent(isDown: isDown)
        }
        hotkeys.update(configuration: hotkeyConfiguration)

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .pttHotkeyConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // hotkeyConfig feeds the onboarding snapshot (hotkeyStatus,
                // selectedHotkeyDisplay) — keep the cache net symmetric.
                self.invalidateOnboardingSnapshot()
                let configuration = PTTHotkeyConfiguration.load()
                self.hotkeyConfiguration = configuration
                self.pttState.resetForConfigurationChange()
                self.hotkeys.update(configuration: configuration)
            }
        }
        
        modelsConfigObserver = NotificationCenter.default.addObserver(
            forName: .modelsConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.invalidateOnboardingSnapshot()
                // Refresh first so the UI reflects the new config immediately
                // (availability is a fast disk check); ASR prep runs in the
                // background, then a final refresh flips isASRReady.
                self.refreshOnboardingState(reopenIfNeeded: false)
                await self.prepareRuntimeIfPossible()
                self.refreshOnboardingState(reopenIfNeeded: false)
            }
        }

        generalSettingsObserver = NotificationCenter.default.addObserver(
            forName: .generalSettingsConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateOnboardingSnapshot()
                self?.applyGeneralSettings()
            }
        }

        microphonePriorityObserver = NotificationCenter.default.addObserver(
            forName: .microphonePriorityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let priority = MicrophonePriorityConfiguration.load()
            let normalized = MicrophoneDeviceService.normalize(config: priority)
            normalized.save()
            Task { @MainActor [weak self] in
                self?.invalidateOnboardingSnapshot()
            }
        }

        openSetupObserver = NotificationCenter.default.addObserver(
            forName: .openSetupFlow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.showOnboardingWindow(mode: self.currentOnboardingSnapshot().mode)
            }
        }

        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.invalidateOnboardingSnapshot()
                // Refresh before the slow ASR prep so the onboarding window
                // (if needed) appears immediately, then again after prep.
                self.refreshOnboardingState(reopenIfNeeded: true)
                await self.prepareRuntimeIfPossible()
                self.refreshOnboardingState(reopenIfNeeded: true)
            }
        }

        // microphone recovery after sleep or device change: react to audio-topology changes (dock reconnects, device
        // death) and system wake — the audio graph must be re-prepared
        // against the fresh device list instead of staying bound to a
        // stale CoreAudio device.
        let monitor = AudioDeviceMonitor()
        monitor.start(
            onDeviceChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshAudioInputAfterDeviceChange()
                }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleSystemWake()
                }
            }
        )
        audioMonitor = monitor

        applyGeneralSettings()
        installEscapeMonitor()
        refreshOnboardingState(reopenIfNeeded: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareRuntimeIfPossible()
            self.refreshOnboardingState(reopenIfNeeded: true)
        }

    }
    
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriptionTask?.cancel()
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
            self.hotkeyObserver = nil
        }
        if let modelsConfigObserver {
            NotificationCenter.default.removeObserver(modelsConfigObserver)
            self.modelsConfigObserver = nil
        }
        if let generalSettingsObserver {
            NotificationCenter.default.removeObserver(generalSettingsObserver)
            self.generalSettingsObserver = nil
        }
        if let microphonePriorityObserver {
            NotificationCenter.default.removeObserver(microphonePriorityObserver)
            self.microphonePriorityObserver = nil
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
        if let openSetupObserver {
            NotificationCenter.default.removeObserver(openSetupObserver)
            self.openSetupObserver = nil
        }
        audioMonitor?.stop()
        audioMonitor = nil
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
    }
    
    @objc private func openSettings() {
        openSettingsWindow(selectModelsTab: false)
    }

    @objc private func openLatestRelease() {
        KalamExternalLinks.openLatestRelease()
    }

    @objc private func openSetup() {
        showOnboardingWindow(mode: currentOnboardingSnapshot().mode)
    }

    private func openSettingsWindow(selectModelsTab: Bool) {
        if let wc = settingsWC {
            presentWindowController(wc, centerIfNeeded: wc.window?.isVisible != true)
            if selectModelsTab {
                postSelectModelsTab()
            }
            return
        }
        // Settings redesign: the settings window is a fixed 980×660 borderless custom NSWindow
        // hosted in an AppDelegate NSWindow (no WindowGroup scene — user decision 2026-08-13).
        let root = SettingsRoot(store: LiveSettingsBacking()) { [weak self] in
            self?.settingsWC?.window?.close()
        }
        let vc = NSHostingController(rootView: root)
        let w = SettingsWindow(contentViewController: vc)
        w.identifier = NSUserInterfaceItemIdentifier("KalamSettingsWindow")
        w.styleMask = [.borderless]
        w.isMovableByWindowBackground = true
        // settings redesign follow-up (2026-08-13): rounded 12 pt card corners per mockup `.frame` rule
        // (was isOpaque=true + kPaper background → square rect).
        w.applyRoundedCorners()
        w.isReleasedWhenClosed = false
        let size = NSSize(width: 980, height: 660)
        w.setContentSize(size)
        w.minSize = size
        w.maxSize = size
        let wc = NSWindowController(window: w)
        self.settingsWC = wc
        presentWindowController(wc, centerIfNeeded: true)
        w.makeKeyAndOrderFront(nil)
        if selectModelsTab {
            postSelectModelsTab()
        }
    }

    /// settings deep link (`.selectModelsSettingsTab` → Engine dive). Posted on the next
    /// runloop turn so the freshly created SettingsRoot has registered its observer.
    private func postSelectModelsTab() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .selectModelsSettingsTab, object: nil)
        }
    }

    private func currentOnboardingSnapshot() -> OnboardingStatusSnapshot {
        let now = Date()
        if let cached = cachedOnboardingSnapshot,
           OnboardingSnapshotCacheDecision.shouldReuse(
            cachedAt: cachedOnboardingSnapshotAt,
            now: now,
            maxAgeSeconds: Self.onboardingSnapshotMaxAgeSeconds) {
            return cached
        }
        let snapshot = buildOnboardingSnapshot()
        cachedOnboardingSnapshot = snapshot
        cachedOnboardingSnapshotAt = now
        return snapshot
    }

    private func invalidateOnboardingSnapshot() {
        cachedOnboardingSnapshot = nil
        cachedOnboardingSnapshotAt = nil
    }

    private func buildOnboardingSnapshot() -> OnboardingStatusSnapshot {
        let config = ModelsConfiguration.load()
        let onboardingConfig = OnboardingConfiguration.load()
        let hotkeyConfig = PTTHotkeyConfiguration.load()
        let installedModels = ModelSetupSupport.installedModelVersions(in: config)
        let selectedAvailability = config.availability(for: config.asrVersion)
        
        let selectedInputUID = UserDefaults.standard.string(forKey: GeneralSettingsKeys.selectedInputUID)
        let selectedMicName = MicrophoneDeviceService.availableInputDevices().first(where: { $0.uid == selectedInputUID })?.name
        
        return OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: AVCaptureDevice.authorizationStatus(for: .audio),
            selectedMicrophoneName: selectedMicName,
            accessibilityTrusted: AccessibilityHelper.isTrusted,
            hasAttemptedAccessibilitySetup: onboardingConfig.hasAttemptedAccessibilitySetup,
            hotkeyConfig: hotkeyConfig,
            hasPickedHotkey: onboardingConfig.hasPickedHotkey,
            selectedModelVersion: config.asrVersion,
            modelLibraryURL: config.modelLibraryURL,
            selectedModelAvailability: selectedAvailability,
            installedModelVersions: installedModels,
            hasCompletedRequiredSetup: onboardingConfig.hasCompletedRequiredSetup,
            hasConfirmedModelLocation: onboardingConfig.hasConfirmedModelLocation,
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }

    private func refreshOnboardingState(reopenIfNeeded: Bool) {
        invalidateOnboardingSnapshot()
        let snapshot = currentOnboardingSnapshot()
        if snapshot.canStartDictating {
            var onboardingConfig = OnboardingConfiguration.load()
            if !onboardingConfig.hasCompletedRequiredSetup {
                onboardingConfig.hasCompletedRequiredSetup = true
                onboardingConfig.save()
            }
        }

        setupMenuItem?.title = snapshot.hasIncompleteRequirements ? "Complete Setup…" : "Run Setup Again…"
        onboardingController?.apply(snapshot: snapshot)
        // accessibility relaunch escape hatch: after the user attempted Accessibility setup, every refresh transitions the
        // setup state to .enabledPendingRelaunch while the process isn't trusted — this makes
        // the "Quit & Reopen Kalam" relaunch path reachable (it was dead code before).
        onboardingController?.confirmAccessibilityEnabledIfAttempted()
        if reopenIfNeeded, snapshot.hasIncompleteRequirements {
            reopenOnboardingIfNeeded(with: snapshot.mode)
        }
    }

    private func reopenOnboardingIfNeeded(with mode: OnboardingMode) {
        if onboardingWC?.window?.isVisible == true {
            return
        }
        showOnboardingWindow(mode: mode)
    }

    private func showOnboardingWindow(mode: OnboardingMode) {
        let snapshot = currentOnboardingSnapshot()
        if let controller = onboardingController {
            controller.apply(snapshot: snapshot)
        }

        if let wc = onboardingWC, let window = wc.window {
            configureOnboardingWindow(window, mode: mode)
            presentWindowController(wc, centerIfNeeded: window.isVisible != true)
            return
        }

        let controller = onboardingController ?? OnboardingFlowController(
            snapshot: snapshot,
            requestMicrophoneAccessAction: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.requestMicrophoneAccessFromOnboarding()
                }
            },
            refreshAction: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // Same ordering as the modelsConfig observer: refresh the
                    // snapshot first (fast), run the slow ASR prep, then
                    // refresh again so isASRReady reaches the UI.
                    self.refreshOnboardingState(reopenIfNeeded: false)
                    await self.prepareRuntimeIfPossible()
                    self.refreshOnboardingState(reopenIfNeeded: false)
                }
            },
            openSettingsAction: { [weak self] in
                guard let self else { return }
                self.openSettingsWindow(selectModelsTab: false)
            },
            relaunchAppAction: {
                AppRelauncher.relaunch()
            },
            saveOnboardingConfiguration: { config in
                config.save()
            },
            startDictationAction: { [weak self] in
                self?.completeOnboarding()
            }
        )
        controller.apply(snapshot: snapshot)
        onboardingController = controller

        let root = OnboardingDeckView(controller: controller) { [weak self] in
            self?.onboardingWC?.window?.close()
        }
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        configureOnboardingWindow(window, mode: mode)

        let wc = NSWindowController(window: window)
        onboardingWC = wc
        presentWindowController(wc, centerIfNeeded: true)
    }

    private func configureOnboardingWindow(_ window: NSWindow, mode: OnboardingMode) {
        let onboardingFrameSize = onboardingWindowFrameSize(for: window.screen ?? NSScreen.main, window: window)
        window.identifier = NSUserInterfaceItemIdentifier("KalamOnboardingWindow")
        window.title = mode.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Must stay false: with it true, the window background swallows the
        // mouse-down and the Task 7 drag tile drags the WHOLE WINDOW instead
        // of originating an .onDrag. Window positioning happens via the
        // (transparent) titlebar region, which still drags.
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        
        // Hide traffic lights for a dedicated setup experience
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.minSize = onboardingFrameSize
        window.maxSize = onboardingFrameSize
    }

    private func presentWindowController(_ controller: NSWindowController, centerIfNeeded: Bool) {
        guard let window = controller.window else { return }
        controller.showWindow(nil)
        applyOnboardingWindowFrame(window, centerIfNeeded: centerIfNeeded)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func onboardingWindowFrameSize(for screen: NSScreen?, window: NSWindow) -> NSSize {
        let preferredContentSize = NSSize(width: 700, height: 600)
        let preferredFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize)).size
        guard let visibleFrame = screen?.visibleFrame else {
            return preferredFrameSize
        }

        let horizontalMargin: CGFloat = 32
        let verticalMargin: CGFloat = 32
        return NSSize(
            width: min(preferredFrameSize.width, max(420, visibleFrame.width - horizontalMargin)),
            height: min(preferredFrameSize.height, max(520, visibleFrame.height - verticalMargin))
        )
    }

    private func applyOnboardingWindowFrame(_ window: NSWindow, centerIfNeeded: Bool) {
        guard window.identifier == NSUserInterfaceItemIdentifier("KalamOnboardingWindow") else {
            if centerIfNeeded {
                window.center()
            }
            return
        }

        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = targetScreen?.visibleFrame else {
            if centerIfNeeded {
                window.center()
            }
            return
        }

        let targetFrameSize = onboardingWindowFrameSize(for: targetScreen, window: window)
        window.minSize = targetFrameSize
        window.maxSize = targetFrameSize
        var frame = window.frame
        frame.size = targetFrameSize

        if centerIfNeeded {
            frame.origin.x = visibleFrame.midX - (frame.width * 0.5)
            frame.origin.y = visibleFrame.midY - (frame.height * 0.5)
        }

        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    private func completeOnboarding() {
        onboardingWC?.window?.close()
        let snapshot = currentOnboardingSnapshot()
        if snapshot.canStartDictating {
            let hotkeyLabel = hotkeyConfiguration.normalized().displayString
            overlay.showInfoAndAutoHide("Kalam is ready. Press \(hotkeyLabel) to speak.")
        }
    }

    private func applyGeneralSettings() {
        let settings = GeneralSettingsConfiguration.load()

        let targetActivation: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        let currentActivation = NSApp.activationPolicy()
        if currentActivation != targetActivation {
            let activationApplied = NSApp.setActivationPolicy(targetActivation)
            if !activationApplied {
                logger.warning("Failed to apply activation policy showInDock=\(settings.showInDock, privacy: .public) current=\(currentActivation.rawValue, privacy: .public) target=\(targetActivation.rawValue, privacy: .public)")
            }
        }

        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.warning("Failed to update launch-at-login errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            }
        }
    }

    private func installEscapeMonitor() {
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscapeEvent(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscapeEvent(event)
        }
    }

    private func handleEscapeEvent(_ event: NSEvent) {
        guard event.keyCode == 53 else { return } // Escape
        // off-main post-processing: cheap checks FIRST — the global monitor fires on every
        // Escape keystroke system-wide, so the defaults load must sit
        // behind the isRecording gate.
        guard isRecording else { return }
        let settings = GeneralSettingsConfiguration.load()
        guard settings.escapeCancelsRecording else { return }
        cancelRecording()
    }

    private func logITNStatusOnStartup() {
        // off-main post-processing: enable/span moved into TranscriptPostProcessor (read at
        // process time); launch logs availability + version only.
        if NemoTextProcessing.isAvailable {
            let version = NemoTextProcessing.version ?? "unknown"
            logger.info("ITN ready version=\(version, privacy: .public)")
        } else {
            logger.warning("ITN unavailable")
        }
    }

    /// off-main post-processing: nonisolated + async => runs on the global executor (SE-0338),
    /// NOT the MainActor. Captures only Sendable values.
    private nonisolated static func postProcessTranscript(
        _ processor: TranscriptPostProcessor,
        _ text: String
    ) async -> TranscriptPostProcessor.Output {
        processor.process(text)
    }

    private func requestMicrophoneAccessFromOnboarding() async {
        _ = await AudioRecorder.requestMicrophoneAccessIfNeeded()
        await prepareRuntimeIfPossible()
        refreshOnboardingState(reopenIfNeeded: false)
    }

    private func prepareRuntimeIfPossible() async {
        // Single-flight: the modelsConfig observer, refreshAction,
        // appDidBecomeActive and the startup task can all fire concurrently
        // (e.g. applyModelLibraryFolder previously triggered both the
        // notification and refreshAction). Coalesce into one in-flight
        // preparation instead of loading/compiling the ASR model twice.
        if let runtimePrepTask {
            await runtimePrepTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimePreparation()
        }
        runtimePrepTask = task
        await task.value
        runtimePrepTask = nil
    }

    private func performRuntimePreparation() async {
        let microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneAuthorization == .authorized {
            do {
                try audio.prepare(preferredInputDeviceID: nil)
                isAudioReady = true
            } catch {
                isAudioReady = false
                logger.warning("Audio prepare failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            }
        } else {
            isAudioReady = false
        }

        let config = ModelsConfiguration.load()
        let availability = config.availability(for: config.asrVersion)
        switch availability {
        case .installed:
            do {
                let status = await asr.status
                if status.isReady {
                    try await asr.reinitializeIfNeeded()
                } else {
                    try await asr.initialize()
                }
                updateASRStatus(await asr.status)
            } catch {
                updateASRStatus(await asr.status, forceReady: false)
                logger.warning("ASR init failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            }
        case .modelLibraryNotConfigured, .missingModelFolder, .invalidModelFolder, .partial:
            isASRReady = false
            isASRSetupIssue = true
            asrRecordingBlockMessage = "Set model folder in Settings"
        }
    }

    private func updateASRStatus(_ status: ASRServiceStatus, forceReady: Bool? = nil) {
        invalidateOnboardingSnapshot()
        isASRReady = forceReady ?? status.isReady
        isASRSetupIssue = status.isSetupIssue
        asrRecordingBlockMessage = status.recordingBlockMessage
    }

    /// microphone recovery after sleep or device change: CoreAudio device changed (plug/unplug, default-input switch,
    /// device death, dock reconnect) — rebuild the audio graph against the
    /// fresh topology and re-select the priority-ordered microphone.
    private func refreshAudioInputAfterDeviceChange() {
        invalidateOnboardingSnapshot()
        audio.invalidatePreparedState()
        do {
            _ = try prepareAudioForRecording()
            isAudioReady = true
        } catch {
            isAudioReady = false
            logger.warning("Audio refresh after device change failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }
        refreshOnboardingState(reopenIfNeeded: false)
    }

    /// microphone recovery after sleep or device change: system woke. Two failure modes to clear:
    /// 1. A phantom PTT session (toggle started before sleep, key-up lost) —
    ///    the first post-wake keypress would otherwise act as a STOP and
    ///    instantly "transcribe" a junk clip. Reset the machine silently
    ///    (no chime, no toast — wake should not beep).
    /// 2. A stale audio-graph binding — same refresh as a device change.
    private func handleSystemWake() {
        invalidateOnboardingSnapshot()
        logger.info("System wake: resetting PTT state and refreshing audio input")
        if isRecording {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            dictationTargetPID = nil
            dictationTargetElement = nil
            heldTranscript = nil
            let audio = self.audio
            // Pin the teardown to the session being torn down on wake.
            let audioGeneration = audio.captureGeneration
            let stopTask = Task(priority: .userInitiated) { [audio, audioGeneration] in
                return audio.finishStop(expectedGeneration: audioGeneration)
            }
            recordingStopTask = stopTask
            overlay.hide()
        }
        // wake handler PTT field reset: abandon (recordingDidStop + flag clear), NOT
        // resetForConfigurationChange — the latter keeps isRecording == true,
        // so the first post-wake keypress acted as a STOP on a junk clip.
        pttState.abandonActiveSession()
        refreshAudioInputAfterDeviceChange()
    }

    private func handleHotkeyEvent(isDown: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let events = ptt.handle(
            isDown: isDown,
            now: now,
            activationMode: hotkeyConfiguration.normalized().activationMode,
            state: &pttState
        )
        for event in events {
            switch event {
            case .start(let triggerMode):
                pttDownTime = now
                var probe = RecordingStartLatencyProbe()
                probe.markWithTime(.hotkeyReceived, now)
                startLatencyProbe = probe
                _ = startRecording(triggerMode: triggerMode)
            case .stop:
                pttUpTime = now
                stopRecordingAndTranscribe()
            case .suppressNextKeyUp:
                pttState.suppressNextKeyUp()
            }
        }
    }

    private func resolvePriorityOrderedMicrophones() -> [MicrophoneDeviceDescriptor] {
        let config = MicrophonePriorityConfiguration.load()
        let normalized = MicrophoneDeviceService.normalize(config: config)
        if normalized != config {
            normalized.save()
        }
        return MicrophoneDeviceService.mergedPriorityList(config: normalized)
            .filter(\.isAvailable)
    }

    private func prepareAudioForRecording() throws -> String? {
        let candidates = resolvePriorityOrderedMicrophones()
        for candidate in candidates {
            do {
                try audio.prepare(preferredInputDeviceID: candidate.deviceID)
                return candidate.uid
            } catch {
                logger.warning("Audio input bind failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                continue
            }
        }
        try audio.prepare(preferredInputDeviceID: nil)
        return nil
    }

    @discardableResult
    private func startRecording(triggerMode: PTTStateMachine.TriggerMode) -> Bool {
        // stale-recording paste guard: a new recording supersedes any in-flight transcription/paste from
        // the previous session — abort it so stale text is never pasted.
        transcriptionTask?.cancel()
        guard !isRecording else { return false }
        let onboardingSnapshot = currentOnboardingSnapshot()
        guard !onboardingSnapshot.hasIncompleteRequirements else {
            showOnboardingWindow(mode: .repair)
            overlay.showInfoAndAutoHide("Complete setup to start dictation")
            return false
        }
        guard isAudioReady else {
            logger.warning("PTT ignored because audio input is not ready")
            overlay.showError("Microphone not ready", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }
        guard isASRReady else {
            logger.warning("PTT ignored because ASR is not ready; setupIssue=\(self.isASRSetupIssue, privacy: .public)")
            if isASRSetupIssue {
                showOnboardingWindow(mode: .repair)
                overlay.showError(asrRecordingBlockMessage, action: nil, autoHideAfter: 4.0)
            } else {
                overlay.showInfoAndAutoHide(asrRecordingBlockMessage)
            }
            return false
        }
        startLatencyProbe?.mark(.guardsCompleted)

        do {
            let pickedUID = try prepareAudioForRecording()
            selectedInputUID = pickedUID
            startLatencyProbe?.mark(.audioPrepared)
            UserDefaults.standard.set(pickedUID, forKey: GeneralSettingsKeys.selectedInputUID)
        } catch {
            logger.warning("Audio input setup failed before recording errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            overlay.showError("Microphone setup failed", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }

        // microphone recovery after sleep or device change: the state sync happens only after startCollecting succeeds —
        // a failed start must leave the PTT machine idle (PTT state machine test coverage invariant).
        _ = recordingSessions.beginNewRecording()

        // Play chime (so user hears it at full volume)
        let chimeDuration = playRecordingChime()

        // Then duck system volume if enabled (slight delay so the chime is audible)
        if UserDefaults.standard.bool(forKey: "duckEnabled") {
            duckingStartWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    SystemAudioDucker.shared.startDucking()
                }
            }
            duckingStartWorkItem = workItem
            let delay = max(0.12, min(0.6, chimeDuration))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        // record-time paste target capture: remember where the user is dictating so the transcript follows the
        // record-time target even if the frontmost app changes during transcription.
        // T14 diagnosis (2026-08-24 FAIL): capture failures were silent, degrading
        // invisibly to frontmost-at-paste-time. Log the outcome (app/strategy/reason
        // only — never transcript content).
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            switch AccessibilityFocusResolver.resolveFocusedElement(frontmostApp: frontmost) {
            case .success(let resolution):
                dictationTargetPID = frontmost.processIdentifier
                dictationTargetElement = resolution.element
                logger.info("Dictation target captured appName=\(resolution.appName, privacy: .public) strategy=\(resolution.strategy, privacy: .public) pid=\(frontmost.processIdentifier, privacy: .public)")
            case .failure(let error):
                // partial-AX target capture no-op: partial-AX apps (e.g. Sublime Text) answer none of the AX
                // queries, but the pid alone still identifies the record-time target —
                // keep it so paste-time routing can reactivate this app instead of
                // degrading to frontmost-at-paste-time.
                dictationTargetPID = frontmost.processIdentifier
                dictationTargetElement = nil
                logger.warning("Dictation target element capture FAILED reason=\(error.reason, privacy: .public) pidKept=\(frontmost.processIdentifier, privacy: .public)")
            }
        } else {
            dictationTargetPID = nil
            dictationTargetElement = nil
            logger.warning("Dictation target capture SKIPPED: no frontmost application")
        }

        do {
            try audio.startCollecting()
        } catch {
            logger.warning("Audio collection start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            dictationTargetPID = nil
            dictationTargetElement = nil
            overlay.showError("Microphone unavailable", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }
        startLatencyProbe?.mark(.engineStarted)
        pttState.recordingDidStart(triggerMode)
        overlay.showRecording(isHoldMode: triggerMode == .hold)
        startLatencyProbe?.mark(.indicatorShown)
        if UserDefaults.standard.bool(forKey: LatencyTuningOptions.startStageTimingKey),
           let line = startLatencyProbe?.summaryLine() {
            logger.info("Recording start latency \(line, privacy: .public)")
        }
        startLatencyProbe = nil
        return true
    }
    
    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        pttState.recordingDidStop()
        
        if UserDefaults.standard.bool(forKey: "duckEnabled") {
            duckingStartWorkItem?.cancel()
            duckingStartWorkItem = nil
            SystemAudioDucker.shared.stopDucking()
        }

        playRecordingChime()
        
        overlay.showTranscribing()
        
        // Capture PTT times on MainActor before detaching
        let pttDown = self.pttDownTime
        let pttUp = self.pttUpTime
        let generation = recordingSessions.currentGeneration()
        // Pin the audio stop to the capture session being stopped NOW, before
        // any suspension. A rapid re-record bumps this id; the stale stop will
        // then no-op instead of draining the new session.
        let audioGeneration = audio.captureGeneration

        transcriptionTask?.cancel()

        // Audio teardown lives in its own task: the transcription task is
        // cancelled by the next session's start (stale-recording paste guard) and must NOT own the
        // engine-stop/drain step, or a rapid re-record would skip it and leave
        // the engine running under the next session.
        let stopTask = Task(priority: .userInitiated) { [weak self, audioGeneration] in
            guard let self else { return [Float]() }
            let postRollMs = Self.postRollForSegment(
                pttDown: pttDown,
                pttUp: pttUp,
                defaults: .standard,
                logger: self.logger
            )
            try? await Task.sleep(nanoseconds: UInt64(postRollMs) * 1_000_000)
            return self.audio.finishStop(expectedGeneration: audioGeneration)
        }
        recordingStopTask = stopTask
        
        // Run as an actor-inherited task instead of Task.detached so Swift 6 does not
        // send MainActor app state into an unisolated closure. Add post-roll to preserve trailing phonemes.
        transcriptionTask = Task(priority: .userInitiated) { [weak self, pttDown, pttUp, generation, stopTask] in
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            let defaults = UserDefaults.standard
            let stageTimingEnabled = defaults.bool(forKey: LatencyTuningOptions.enableStageTimingKey)
            let pipelineStart = CFAbsoluteTimeGetCurrent()
            var mark = pipelineStart
            
            func stageMark(_ label: String) {
                guard stageTimingEnabled else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let deltaMs = Int((now - mark) * 1000.0)
                let cumulativeMs = Int((now - pipelineStart) * 1000.0)
                self.logger.info("Latency stage label=\(label, privacy: .public) deltaMs=\(deltaMs, privacy: .public) cumulativeMs=\(cumulativeMs, privacy: .public)")
                mark = now
            }
            
            let keyUpToStopStart = CFAbsoluteTimeGetCurrent()
            let samples = await stopTask.value
            guard !Task.isCancelled else { return }
            // A stale stop (superseded by a rapid re-record) returns no audio;
            // the newer session's overlay state owns the indicator from here.
            guard !samples.isEmpty else {
                self.logger.info("Stop superseded by a newer recording; skipping transcription")
                return
            }
            let afterStop = CFAbsoluteTimeGetCurrent()
            let keyDownToUp = pttUp - pttDown
            let upToSamples = afterStop - keyUpToStopStart
            // Segment estimate is derived from the PTT hold time; the paste
            // delay decision below reuses it without re-measuring.
            let segmentEstimateMs = Int((pttUp - pttDown) * 1000)
            let postRollMs = Self.postRollForSegment(
                pttDown: pttDown,
                pttUp: pttUp,
                defaults: defaults,
                logger: self.logger
            )
            self.logger.info("Recording timing holdMs=\(Int(keyDownToUp * 1000), privacy: .public) keyUpToSamplesMs=\(Int(upToSamples * 1000), privacy: .public)")
            stageMark("audio-stop+fetch")
            
            // Trim with hysteresis/hangover/padding + conservative fallback
            let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: 16_000)
            stageMark("trim")
            guard !trimmed.isEmpty else {
                self.logger.info("No speech detected after trimming")
                await MainActor.run {
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }

            // noise-clip ASR rejection: never feed noise-only clips to ASR — Parakeet TDT
            // hallucinates filler words ("yeah") on boosted room tone.
            guard SpeechQualityGuard.isSpeechLike(samples: trimmed, sampleRate: 16_000) else {
                self.logger.info("Clip rejected by speech-quality guard")
                await MainActor.run {
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }
            
            do {
                // Normalize before ASR without spawning an extra child task; this keeps the
                // transcription flow inside one actor-inherited task for Swift 6 safety.
                let asrStart = CFAbsoluteTimeGetCurrent()
                var normalized = SilenceTrimmer.normalizePeak(trimmed, targetDbFS: -3.0)
                
                // Ensure audio is at least 300ms (4800 samples at 16kHz) to avoid FluidAudio short-utterance rejection
                if normalized.count < 4800 {
                    normalized.append(contentsOf: [Float](repeating: 0.0, count: 4800 - normalized.count))
                }
                
                let text = try await self.asr.transcribe(samples: normalized)
                guard !Task.isCancelled else { return }
                let asrEnd = CFAbsoluteTimeGetCurrent()
                stageMark("asr")
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !trimmedText.isEmpty else {
                    self.logger.info("Empty transcription result; skipping paste")
                    await MainActor.run {
                        self.overlay.showInfoAndAutoHide("No speech detected")
                    }
                    return
                }
                
                // off-main post-processing: snapshot Sendable inputs on-main, run cleanup+ITN+
                // dictionary OFF the main actor, keep only counts in logs.
                let processor = TranscriptPostProcessor(
                    cleanupConfig: ModelsConfiguration.load().textCleanup,
                    dictionaryEntries: CustomDictionaryManager.shared.entries
                )
                let post = await Self.postProcessTranscript(processor, trimmedText)
                stageMark("cleanup+itn+dictionary")
                self.logger.info("Transcription completed outputLength=\(post.text.count, privacy: .public) asrMs=\(Int((asrEnd - asrStart) * 1000), privacy: .public) cleanupEdits=\(post.stats.totalEdits, privacy: .public) cleanupMs=\(Int(post.stats.durationMs), privacy: .public) grammarEdits=\(post.stats.grammarEdits, privacy: .public) grammarAttempted=\(post.stats.grammarAttempted, privacy: .public) grammarTimedOut=\(post.stats.grammarTimedOut, privacy: .public) grammarSkippedForLength=\(post.stats.grammarSkippedForLength, privacy: .public) itnSpansMasked=\(post.itnSpansMasked, privacy: .public) itnEnabled=\(post.itnEnabled, privacy: .public) itnAvailable=\(post.itnAvailable, privacy: .public) itnChanged=\(post.itnChanged, privacy: .public) itnMs=\(post.itnMs, privacy: .public) replacements=\(post.replacements, privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public)")

                // Adaptive paste delay: 50ms for short segments (<5s) or 80ms otherwise, to reduce end-to-end latency.
                // Fallback on error: Retry after additional delay to approx. total 120ms.
                let pasteDelayShortMs = max(20, min(300, defaults.integer(forKey: LatencyTuningOptions.pasteDelayShortMsKey)))
                let pasteDelayLongMs = max(20, min(300, defaults.integer(forKey: LatencyTuningOptions.pasteDelayLongMsKey)))
                let pasteDelayMs = Double(segmentEstimateMs) < 5000 ? Double(pasteDelayShortMs) : Double(pasteDelayLongMs)
                let fallbackTotalMs = max(pasteDelayMs, Double(max(20, min(500, defaults.integer(forKey: LatencyTuningOptions.pasteFallbackTotalMsKey)))))
                let pasteDelay = pasteDelayMs / 1000.0
                let fallbackAdditionalDelay = (fallbackTotalMs - pasteDelayMs) / 1000.0

                try await Task.sleep(nanoseconds: UInt64(pasteDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard self.recordingSessions.isCurrent(generation) else {
                    self.logger.info("Paste suppressed: recording superseded by a newer session")
                    return
                }
                stageMark("paste-wait")

                do {
                    // T14 diagnosis: record which branch fired and why. PIDs only,
                    // never transcript text. Decision and log share one frontmost
                    // read so they cannot disagree.
                    let frontmostPIDAtDecision = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let route = PasteService.PasteRouting.target(
                        capturedPID: self.dictationTargetPID,
                        capturedElement: self.dictationTargetElement,
                        frontmostPID: frontmostPIDAtDecision
                    )
                    switch route {
                    case .frontmost:
                        self.logger.info("Paste route=frontmost capturedPID=\(self.dictationTargetPID.map { String($0) } ?? "nil", privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        try await self.paster.paste(post.text)
                    case .capturedElement(let element):
                        // record-time paste target capture: the user switched apps while transcribing — insert into the
                        // record-time target (bypasses the pasteboard entirely).
                        self.logger.info("Paste route=capturedElement capturedPID=\(self.dictationTargetPID.map { String($0) } ?? "nil", privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        do {
                            try await self.paster.paste(into: element, text: post.text)
                        } catch {
                            // The captured target is gone (app quit / field closed): hold the
                            // transcript with a notice instead of pasting into the wrong app.
                            self.heldTranscript = post.text
                            self.heldTranscriptTargetPID = self.dictationTargetPID
                            self.dictationTargetElement = nil
                            self.dictationTargetPID = nil
                            let promisedName = NSRunningApplication(processIdentifier: self.heldTranscriptTargetPID ?? 0)?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
                            await MainActor.run {
                                self.overlay.showError(
                                    "Transcript ready — paste into \(promisedName)?",
                                    action: .pasteHeldTranscript,
                                    autoHideAfter: nil
                                )
                            }
                            self.logger.info("Captured-target paste failed; transcript held errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                            return
                        }
                    case .capturedApp(let capturedPid):
                        // partial-AX target capture no-op Option A: the record-time app has partial AX support (no
                        // element), so bring it back to front and paste via the normal
                        // path. If it cannot be reactivated or won't settle as frontmost,
                        // hold the transcript for the promised app (the Paste button will
                        // retry activation there).
                        self.logger.info("Paste route=capturedApp capturedPID=\(capturedPid, privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        guard await self.activateCapturedApp(capturedPid) != nil,
                              await self.waitForFrontmost(pid: capturedPid) else {
                            self.heldTranscript = post.text
                            self.heldTranscriptTargetPID = capturedPid
                            let appName = NSRunningApplication(processIdentifier: capturedPid)?.localizedName ?? "the original app"
                            await MainActor.run {
                                self.overlay.showError(
                                    "Transcript ready — paste into \(appName)?",
                                    action: .pasteHeldTranscript,
                                    autoHideAfter: nil
                                )
                            }
                            self.logger.warning("Captured-app activation failed; transcript held pid=\(capturedPid, privacy: .public)")
                            return
                        }
                        try await self.paster.paste(post.text)
                    }
                    self.heldTranscript = nil
                    self.heldTranscriptTargetPID = nil
                    self.dictationTargetElement = nil
                    self.dictationTargetPID = nil
                    self.overlay.showSuccessAndAutoHide()
                    stageMark("paste-dispatch")
                    if stageTimingEnabled {
                        let totalMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000.0
                        self.logger.info("Latency summary pasteDispatchMs=\(Int(totalMs), privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public) pasteDelayMs=\(Int(pasteDelayMs), privacy: .public)")
                    }
                    self.logger.info("Paste dispatched via initial path delayMs=\(Int(pasteDelay * 1000), privacy: .public)")
                } catch {
                    self.logger.warning("Initial paste failed delayMs=\(Int(pasteDelay * 1000), privacy: .public) errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                    try await Task.sleep(nanoseconds: UInt64(max(0, fallbackAdditionalDelay) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    stageMark("paste-fallback-wait")

                    do {
                        try await self.paster.paste(post.text)
                        self.overlay.showSuccessAndAutoHide()
                        stageMark("paste-fallback-dispatch")
                        if stageTimingEnabled {
                            let totalMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000.0
                            self.logger.info("Latency summary pasteFallbackDispatchMs=\(Int(totalMs), privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public) fallbackTotalMs=\(Int(fallbackTotalMs), privacy: .public)")
                        }
                        self.logger.info("Fallback paste dispatched totalDelayMs=\(Int((pasteDelay + fallbackAdditionalDelay) * 1000), privacy: .public)")
                    } catch {
                        self.logger.warning("Fallback paste failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                        await MainActor.run {
                            self.overlay.showError("Enable Accessibility to paste", action: .openAccessibilitySettings, autoHideAfter: 4.0)
                            AccessibilityHelper.explainAccessibilityIfNeeded()
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.logger.warning("Transcription failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                await MainActor.run {
                    self.overlay.showError("Transcription failed", action: nil, autoHideAfter: 4.0)
                }
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        pttState.recordingDidStop()

        // record-time paste target capture: a canceled session must not retain its paste target or held transcript.
        dictationTargetPID = nil
        dictationTargetElement = nil
        heldTranscript = nil
        heldTranscriptTargetPID = nil

        if UserDefaults.standard.bool(forKey: "duckEnabled") {
            duckingStartWorkItem?.cancel()
            duckingStartWorkItem = nil
            SystemAudioDucker.shared.stopDucking()
        }

        playRecordingChime()

        transcriptionTask?.cancel()
        let audio = self.audio
        // Pin the teardown to THIS session before any suspension — a stale
        // cancel must never kill a newer session that started in between.
        let audioGeneration = audio.captureGeneration
        let stopTask = Task(priority: .userInitiated) { [audio, audioGeneration] in
            return audio.finishStop(expectedGeneration: audioGeneration)
        }
        recordingStopTask = stopTask
        transcriptionTask = Task(priority: .userInitiated) { [weak self, stopTask] in
            guard let self else { return }
            _ = await stopTask.value
            await MainActor.run {
                self.overlay.showInfoAndAutoHide("Recording canceled")
            }
        }
    }

    /// partial-AX target capture no-op: activate another app from a background/menu-bar context. Plain
    /// `NSRunningApplication.activate()` is routinely refused by TCC for
    /// non-frontmost apps (observed live 2026-08-24: "activation refused");
    /// the LaunchServices route carries the user-intent semantics needed here.
    @MainActor
    private func activateCapturedApp(_ pid: pid_t) async -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if app.activate() { return app }
        logger.info("Plain activate refused; trying LaunchServices openApplication pid=\(pid, privacy: .public)")
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            try await NSWorkspace.shared.openApplication(at: app.bundleURL ?? URL(fileURLWithPath: "/"), configuration: configuration)
            return app
        } catch {
            logger.warning("LaunchServices activation failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            return nil
        }
    }

    /// Polls until `pid` is actually frontmost (≤1 s); false if it never settles.
    @MainActor
    private func waitForFrontmost(pid: pid_t) async -> Bool {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// record-time paste target capture/partial-AX target capture no-op: explicit "Paste" action for a held transcript. The capsule named an
    /// app, so deliver THERE: reactivate the promised app if it drifted to background,
    /// wait until it is genuinely frontmost, then paste via the normal path. Only if
    /// the promised app quit entirely does the paste go to the current frontmost —
    /// the user's click is then the conscious choice of destination.
    private func pasteHeldTranscript() {
        guard let text = heldTranscript else { return }
        let promisedPID = heldTranscriptTargetPID
        heldTranscript = nil
        heldTranscriptTargetPID = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let promisedPID, NSRunningApplication(processIdentifier: promisedPID) != nil {
                guard await self.activateCapturedApp(promisedPID) != nil,
                      await self.waitForFrontmost(pid: promisedPID) else {
                    let appName = NSRunningApplication(processIdentifier: promisedPID)?.localizedName ?? "the app"
                    self.logger.warning("Held-transcript reactivation failed pid=\(promisedPID, privacy: .public)")
                    self.overlay.showError("Could not bring \(appName) to front", action: nil, autoHideAfter: 4.0)
                    return
                }
            }
            do {
                try await self.paster.paste(text)
                self.overlay.showSuccessAndAutoHide()
            } catch {
                self.logger.warning("Held-transcript paste failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                self.overlay.showError("Paste failed", action: nil, autoHideAfter: 4.0)
            }
        }
    }

    @discardableResult
    private func playRecordingChime() -> TimeInterval {
        if let player = recordingChimePlayer {
            player.volume = recordingChimeVolume
            player.currentTime = 0
            player.play()
            return player.duration > 0 ? player.duration : 0.12
        }

        if let sound = recordingChime {
            sound.stop()
            sound.volume = recordingChimeVolume
            sound.currentTime = 0
            sound.play()
            let duration = sound.duration
            return duration > 0 ? duration : 0.12
        }

        NSSound.beep()
        return 0.12
    }

    private func prepareRecordingChime() {
        let systemSoundPath = "/System/Library/Sounds/Breeze.aiff"
        let systemSoundURL = URL(fileURLWithPath: systemSoundPath)

        if FileManager.default.fileExists(atPath: systemSoundPath),
           let player = try? AVAudioPlayer(contentsOf: systemSoundURL) {
            player.volume = recordingChimeVolume
            player.prepareToPlay()
            recordingChimePlayer = player
            return
        }

        if let sound = recordingChime {
            sound.volume = recordingChimeVolume
        }
    }
}
