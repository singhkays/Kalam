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

// MARK: - Secure Memory Zeroing
extension Array where Element == Float {
    mutating func secureZero() {
        self.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                memset(baseAddress, 0, buffer.count * MemoryLayout<Float>.size)
            }
        }
    }
}

// MARK: - Fix: Missing Accessibility Attribute Constants
// Some AX attributes aren't exposed in Swift headers, add them manually.
// MARK: - App
private let pasteKeyCode: CGKeyCode = 9 // 'V' key (ANSI V) for Command+V

enum KalamExternalLinks {
    static let latestReleaseURL = URL(string: "https://github.com/singhkays/Kalam/releases/latest")!

    @MainActor
    @discardableResult
    static func openLatestRelease() -> Bool {
        NSWorkspace.shared.open(latestReleaseURL)
    }
}

enum KalamAppVersion {
    static var displayString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty {
            return version
        }
        return "Unknown"
    }
}

// MARK: - App
@main
struct KalamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // macOS Settings window with our custom dictionary UI
        Settings {
            SettingsView()
                .environmentObject(CustomDictionaryManager.shared)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum ITNOptions {
        static let enabledDefaultsKey = "internal.itn.enabled"
        static let spanDefaultsKey = "internal.itn.maxSpanTokens"
        static let defaultEnabled = true
        static let defaultSpanTokens = 16
        static let minSpanTokens = 4
        static let maxSpanTokens = 64
    }
    
    private enum LatencyTuningOptions {
        static let postRollMinMsKey = "internal.latency.postRollMinMs"
        static let postRollMaxMsKey = "internal.latency.postRollMaxMs"
        static let pasteDelayShortMsKey = "internal.latency.pasteDelayShortMs"
        static let pasteDelayLongMsKey = "internal.latency.pasteDelayLongMs"
        static let pasteFallbackTotalMsKey = "internal.latency.pasteFallbackTotalMs"
        static let enableStageTimingKey = "internal.latency.enableStageTiming"
        
        static let defaultPostRollMinMs = 100
        static let defaultPostRollMaxMs = 150
        static let defaultPasteDelayShortMs = 50
        static let defaultPasteDelayLongMs = 80
        static let defaultPasteFallbackTotalMs = 120
        static let defaultEnableStageTiming = true
    }

    private var statusItem: NSStatusItem!
    private var setupMenuItem: NSMenuItem!
    private let asr = ASRService()
    private let audio = AudioRecorder()
    private let overlay = DictationOverlayController()
    private let hotkeys = HotkeyListener()
    private let paster = PasteService()
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "DictationRuntime")

    private enum RecordingTriggerMode {
        case hold
        case toggle
    }
    
    private var isRecording = false
    private var isASRReady = false
    private var isASRSetupIssue = false
    private var asrRecordingBlockMessage = "Model loading..."
    private var isAudioReady = false
    private var pttDownTime: CFAbsoluteTime = 0
    private var pttUpTime: CFAbsoluteTime = 0
    private var currentKeyDownTime: CFAbsoluteTime = 0
    private var lastTapReleaseTime: CFAbsoluteTime = 0
    private var recordingTriggerMode: RecordingTriggerMode?
    private var ignoreNextKeyUp = false
    private var hotkeyConfiguration: PTTHotkeyConfiguration = .load()
    private var transcriptionTask: Task<Void, Never>?
    private var recordingSessions = RecordingSessionTracker()
    private let holdOrToggleTapThreshold: CFTimeInterval = 0.45
    private let doubleTapInterval: CFTimeInterval = 0.35
    
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
            GeneralSettingsKeys.indicatorPlacementPreset: GeneralSettingsConfiguration.defaults.indicatorPlacementPreset.rawValue,
            GeneralSettingsKeys.muteWhileRecording: GeneralSettingsConfiguration.defaults.muteWhileRecording,
            LatencyTuningOptions.postRollMinMsKey: LatencyTuningOptions.defaultPostRollMinMs,
            LatencyTuningOptions.postRollMaxMsKey: LatencyTuningOptions.defaultPostRollMaxMs,
            LatencyTuningOptions.pasteDelayShortMsKey: LatencyTuningOptions.defaultPasteDelayShortMs,
            LatencyTuningOptions.pasteDelayLongMsKey: LatencyTuningOptions.defaultPasteDelayLongMs,
            LatencyTuningOptions.pasteFallbackTotalMsKey: LatencyTuningOptions.defaultPasteFallbackTotalMs,
            LatencyTuningOptions.enableStageTimingKey: LatencyTuningOptions.defaultEnableStageTiming
        ])
        
        SystemAudioDucker.shared.initialize()
        overlay.setWaveformProvider { [weak self] in
            self?.audio.recentWaveform(sampleCount: 512) ?? []
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
                let configuration = PTTHotkeyConfiguration.load()
                self.hotkeyConfiguration = configuration
                self.lastTapReleaseTime = 0
                self.ignoreNextKeyUp = false
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
                self?.applyGeneralSettings()
            }
        }

        microphonePriorityObserver = NotificationCenter.default.addObserver(
            forName: .microphonePriorityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            let priority = MicrophonePriorityConfiguration.load()
            let normalized = MicrophoneDeviceService.normalize(config: priority)
            normalized.save()
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
                await self.prepareRuntimeIfPossible()
                self.refreshOnboardingState(reopenIfNeeded: true)
            }
        }

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
            if let window = wc.window {
                configureSettingsWindow(window)
            }
            presentWindowController(wc, centerIfNeeded: wc.window?.isVisible != true)
            if selectModelsTab {
                NotificationCenter.default.post(name: .selectModelsSettingsTab, object: nil)
            }
            return
        }
        let initialTab: SettingsView.SettingsTab = selectModelsTab ? .models : .general
        let root = SettingsView(initialTab: initialTab).environmentObject(CustomDictionaryManager.shared)
        let vc = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        configureSettingsWindow(w)
        
        w.setContentSize(NSSize(width: 750, height: 640))
        w.minSize = NSSize(width: 750, height: 640)
        w.maxSize = NSSize(width: 750, height: CGFloat.greatestFiniteMagnitude)
        let wc = NSWindowController(window: w)
        self.settingsWC = wc
        presentWindowController(wc, centerIfNeeded: true)
        if selectModelsTab {
            NotificationCenter.default.post(name: .selectModelsSettingsTab, object: nil)
        }
    }
    
    private func configureSettingsWindow(_ window: NSWindow) {
        let fixedWidth: CGFloat = 900
        window.identifier = NSUserInterfaceItemIdentifier("KalamSettingsWindow")
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarSeparatorStyle = .automatic
        window.isMovableByWindowBackground = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.toolbar = nil
        window.minSize = NSSize(width: fixedWidth, height: 640)
        window.maxSize = NSSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude)
    }

    private func currentOnboardingSnapshot() -> OnboardingStatusSnapshot {
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
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }

    private func refreshOnboardingState(reopenIfNeeded: Bool) {
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

        let root = OnboardingView(controller: controller) { [weak self] in
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
        let preferredContentSize = NSSize(width: 600, height: 720)
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
        let settings = GeneralSettingsConfiguration.load()
        guard settings.escapeCancelsRecording else { return }
        guard isRecording else { return }
        cancelRecording()
    }

    private func logITNStatusOnStartup() {
        let enabled = Self.isITNEnabled()
        let span = Self.itnSpanTokens()
        if NemoTextProcessing.isAvailable {
            let version = NemoTextProcessing.version ?? "unknown"
            logger.info("ITN ready enabled=\(enabled, privacy: .public) span=\(span, privacy: .public) version=\(version, privacy: .public)")
        } else {
            logger.warning("ITN unavailable enabled=\(enabled, privacy: .public) span=\(span, privacy: .public)")
        }
    }

    private nonisolated static func applyITNIfEnabled(to text: String) -> (text: String, changed: Bool, durationMs: Double, available: Bool, enabled: Bool, spanTokens: Int) {
        let enabled = isITNEnabled()
        let spanTokens = itnSpanTokens()
        let nemoAvailable = NemoTextProcessing.isAvailable
        guard enabled, nemoAvailable, !text.isEmpty else {
            return (text, false, 0, nemoAvailable, enabled, spanTokens)
        }

        let span = UInt32(spanTokens)
        let started = CFAbsoluteTimeGetCurrent()
        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return NemoTextProcessing.normalizeSentence(line, maxSpanTokens: span)
        }

        let normalized = normalizedLines.joined(separator: "\n")
        let durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return (normalized, normalized != text, durationMs, nemoAvailable, enabled, Int(span))
    }

    private nonisolated static func isITNEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ITNOptions.enabledDefaultsKey) != nil else {
            return ITNOptions.defaultEnabled
        }
        return defaults.bool(forKey: ITNOptions.enabledDefaultsKey)
    }

    private nonisolated static func itnSpanTokens() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ITNOptions.spanDefaultsKey) != nil else {
            return ITNOptions.defaultSpanTokens
        }
        let value = defaults.integer(forKey: ITNOptions.spanDefaultsKey)
        return min(ITNOptions.maxSpanTokens, max(ITNOptions.minSpanTokens, value))
    }

    private func requestMicrophoneAccessFromOnboarding() async {
        _ = await AudioRecorder.requestMicrophoneAccessIfNeeded()
        await prepareRuntimeIfPossible()
        refreshOnboardingState(reopenIfNeeded: false)
    }

    private func prepareRuntimeIfPossible() async {
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
        case .modelLibraryNotConfigured, .missingModelFolder, .invalidModelFolder:
            isASRReady = false
            isASRSetupIssue = true
            asrRecordingBlockMessage = "Set model folder in Settings"
        }
    }

    private func updateASRStatus(_ status: ASRServiceStatus, forceReady: Bool? = nil) {
        isASRReady = forceReady ?? status.isReady
        isASRSetupIssue = status.isSetupIssue
        asrRecordingBlockMessage = status.recordingBlockMessage
    }

    private func handleHotkeyEvent(isDown: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let config = hotkeyConfiguration.normalized()

        if isDown {
            currentKeyDownTime = now

            switch config.activationMode {
            case .hold:
                pttDownTime = now
                _ = startRecording(triggerMode: .hold)

            case .toggle:
                toggleRecording(now: now)

            case .doubleTap:
                handleDoubleTap(now: now)

            case .holdOrToggle:
                handleHoldOrToggleKeyDown(now: now)
            }
            return
        }

        if ignoreNextKeyUp {
            ignoreNextKeyUp = false
            return
        }

        switch config.activationMode {
        case .hold:
            pttUpTime = now
            stopRecordingAndTranscribe()

        case .toggle:
            break

        case .doubleTap:
            lastTapReleaseTime = now

        case .holdOrToggle:
            handleHoldOrToggleKeyUp(now: now)
        }
    }

    private func handleHoldOrToggleKeyDown(now: CFAbsoluteTime) {
        if isRecording, recordingTriggerMode == .toggle {
            pttUpTime = now
            stopRecordingAndTranscribe()
            ignoreNextKeyUp = true
            return
        }

        guard !isRecording else { return }
        pttDownTime = now
        _ = startRecording(triggerMode: .hold)
    }

    private func handleHoldOrToggleKeyUp(now: CFAbsoluteTime) {
        guard isRecording else { return }
        guard recordingTriggerMode == .hold else { return }

        let pressDuration = now - currentKeyDownTime
        if pressDuration < holdOrToggleTapThreshold {
            recordingTriggerMode = .toggle
            return
        }

        pttUpTime = now
        stopRecordingAndTranscribe()
    }

    private func toggleRecording(now: CFAbsoluteTime) {
        if isRecording {
            pttUpTime = now
            stopRecordingAndTranscribe()
            ignoreNextKeyUp = true
            return
        }

        pttDownTime = now
        _ = startRecording(triggerMode: .toggle)
    }

    private func handleDoubleTap(now: CFAbsoluteTime) {
        if isRecording {
            pttUpTime = now
            stopRecordingAndTranscribe()
            ignoreNextKeyUp = true
            return
        }

        guard lastTapReleaseTime > 0 else { return }
        guard (now - lastTapReleaseTime) <= doubleTapInterval else { return }

        pttDownTime = now
        _ = startRecording(triggerMode: .toggle)
        lastTapReleaseTime = 0
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
    private func startRecording(triggerMode: RecordingTriggerMode) -> Bool {
        // K-01: a new recording supersedes any in-flight transcription/paste from
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

        do {
            let pickedUID = try prepareAudioForRecording()
            selectedInputUID = pickedUID
            UserDefaults.standard.set(pickedUID, forKey: GeneralSettingsKeys.selectedInputUID)
        } catch {
            logger.warning("Audio input setup failed before recording errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            overlay.showError("Microphone setup failed", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }

        _ = recordingSessions.beginNewRecording()
        isRecording = true
        recordingTriggerMode = triggerMode
        
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
        
        audio.startCollecting()
        overlay.showRecording(isHoldMode: triggerMode == .hold)
        return true
    }
    
    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        recordingTriggerMode = nil
        
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

        transcriptionTask?.cancel()
        
        // Run as an actor-inherited task instead of Task.detached so Swift 6 does not
        // send MainActor app state into an unisolated closure. Add post-roll to preserve trailing phonemes.
        transcriptionTask = Task(priority: .userInitiated) { [weak self, pttDown, pttUp, generation] in
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
            
            // Adaptive post-roll: Estimate segment duration from PTT hold time for dense speech optimization.
            // Clamp to 100-150ms range: reduces latency from fixed 200ms (plan: target <300ms end-to-end for dictation UX).
            // For short bursts (<100ms est.), floor at 100ms to avoid over-trimming; for long/continuous, cap at 150ms.
            // Rationale: Dense speech has abrupt PTT-up (minimal pauses), so shorter post-roll suffices; drainConverterRemainder handles ~20ms resampler tail.
            // Real-app pattern: Apple's Dictation uses ~100-200ms adaptive buffers based on speech density.
            let segmentEstimateMs = Int((pttUp - pttDown) * 1000)
            let configuredPostRollMin = max(50, min(400, defaults.integer(forKey: LatencyTuningOptions.postRollMinMsKey)))
            let configuredPostRollMax = max(configuredPostRollMin, min(500, defaults.integer(forKey: LatencyTuningOptions.postRollMaxMsKey)))
            let postRollMs = min(configuredPostRollMax, max(configuredPostRollMin, segmentEstimateMs))
            
            let audio = self.audio
            let keyUpToStopStart = CFAbsoluteTimeGetCurrent()
            let samples = await audio.stopAndFetchSamples(postRollMs: postRollMs)
            guard !Task.isCancelled else { return }
            let afterStop = CFAbsoluteTimeGetCurrent()
            let keyDownToUp = pttUp - pttDown
            let upToSamples = afterStop - keyUpToStopStart
            self.logger.info("Recording timing holdMs=\(Int(keyDownToUp * 1000), privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) keyUpToSamplesMs=\(Int(upToSamples * 1000), privacy: .public) postRollMs=\(postRollMs, privacy: .public)")
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
                
                // Run cleanup on transcript text before dictionary replacements.
                let cleanupConfig = ModelsConfiguration.load().textCleanup
                let cleanupResult = TextCleanupService.shared.clean(trimmedText, configuration: cleanupConfig)
                let itnResult = Self.applyITNIfEnabled(to: cleanupResult.text)
                stageMark("cleanup+itn")

                // Apply custom dictionary replacements (phrases first, then words)
                let (postProcessed, replaceCount) = CustomDictionaryManager.shared.apply(to: itnResult.text)
                stageMark("dictionary")
                self.logger.info("Transcription completed outputLength=\(postProcessed.count, privacy: .public) asrMs=\(Int((asrEnd - asrStart) * 1000), privacy: .public) cleanupEdits=\(cleanupResult.stats.totalEdits, privacy: .public) cleanupMs=\(Int(cleanupResult.stats.durationMs), privacy: .public) grammarEdits=\(cleanupResult.stats.grammarEdits, privacy: .public) grammarAttempted=\(cleanupResult.stats.grammarAttempted, privacy: .public) grammarTimedOut=\(cleanupResult.stats.grammarTimedOut, privacy: .public) grammarSkippedForLength=\(cleanupResult.stats.grammarSkippedForLength, privacy: .public) itnEnabled=\(itnResult.enabled, privacy: .public) itnAvailable=\(itnResult.available, privacy: .public) itnChanged=\(itnResult.changed, privacy: .public) itnMs=\(Int(itnResult.durationMs), privacy: .public) replacements=\(replaceCount, privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public)")

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
                    try await MainActor.run {
                        try self.paster.paste(postProcessed)
                        self.overlay.showSuccessAndAutoHide()
                    }
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
                        try await MainActor.run {
                            try self.paster.paste(postProcessed)
                            self.overlay.showSuccessAndAutoHide()
                        }
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
        isRecording = false
        recordingTriggerMode = nil

        if UserDefaults.standard.bool(forKey: "duckEnabled") {
            duckingStartWorkItem?.cancel()
            duckingStartWorkItem = nil
            SystemAudioDucker.shared.stopDucking()
        }

        playRecordingChime()

        transcriptionTask?.cancel()
        let audio = self.audio
        transcriptionTask = Task(priority: .userInitiated) { [weak self, audio] in
            guard let self else { return }
            await audio.cancelCapture()
            await MainActor.run {
                self.overlay.showInfoAndAutoHide("Recording canceled")
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

    func showError(_ message: String, action: OverlayAction?, autoHideAfter: TimeInterval) {
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

// MARK: - Audio Recorder (AVAudioEngine + resample to 16kHz mono Float32)

enum AudioRecorderError: LocalizedError {
    case micPermissionDenied
    case invalidInputFormat
    case converterCreationFailed
    case engineStartFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone permission denied."
        case .invalidInputFormat:
            return "Invalid input format."
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter."
        case .engineStartFailed(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        }
    }
}

final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputSampleRate: Double = 0
    private var converterInputChannelCount: AVAudioChannelCount = 0
    private var callbackCount: Int = 0
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    
    // Thread-safe buffer and converter access
    private let bufferQueue = DispatchQueue(label: "Kalam.AudioBuffer")
    private var collecting = false
    private var sampleBuffer: [Float] = []
    private var recentWaveformSamples: [Float] = []
    private let recentWaveformCapacity = 4096
    
    // Tap buffer size reduced to lower tail latency at key-up
    private let tapBufferSizeFrames: AVAudioFrameCount = 1024

    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    func prepare(preferredInputDeviceID: AudioDeviceID?) throws {
        if isPrepared && preparedInputDeviceID == preferredInputDeviceID {
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw AudioRecorderError.micPermissionDenied
        @unknown default:
            throw AudioRecorderError.micPermissionDenied
        }

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter = nil
        converterInputSampleRate = 0
        converterInputChannelCount = 0
        
        // Log current default input device details (to confirm e.g. Logitech C920)
        AudioDeviceDebug.logDefaultInputDeviceSummary()
        
        let input = engine.inputNode
        if let preferredInputDeviceID, let audioUnit = input.audioUnit {
            var id = preferredInputDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioRecorderError.engineStartFailed(
                    NSError(
                        domain: "Kalam.AudioRecorder",
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to bind input device (OSStatus \(status))"]
                    )
                )
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }
        
        logger.info("Input format sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
        
        // Prepare engine but don't start it yet - we'll start it when recording begins
        engine.prepare()
        logger.info("Audio engine prepared tapBufferSize=\(self.tapBufferSizeFrames, privacy: .public)")
        isPrepared = true
        preparedInputDeviceID = preferredInputDeviceID
    }
    
    func startCollecting() {
        // Start engine when we begin collecting
        if !engine.isRunning {
            do {
                try engine.start()
                logger.info("Audio engine started for recording")
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                logger.info("Live input output format sampleRate=\(liveOutputFormat.sampleRate, privacy: .public) channels=\(liveOutputFormat.channelCount, privacy: .public)")
                logger.info("Live input bus format sampleRate=\(liveInputBusFormat.sampleRate, privacy: .public) channels=\(liveInputBusFormat.channelCount, privacy: .public)")
            } catch {
                logger.warning("Failed to start audio engine errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                return
            }
        }

        if !tapInstalled {
            // For input node taps, AVAudioEngine expects the input bus hardware format.
            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            logger.info("Installing tap sampleRate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)")
            engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSizeFrames, format: tapFormat) { [weak self] (buffer, _) in
                self?.process(buffer: buffer)
            }
            tapInstalled = true
        }
        
        bufferQueue.sync {
            collecting = true
            callbackCount = 0
            sampleBuffer.removeAll(keepingCapacity: true)
            recentWaveformSamples.removeAll(keepingCapacity: true)
            // Do not reset converter here; keep across session until stop/drain to preserve internal filter state.
        }
        logger.info("Started collecting audio samples")
    }
    
    // Post-roll capture is applied before stopping and fetching samples.
    func stopAndFetchSamples(postRollMs: Int = 200) async -> [Float] {
        // Keep collecting for a short post-roll to capture trailing phonemes
        let delayMs = max(0, min(500, postRollMs))
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        
        var out: [Float] = []
        bufferQueue.sync {
            collecting = false
            out = sampleBuffer
            sampleBuffer.secureZero()
            sampleBuffer.removeAll(keepingCapacity: false)
            recentWaveformSamples.secureZero()
            recentWaveformSamples.removeAll(keepingCapacity: false)
        }
        
        // Stop the engine on the main thread to turn off the microphone indicator
        if engine.isRunning {
            let stopStart = CFAbsoluteTimeGetCurrent()
            let engine = self.engine
            // Ensure engine.stop is done on main to avoid CoreAudio surprises
            await MainActor.run {
                engine.stop()
            }
            let stopElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            logger.info("Audio engine stopped stopMs=\(Int(stopElapsed), privacy: .public)")
        }
        
        // Drain any residual frames from the converter (resampler tail) and reset it
        let drainedTail = drainConverterRemainder()
        if !drainedTail.isEmpty {
            logger.info("Drained converter tail samples=\(drainedTail.count, privacy: .public) durationMs=\(Int(Double(drainedTail.count) / 16_000.0 * 1000), privacy: .public)")
        }
        
        out.append(contentsOf: drainedTail)
        
        let durationMs = out.isEmpty ? 0 : Int(Double(out.count) / 16_000.0 * 1000)
        let callbacks = bufferQueue.sync { callbackCount }
        logger.info("Stopped collecting samples=\(out.count, privacy: .public) durationMs=\(durationMs, privacy: .public) callbacks=\(callbacks, privacy: .public)")
        
        // Debug: Check non-zero and max amplitude
        let nonZeroCount = out.lazy.filter { abs($0) > 0.0001 }.count
        logger.info("Audio sample summary nonZeroSamples=\(nonZeroCount, privacy: .public) totalSamples=\(out.count, privacy: .public)")
        if let maxAmplitude = out.map({ abs($0) }).max() {
            logger.info("Audio sample maxAmplitude=\(maxAmplitude, privacy: .public)")
        }
        return out
    }

    func cancelCapture() async {
        _ = await stopAndFetchSamples(postRollMs: 0)
    }
    
    private func process(buffer: AVAudioPCMBuffer) {
        bufferQueue.sync {
            guard self.collecting else { return }
            self.callbackCount += 1
            let inputFormat = buffer.format
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
            let needsConverterRebuild =
                self.converter == nil
                || self.converterInputSampleRate != inputFormat.sampleRate
                || self.converterInputChannelCount != inputFormat.channelCount

            if needsConverterRebuild {
                guard let rebuilt = AVAudioConverter(from: inputFormat, to: self.targetFormat) else {
                    self.logger.warning("Failed to create AVAudioConverter inputSampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
                    return
                }
                self.converter = rebuilt
                self.converterInputSampleRate = inputFormat.sampleRate
                self.converterInputChannelCount = inputFormat.channelCount
            }
            guard let converter = self.converter else { return }
            
            let ratio = self.targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64.0)
            
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else {
                self.logger.warning("Failed to create output buffer")
                return
            }
            
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
            
            if status == .error {
                if let e = convError {
                    self.logger.warning("Conversion error; using PCM fallback errorSummary=\(privacySafeErrorSummary(e), privacy: .public)")
                } else {
                    self.logger.warning("Conversion error unknown; using PCM fallback")
                }
                self.appendPCMBufferFallback(buffer)
                return
            }

            let frames = Int(outBuffer.frameLength)
            if frames > 0 {
                guard let channel = outBuffer.floatChannelData?[0] else {
                    self.logger.warning("No float channel data available; using PCM fallback")
                    self.appendPCMBufferFallback(buffer)
                    return
                }
                let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
                self.sampleBuffer.append(contentsOf: samples)
                self.recentWaveformSamples.append(contentsOf: samples)
                let overflow = self.recentWaveformSamples.count - self.recentWaveformCapacity
                if overflow > 0 {
                    self.recentWaveformSamples.removeFirst(overflow)
                }
            } else {
                self.appendPCMBufferFallback(buffer)
            }
        }
    }

    private func appendPCMBufferFallback(_ buffer: AVAudioPCMBuffer) {
        let mono = extractMonoFloatSamples(from: buffer)
        guard !mono.isEmpty else { return }
        let resampled = resampleLinear(mono, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        guard !resampled.isEmpty else { return }
        sampleBuffer.append(contentsOf: resampled)
        recentWaveformSamples.append(contentsOf: resampled)
        let overflow = recentWaveformSamples.count - recentWaveformCapacity
        if overflow > 0 {
            recentWaveformSamples.removeFirst(overflow)
        }
    }

    private func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: frames))

        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int16.max) }

        case .pcmFormatInt32:
            guard let channel = buffer.int32ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int32.max) }

        default:
            return []
        }
    }

    private func resampleLinear(_ input: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard inRate > 0, outRate > 0 else { return [] }
        guard abs(inRate - outRate) > 0.001 else { return input }

        let outputCount = Int(Double(input.count) * outRate / inRate)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let scale = inRate / outRate
        for i in 0..<outputCount {
            let src = Double(i) * scale
            let lo = Int(src)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(src - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }

    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        bufferQueue.sync {
            guard !recentWaveformSamples.isEmpty else { return [] }
            let count = max(8, sampleCount)
            if recentWaveformSamples.count <= count {
                return recentWaveformSamples
            }
            return Array(recentWaveformSamples.suffix(count))
        }
    }
    
    // Drain any residual frames from the converter at stream end to avoid losing ~10–30 ms.
    private func drainConverterRemainder() -> [Float] {
        var leftovers: [Float] = []
        bufferQueue.sync {
            guard let converter = self.converter else { return }
            var convError: NSError?
            
            // Provide end-of-stream to flush internal buffers
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: 2048) else { break }
                out.frameLength = 0
                let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
                if status == .haveData {
                    if let ch = out.floatChannelData?[0] {
                        let frames = Int(out.frameLength)
                        leftovers.append(contentsOf: UnsafeBufferPointer(start: ch, count: frames))
                    }
                    continue
                }
                break
            }
            // Reset converter between sessions to clear state
            converter.reset()
        }
        return leftovers
    }
    
    deinit {
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        sampleBuffer.secureZero()
        recentWaveformSamples.secureZero()
        logger.info("AudioRecorder deinitialized; engine stopped and tap removed")
    }
}

// MARK: - ASR (FluidAudio Parakeet TDT v3)

// MARK: - Silence Trimmer (robust energy-based endpointer with hysteresis)

enum SilenceTrimmer {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "SilenceTrimmer")

    // Main entry. Defaults tuned for dense speech with very little silence.
    static func trim(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        padMs: Int = 300,              // Increased for conservative padding
        startMarginDb: Float = 10,     // Lowered for tighter adaptation
        stopMarginDb: Float = 6,       // Lowered for tighter adaptation
        hangoverMs: Int = 300,         // Increased for longer speech tails
        fallbackMinSeconds: Double = 4.0,  // Baseline guardrail for short clips
        fallbackMinKeepRatio: Double = 0.8  // Baseline guardrail for short clips
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        
        let maxAmplitude = samples.map { abs($0) }.max() ?? 0
        logger.info("Trimming audio maxAmplitude=\(maxAmplitude, privacy: .public)")
        
        if maxAmplitude < 0.00001 {
            logger.info("Audio is silent below amplitude threshold")
            return []
        }
        
        let winSamples = max(1, (sampleRate * windowMs) / 1000)
        var energiesDb: [Float] = []
        energiesDb.reserveCapacity(samples.count / winSamples + 1)
        
        // Compute per-window RMS energy, then convert to dB (20*log10 for amplitude scale)
        let eps: Float = 1e-6  // Epsilon for RMS to avoid log(0); yields ~ -120 dB floor before clamp
        var i = 0
        while i < samples.count {
            let end = min(i + winSamples, samples.count)
            var sum: Float = 0
            var j = i
            while j < end {
                let s = samples[j]
                sum += s * s
                j += 1
            }
            let count = Float(end - i)
            let meanSquare = sum / count
            let rms = sqrt(meanSquare)
            let db = 20.0 * log10(max(rms, eps))
            // Clamp to [-60, 0] dB: -60 floor avoids overestimating silence in low-level speech; 0 caps peaks
            let clampedDb = max(-60.0, min(0.0, db))
            energiesDb.append(clampedDb)
            i = end
        }
        
        guard !energiesDb.isEmpty else { return samples }
        
        // Estimate noise floor using 5th percentile (more conservative for dense speech with less noise variability)
        let noiseFloorDb = percentile(energiesDb, p: 0.05)
        let startThresholdDb = noiseFloorDb + startMarginDb
        let stopThresholdDb = noiseFloorDb + stopMarginDb
        logger.info("Silence thresholds noiseFloorDb=\(noiseFloorDb, privacy: .public) startThresholdDb=\(startThresholdDb, privacy: .public) stopThresholdDb=\(stopThresholdDb, privacy: .public)")
        
        // Scan the buffer to extract multiple speech segments, dropping long silences
        let padWins = max(0, (padMs + windowMs - 1) / windowMs)
        let hangoverWins = max(1, (hangoverMs + windowMs - 1) / windowMs)
        
        var segments: [(start: Int, end: Int)] = []
        
        var inSpeech = false
        var startWin = 0
        var belowCount = 0
        var lastSpeechWin = -1
        
        for (idx, db) in energiesDb.enumerated() {
            if !inSpeech {
                if db >= startThresholdDb {
                    inSpeech = true
                    startWin = idx
                    lastSpeechWin = idx
                    belowCount = 0
                }
            } else {
                if db >= stopThresholdDb {
                    lastSpeechWin = idx
                    belowCount = 0
                } else {
                    belowCount += 1
                    if belowCount >= hangoverWins {
                        segments.append((start: startWin, end: lastSpeechWin))
                        inSpeech = false
                    }
                }
            }
        }
        
        if inSpeech {
            segments.append((start: startWin, end: lastSpeechWin))
        }
        
        if segments.isEmpty {
            logger.info("No speech detected after endpointing")
            // Conservative fallback: send full audio if it looks speech-y
            if maxAmplitude > 0.001 {
                logger.info("Returning full audio for ASR fallback")
                return samples
            }
            return []
        }
        
        // Pad and merge overlapping segments
        var paddedSegments: [(start: Int, end: Int)] = []
        for seg in segments {
            let paddedStart = max(0, seg.start - padWins)
            let paddedEnd = min(energiesDb.count - 1, seg.end + padWins)
            
            if let last = paddedSegments.last, last.end >= paddedStart {
                paddedSegments[paddedSegments.count - 1] = (start: last.start, end: max(last.end, paddedEnd))
            } else {
                paddedSegments.append((start: paddedStart, end: paddedEnd))
            }
        }
        
        var outSamples: [Float] = []
        var trimmedCount = 0
        
        for seg in paddedSegments {
            let startIndex = seg.start * winSamples
            let endIndex = min(samples.count, (seg.end + 1) * winSamples)
            if endIndex > startIndex {
                outSamples.append(contentsOf: samples[startIndex..<endIndex])
                trimmedCount += (endIndex - startIndex)
            }
        }
        
        // Fallback policy if the trim looks too aggressive
        let originalDur = Double(samples.count) / Double(sampleRate)
        let trimmedDur = Double(trimmedCount) / Double(sampleRate)
        let keepRatio = Double(trimmedCount) / Double(samples.count)
        
        // Duration-aware fallback:
        // - Short clips remain conservative to avoid clipped utterances.
        // - Long clips allow more aggressive trimming to reduce ASR latency on trailing silence.
        let dynamicMinSeconds: Double
        let dynamicMinKeepRatio: Double
        if originalDur >= 12.0 {
            dynamicMinSeconds = 0.7
            dynamicMinKeepRatio = 0.08
        } else if originalDur >= 8.0 {
            dynamicMinSeconds = 0.9
            dynamicMinKeepRatio = 0.12
        } else if originalDur >= 5.0 {
            dynamicMinSeconds = 1.1
            dynamicMinKeepRatio = 0.18
        } else if originalDur >= 2.5 {
            dynamicMinSeconds = 1.2
            dynamicMinKeepRatio = 0.35
        } else {
            dynamicMinSeconds = fallbackMinSeconds
            dynamicMinKeepRatio = fallbackMinKeepRatio
        }
        
        logger.info("Trim decision segments=\(segments.count, privacy: .public) padWins=\(padWins, privacy: .public) keptSamples=\(trimmedCount, privacy: .public) trimmedMs=\(Int(trimmedDur * 1000), privacy: .public) originalMs=\(Int(originalDur * 1000), privacy: .public) keepRatioPercent=\(Int(keepRatio * 100), privacy: .public)")
        logger.info("Trim fallback thresholds minMs=\(Int(dynamicMinSeconds * 1000), privacy: .public) minKeepRatioPercent=\(Int(dynamicMinKeepRatio * 100), privacy: .public)")
        
        let shouldFallback =
        (originalDur >= 1.2 && trimmedDur < dynamicMinSeconds) ||
        (keepRatio < dynamicMinKeepRatio)
        
        if trimmedCount <= 0 || shouldFallback {
            logger.info("Falling back to full audio clip")
            return samples
        }
        
        return outSamples
    }
    
    // Peak normalize to target dBFS (default -3 dBFS), clamped to [-1, 1].
    static func normalizePeak(_ samples: [Float], targetDbFS: Float = -3.0) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        if maxAbs < 1e-6 { return samples }
        let targetAmp = pow(10.0, targetDbFS / 20.0) // -3 dBFS ≈ 0.7079
        // Only scale if we would not clip badly; allow small attenuation or boost.
        let scale = targetAmp / maxAbs
        if abs(scale - 1.0) < 0.05 { // within 5%, skip
            return samples
        }
        return samples.map { min(max($0 * scale, -1.0), 1.0) }
    }
    
    private static func percentile(_ xs: [Float], p: Float) -> Float {
        if xs.isEmpty { return -120.0 }
        let pClamped = max(0.0, min(1.0, p))
        let sorted = xs.sorted()
        let idx = Int(round(pClamped * Float(sorted.count - 1)))
        return sorted[idx]
    }
}

// MARK: - Accessibility helper

enum AccessibilityHelper {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }
    
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            explainAccessibilityIfNeeded()
        } else {
            print("Accessibility: trusted = true")
        }
        return trusted
    }
    
    static func explainAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        print("""
        Accessibility not enabled for this app.
        Enable it in:
        System Settings → Privacy & Security → Accessibility → enable for Kalam.
        If you just enabled it, quit and re-launch the app.
        """)
    }
}

enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
        } catch {
            print("Failed to relaunch app automatically: \(error.localizedDescription)")
        }

        exit(0)
    }
}
