import SwiftUI
import AppKit
import AVFoundation
import FluidAudio
import Foundation
import HotKey
import ApplicationServices
import CoreAudio
import AudioToolbox
import ServiceManagement

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

    private enum RecordingTriggerMode {
        case hold
        case toggle
    }
    
    private var isRecording = false
    private var isASRReady = false
    private var isAudioReady = false
    private var pttDownTime: CFAbsoluteTime = 0
    private var pttUpTime: CFAbsoluteTime = 0
    private var currentKeyDownTime: CFAbsoluteTime = 0
    private var lastTapReleaseTime: CFAbsoluteTime = 0
    private var recordingTriggerMode: RecordingTriggerMode?
    private var ignoreNextKeyUp = false
    private var hotkeyConfiguration: PTTHotkeyConfiguration = .load()
    private var transcriptionTask: Task<Void, Never>?
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
        let config = ModelSetupSupport.loadPersistedNormalizedSelectedModel()
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
                print("Failed to apply activation policy for showInDock=\(settings.showInDock); current=\(currentActivation.rawValue), target=\(targetActivation.rawValue)")
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
                print("Failed to update launch-at-login: \(error.localizedDescription)")
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
            let smokeInput = "two hundred and five"
            let smokeOutput = NemoTextProcessing.normalize(smokeInput)
            let version = NemoTextProcessing.version ?? "unknown"
            print("ITN ready (enabled=\(enabled), span=\(span), version=\(version), smoke='\(smokeInput)' -> '\(smokeOutput)')")
        } else {
            print("ITN unavailable (enabled=\(enabled), span=\(span)). NemoTextProcessing framework/module not linked or not visible to target.")
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
                print("Audio prepare failed: \(error.localizedDescription)")
            }
        } else {
            isAudioReady = false
        }

        let config = ModelSetupSupport.loadPersistedNormalizedSelectedModel()
        let availability = config.availability(for: config.asrVersion)
        switch availability {
        case .installed:
            do {
                if asr.isReady {
                    try await asr.reinitializeIfNeeded()
                } else {
                    try await asr.initialize()
                }
                isASRReady = asr.isReady
            } catch {
                isASRReady = false
                print("ASR init failed: \(error.localizedDescription)")
            }
        case .modelLibraryNotConfigured, .missingModelFolder, .invalidModelFolder:
            isASRReady = false
        }
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
                print("Audio input bind failed for \(candidate.name): \(error.localizedDescription)")
                continue
            }
        }
        try audio.prepare(preferredInputDeviceID: nil)
        return nil
    }

    @discardableResult
    private func startRecording(triggerMode: RecordingTriggerMode) -> Bool {
        guard !isRecording else { return false }
        let onboardingSnapshot = currentOnboardingSnapshot()
        guard !onboardingSnapshot.hasIncompleteRequirements else {
            showOnboardingWindow(mode: .repair)
            overlay.showInfoAndAutoHide("Complete setup to start dictation")
            return false
        }
        guard isAudioReady else {
            print("⚠️ Audio input not ready yet, ignoring PTT press.")
            overlay.showError("Microphone not ready", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }
        guard isASRReady else {
            print("⚠️ ASR not ready yet, ignoring PTT press.")
            if asr.isSetupIssue {
                showOnboardingWindow(mode: .repair)
                overlay.showError(asr.recordingBlockMessage, action: nil, autoHideAfter: 4.0)
            } else {
                overlay.showInfoAndAutoHide(asr.recordingBlockMessage)
            }
            return false
        }

        do {
            let pickedUID = try prepareAudioForRecording()
            selectedInputUID = pickedUID
            UserDefaults.standard.set(pickedUID, forKey: GeneralSettingsKeys.selectedInputUID)
        } catch {
            print("⚠️ Audio input setup failed, ignoring PTT press: \(error.localizedDescription)")
            overlay.showError("Microphone setup failed", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }

        isRecording = true
        recordingTriggerMode = triggerMode
        
        // Play chime (so user hears it at full volume)
        let chimeDuration = playRecordingChime()
        
        // Then duck system volume if enabled (slight delay so the chime is audible)
        if UserDefaults.standard.bool(forKey: "duckEnabled") {
            duckingStartWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isRecording else { return }
                SystemAudioDucker.shared.startDucking()
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

        transcriptionTask?.cancel()
        
        // Keep heavy work off the MainActor. Add post-roll to preserve trailing phonemes.
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self, pttDown, pttUp] in
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            let defaults = UserDefaults.standard
            let stageTimingEnabled = defaults.bool(forKey: LatencyTuningOptions.enableStageTimingKey)
            let pipelineStart = CFAbsoluteTimeGetCurrent()
            var mark = pipelineStart
            
            func stageMark(_ label: String) {
                guard stageTimingEnabled else { return }
                let now = CFAbsoluteTimeGetCurrent()
                print(String(format: "Latency stage [%@]: +%.0f ms (cum=%.0f ms)",
                             label,
                             (now - mark) * 1000.0,
                             (now - pipelineStart) * 1000.0))
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
            
            let keyUpToStopStart = CFAbsoluteTimeGetCurrent()
            let samples = await self.audio.stopAndFetchSamples(postRollMs: postRollMs)
            guard !Task.isCancelled else { return }
            let afterStop = CFAbsoluteTimeGetCurrent()
            let keyDownToUp = pttUp - pttDown
            let upToSamples = afterStop - keyUpToStopStart
            print(String(format: "Timing: PTT down→up=%.0f ms (est. segment=%.0f ms), key-up→samples=%.0f ms (adaptive post-roll=%d ms)",
                         keyDownToUp * 1000, Double(segmentEstimateMs), upToSamples * 1000, postRollMs))
            stageMark("audio-stop+fetch")
            
            // Trim with hysteresis/hangover/padding + conservative fallback
            let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: 16_000)
            stageMark("trim")
            guard !trimmed.isEmpty else {
                print("No speech detected (empty after trim).")
                await MainActor.run {
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }
            
            do {
                // Parallelize lightweight peak normalization (~5ms for 10s) in a concurrent Task.
                // Await before ASR due to input dependency (normalized samples required for transcription).
                // Structure uses async let for "parallel" invocation; enables future overlap (e.g., with post-ASR steps).
                // Rationale: Overlaps micro-delays in serial chain (trim → normalize → ASR); negligible CPU on Apple Silicon.
                // Expected: 10-20ms savings per plan. Real-app pattern: Final Cut Pro/Whisper.cpp batch audio pipelines.
                // Low confidence: True parallelism limited by dependency; test on long segments for gains.
                let asrStart = CFAbsoluteTimeGetCurrent()
                let normalizedTask = Task {
                    SilenceTrimmer.normalizePeak(trimmed, targetDbFS: -3.0)
                }
                async let asrText: String = {
                    let normalized = await normalizedTask.value
                    return try await self.asr.transcribe(samples: normalized)
                }()
                let text = try await asrText
                guard !Task.isCancelled else { return }
                let asrEnd = CFAbsoluteTimeGetCurrent()
                stageMark("asr")
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !trimmedText.isEmpty else {
                    print("⚠️ Empty transcription; skipping paste.")
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
                print("Transcription completed (len=\(postProcessed.count), ASR=\(String(format: "%.0f", (asrEnd - asrStart)*1000)) ms, cleanupEdits=\(cleanupResult.stats.totalEdits), cleanupMs=\(String(format: "%.0f", cleanupResult.stats.durationMs)), fillerMs=\(String(format: "%.0f", cleanupResult.stats.fillerMs)), backtrackMs=\(String(format: "%.0f", cleanupResult.stats.backtrackMs)), listMs=\(String(format: "%.0f", cleanupResult.stats.listMs)), punctuationMs=\(String(format: "%.0f", cleanupResult.stats.punctuationMs)), grammarMs=\(String(format: "%.0f", cleanupResult.stats.grammarMs)), grammarEdits=\(cleanupResult.stats.grammarEdits), grammarAttempted=\(cleanupResult.stats.grammarAttempted), grammarTimedOut=\(cleanupResult.stats.grammarTimedOut), grammarSkippedForLength=\(cleanupResult.stats.grammarSkippedForLength), itnEnabled=\(itnResult.enabled), itnAvailable=\(itnResult.available), itnSpan=\(itnResult.spanTokens), itnChanged=\(itnResult.changed), itnMs=\(String(format: "%.0f", itnResult.durationMs)), replacements=\(replaceCount), est.segment=\(segmentEstimateMs) ms)")

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
                stageMark("paste-wait")

                do {
                    try await MainActor.run {
                        try self.paster.paste(postProcessed)
                        self.overlay.showSuccessAndAutoHide()
                    }
                    stageMark("paste-dispatch")
                    if stageTimingEnabled {
                        let totalMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000.0
                        print(String(format: "Latency summary: keyUp→paste-dispatch=%.0f ms (segment=%.0f ms, postRoll=%d ms, pasteDelay=%.0f ms)",
                                     totalMs, Double(segmentEstimateMs), postRollMs, pasteDelayMs))
                    }
                    print("✅ Pasted transcription into frontmost app (initial delay=\(String(format: "%.0f", pasteDelay*1000)) ms).")
                } catch {
                    print("❌ Initial paste failed after \(String(format: "%.0f", pasteDelay*1000)) ms: \(error.localizedDescription). Falling back to longer delay...")
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
                            print(String(format: "Latency summary: keyUp→paste-fallback-dispatch=%.0f ms (segment=%.0f ms, postRoll=%d ms, fallbackTotal=%.0f ms)",
                                         totalMs, Double(segmentEstimateMs), postRollMs, fallbackTotalMs))
                        }
                        print("✅ Fallback paste succeeded (total delay ~\(String(format: "%.0f", (pasteDelay + fallbackAdditionalDelay)*1000)) ms).")
                    } catch {
                        print("❌ Fallback paste also failed: \(error.localizedDescription)")
                        await MainActor.run {
                            self.overlay.showError("Enable Accessibility to paste", action: .openAccessibilitySettings, autoHideAfter: 4.0)
                            AccessibilityHelper.explainAccessibilityIfNeeded()
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                print("Transcription failed: \(error.localizedDescription)")
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
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.audio.cancelCapture()
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

// Float clamp helper
private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - SystemAudioDucker

import CoreAudio

final class SystemAudioDucker {
    static let shared = SystemAudioDucker()
    private init() {}
    
    private var duckingActive = false
    private var preDuckingVolume: Float? = nil
    
    func initialize() {
        // We will mute/unmute on demand.
    }
    
    func startDucking() {
        guard !duckingActive else { return }
        guard GeneralSettingsConfiguration.load().muteWhileRecording else { return }
        
        duckingActive = true
        print("🔻 Muting system volume")
        
        let deviceID = getDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }
        
        if let currentVolume = getVirtualMainVolume(for: deviceID) {
            preDuckingVolume = currentVolume
            setVirtualMainVolume(for: deviceID, volume: 0.0)
        }
    }
    
    func stopDucking(cancelOnly: Bool = false) {
        guard duckingActive else { return }
        duckingActive = false
        print("🔊 Restoring system volume")
        
        guard let savedVolume = preDuckingVolume else { return }
        let deviceID = getDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }
        
        setVirtualMainVolume(for: deviceID, volume: savedVolume)
        preDuckingVolume = nil
    }
    
    // MARK: - CoreAudio Volume Helpers
    
    private func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        
        if status != noErr {
            print("Error getting default output device: \\(status)")
        }
        return deviceID
    }
    
    private func getVirtualMainVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0.0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioHardwareServiceHasProperty(deviceID, &propertyAddress) else {
            print("Device does not support VirtualMainVolume")
            return nil
        }
        
        let status = AudioHardwareServiceGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &volume
        )
        
        if status != noErr {
            print("Error getting volume: \\(status)")
            return nil
        }
        return volume
    }
    
    private func setVirtualMainVolume(for deviceID: AudioDeviceID, volume: Float) {
        var newVolume = volume.clamped(to: 0.0...1.0)
        let dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioHardwareServiceHasProperty(deviceID, &propertyAddress) else { return }
        
        let status = AudioHardwareServiceSetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            dataSize,
            &newVolume
        )
        
        if status != noErr {
            print("Error setting volume: \\(status)")
        }
    }
}

// MARK: - Global Hotkey (press-to-talk)

final class HotkeyListener {
    private var hotKey: HotKey?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var activePreset: KeyCombination?
    private var modifierHotkeyIsDown = false
    private var lastRelevantFlags: NSEvent.ModifierFlags = []
    private var leftCommandDown = false
    private var rightCommandDown = false
    private var leftOptionDown = false
    private var rightOptionDown = false
    private var leftShiftDown = false
    private var rightShiftDown = false
    private var leftControlDown = false
    private var rightControlDown = false
    private var functionDown = false
    var onPTTChanged: ((Bool) -> Void)?
    
    func start() {
        update(configuration: PTTHotkeyConfiguration.load())
    }

    func update(configuration: PTTHotkeyConfiguration) {
        stopModifierMonitoring()
        hotKey = nil

        let safeConfiguration = configuration.normalized()
        if let modifierOnlyFlags = safeConfiguration.keyCombination.modifierOnlyFlags {
            startModifierMonitoring(requiredFlags: modifierOnlyFlags, preset: safeConfiguration.keyCombination)
            print("Hotkey registered: \(safeConfiguration.keyCombination.displayName)")
            return
        }

        // Use HotKey for key+modifier combinations.
        let resolved = safeConfiguration.resolvedHotkey
        hotKey = HotKey(key: resolved.key.hotKeyValue, modifiers: resolved.modifiers)

        hotKey?.keyDownHandler = { [weak self] in
            self?.onPTTChanged?(true)
        }
        hotKey?.keyUpHandler = { [weak self] in
            self?.onPTTChanged?(false)
        }

        print("Hotkey registered: \(safeConfiguration.displayString)")
    }

    private func startModifierMonitoring(requiredFlags: NSEvent.ModifierFlags, preset: KeyCombination) {
        activeModifierFlags = requiredFlags.intersection([.command, .option, .shift, .control, .function])
        activePreset = preset
        modifierHotkeyIsDown = false
        lastRelevantFlags = []
        leftCommandDown = false
        rightCommandDown = false
        leftOptionDown = false
        rightOptionDown = false
        leftShiftDown = false
        rightShiftDown = false
        leftControlDown = false
        rightControlDown = false
        functionDown = false

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func stopModifierMonitoring() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        activeModifierFlags = []
        activePreset = nil
        modifierHotkeyIsDown = false
        lastRelevantFlags = []
        leftCommandDown = false
        rightCommandDown = false
        leftOptionDown = false
        rightOptionDown = false
        leftShiftDown = false
        rightShiftDown = false
        leftControlDown = false
        rightControlDown = false
        functionDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !activeModifierFlags.isEmpty else { return }
        let relevant = event.modifierFlags.intersection([.command, .option, .shift, .control, .function])
        updateSideState(for: event.keyCode, flags: relevant)
        lastRelevantFlags = relevant
        let isDown = isPresetCurrentlyActive(relevantFlags: relevant)

        if isDown == modifierHotkeyIsDown { return }
        modifierHotkeyIsDown = isDown
        onPTTChanged?(isDown)
    }

    private func updateSideState(for keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        switch keyCode {
        case 54:
            rightCommandDown = resolveSideKeyState(current: rightCommandDown, relevantFlag: .command, newFlags: flags)
        case 55:
            leftCommandDown = resolveSideKeyState(current: leftCommandDown, relevantFlag: .command, newFlags: flags)
        case 61:
            rightOptionDown = resolveSideKeyState(current: rightOptionDown, relevantFlag: .option, newFlags: flags)
        case 58:
            leftOptionDown = resolveSideKeyState(current: leftOptionDown, relevantFlag: .option, newFlags: flags)
        case 60:
            rightShiftDown = resolveSideKeyState(current: rightShiftDown, relevantFlag: .shift, newFlags: flags)
        case 56:
            leftShiftDown = resolveSideKeyState(current: leftShiftDown, relevantFlag: .shift, newFlags: flags)
        case 62:
            rightControlDown = resolveSideKeyState(current: rightControlDown, relevantFlag: .control, newFlags: flags)
        case 59:
            leftControlDown = resolveSideKeyState(current: leftControlDown, relevantFlag: .control, newFlags: flags)
        case 63:
            functionDown.toggle()
        default:
            break
        }

        if !flags.contains(.command) {
            leftCommandDown = false
            rightCommandDown = false
        }
        if !flags.contains(.option) {
            leftOptionDown = false
            rightOptionDown = false
        }
        if !flags.contains(.shift) {
            leftShiftDown = false
            rightShiftDown = false
        }
        if !flags.contains(.control) {
            leftControlDown = false
            rightControlDown = false
        }
        if !flags.contains(.function) {
            functionDown = false
        }
    }

    private func resolveSideKeyState(current: Bool, relevantFlag: NSEvent.ModifierFlags, newFlags: NSEvent.ModifierFlags) -> Bool {
        let oldContains = lastRelevantFlags.contains(relevantFlag)
        let newContains = newFlags.contains(relevantFlag)
        if oldContains != newContains {
            return newContains
        }
        return !current
    }

    private func isPresetCurrentlyActive(relevantFlags: NSEvent.ModifierFlags) -> Bool {
        guard let activePreset else {
            return relevantFlags == activeModifierFlags
        }

        func matchesExactly(_ expected: NSEvent.ModifierFlags) -> Bool {
            relevantFlags == expected
        }

        switch activePreset {
        case .rightCommand:
            return rightCommandDown && !leftCommandDown && matchesExactly([.command])
        case .rightOption:
            return rightOptionDown && !leftOptionDown && matchesExactly([.option])
        case .rightShift:
            return rightShiftDown && !leftShiftDown && matchesExactly([.shift])
        case .rightControl:
            return rightControlDown && !leftControlDown && matchesExactly([.control])
        case .fn:
            return functionDown && matchesExactly([.function])
        case .optionCommand, .controlCommand, .controlOption, .shiftCommand, .optionShift, .controlShift:
            return matchesExactly(activeModifierFlags)
        case .notSpecified:
            return matchesExactly(activeModifierFlags)
        }
    }

    deinit {
        stopModifierMonitoring()
    }
}

// MARK: - Dictation Overlay
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
            w.orderOut(nil)
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

final class AudioRecorder {
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
        
        print("Input format from AVAudioEngine: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
        
        // Prepare engine but don't start it yet - we'll start it when recording begins
        engine.prepare()
        print("Audio engine prepared (not started yet). Tap bufferSize=\(tapBufferSizeFrames)")
        isPrepared = true
        preparedInputDeviceID = preferredInputDeviceID
    }
    
    func startCollecting() {
        // Start engine when we begin collecting
        if !engine.isRunning {
            do {
                try engine.start()
                print("Audio engine started for recording")
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                print("Live input node output format after engine start: \(liveOutputFormat.sampleRate) Hz, \(liveOutputFormat.channelCount) channels")
                print("Live input node input-bus format after engine start: \(liveInputBusFormat.sampleRate) Hz, \(liveInputBusFormat.channelCount) channels")
            } catch {
                print("Failed to start audio engine: \(error.localizedDescription)")
                return
            }
        }

        if !tapInstalled {
            // For input node taps, AVAudioEngine expects the input bus hardware format.
            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            print("Installing tap with input-bus format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) channels")
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
        print("Started collecting audio samples")
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
            // Ensure engine.stop is done on main to avoid CoreAudio surprises
            await MainActor.run {
                self.engine.stop()
            }
            let stopElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            print(String(format: "Audio engine stopped (%.1f ms) - system mic indicator should turn off", stopElapsed))
        }
        
        // Drain any residual frames from the converter (resampler tail) and reset it
        let drainedTail = drainConverterRemainder()
        if !drainedTail.isEmpty {
            print("Drained converter tail: \(drainedTail.count) samples (~\(String(format: "%.1f", Double(drainedTail.count)/16_000.0 * 1000)) ms)")
        }
        
        out.append(contentsOf: drainedTail)
        
        let seconds = out.isEmpty ? 0.0 : (Double(out.count) / 16_000.0)
        let formattedSeconds = String(format: "%.2f", seconds)
        let callbacks = bufferQueue.sync { callbackCount }
        print("Stopped collecting. Buffer size: \(out.count) samples (\(formattedSeconds) s), callbacks: \(callbacks)")
        
        // Debug: Check non-zero and max amplitude
        let nonZeroCount = out.lazy.filter { abs($0) > 0.0001 }.count
        print("Non-zero samples: \(nonZeroCount) out of \(out.count)")
        if let maxAmplitude = out.map({ abs($0) }).max() {
            let formattedAmplitude = String(format: "%.5f", maxAmplitude)
            print("Max amplitude: \(formattedAmplitude)")
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
                    print("Failed to create AVAudioConverter for input format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
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
                print("Failed to create output buffer")
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
                    print("Conversion error: \(e.localizedDescription); using PCM fallback")
                } else {
                    print("Conversion error: unknown; using PCM fallback")
                }
                self.appendPCMBufferFallback(buffer)
                return
            }

            let frames = Int(outBuffer.frameLength)
            if frames > 0 {
                guard let channel = outBuffer.floatChannelData?[0] else {
                    print("No float channel data available; using PCM fallback")
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
        print("AudioRecorder deinitialized - engine stopped and tap removed")
    }
}

// MARK: - ASR (FluidAudio Parakeet TDT v3)

enum ASRError: LocalizedError {
    case notInitialized
    case modelLibraryNotConfigured
    case modelFolderMissing(version: ASRModelVersion, expectedPath: String)
    case invalidModelFiles(version: ASRModelVersion, expectedPath: String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "ASR not initialized yet."
        case .modelLibraryNotConfigured:
            return "No model library folder selected. Open Settings > Models and choose your model library folder."
        case .modelFolderMissing(let version, let expectedPath):
            return "Missing \(version.displayName) model folder at \(expectedPath)."
        case .invalidModelFiles(let version, let expectedPath):
            return "Incomplete or invalid files for \(version.displayName) at \(expectedPath)."
        }
    }

    var isSetupRelated: Bool {
        switch self {
        case .modelLibraryNotConfigured, .modelFolderMissing, .invalidModelFiles:
            return true
        case .notInitialized:
            return false
        }
    }

    var recordingBlockMessage: String {
        switch self {
        case .modelLibraryNotConfigured:
            return "Set model folder in Settings"
        case .modelFolderMissing:
            return "Selected model is missing"
        case .invalidModelFiles:
            return "Selected model files are invalid"
        case .notInitialized:
            return "Model loading..."
        }
    }
}

final class ASRService {
    private var asrManager: AsrManager?
    private var initialized = false
    private var currentModelVersion: ASRModelVersion?
    private var currentModelDirectoryPath: String?
    private(set) var lastInitializationErrorDescription: String?
    private(set) var isSetupIssue = false
    private var lastASRError: ASRError?
    
    // Public read-only property for readiness check
    var isReady: Bool {
        asrManager != nil && initialized
    }

    var recordingBlockMessage: String {
        if let lastASRError {
            return lastASRError.recordingBlockMessage
        }
        if let lastInitializationErrorDescription, !lastInitializationErrorDescription.isEmpty {
            return "Model initialization failed"
        }
        return "Model loading..."
    }
    
    func initialize() async throws {
        try await initialize(using: ModelSetupSupport.loadPersistedNormalizedSelectedModel())
    }
    
    func initialize(with version: ASRModelVersion) async throws {
        var config = ModelsConfiguration.load()
        config.asrVersion = version
        try await initialize(using: config)
    }

    private func initialize(using config: ModelsConfiguration) async throws {
        do {
            let version = config.asrVersion
            let availability = config.availability(for: version)
            let modelDirectory: URL
            let modelLibraryURL: URL

            switch availability {
            case .modelLibraryNotConfigured:
                throw ASRError.modelLibraryNotConfigured
            case .missingModelFolder(let expectedPath):
                throw ASRError.modelFolderMissing(version: version, expectedPath: expectedPath)
            case .invalidModelFolder(let expectedPath):
                throw ASRError.invalidModelFiles(version: version, expectedPath: expectedPath)
            case .installed(let path):
                modelDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                guard let libraryURL = config.modelLibraryURL else {
                    throw ASRError.modelLibraryNotConfigured
                }
                modelLibraryURL = libraryURL.standardizedFileURL
            }

            if initialized && currentModelVersion == version && currentModelDirectoryPath == modelDirectory.path {
                return
            }

            let models = try await ModelsConfiguration.withSecurityScopedAccess(to: modelLibraryURL) {
                try await AsrModels.load(from: modelDirectory, version: version.fluidAudioVersion)
            }
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asrManager = manager
            self.initialized = true
            self.currentModelVersion = version
            self.currentModelDirectoryPath = modelDirectory.path
            self.lastInitializationErrorDescription = nil
            self.isSetupIssue = false
            self.lastASRError = nil
            
            print("ASR initialized with model: \(version.displayName) from \(modelDirectory.path)")
            
            // Warm-up: run inference with model-expected shape (15s) to compile/allocate graph and avoid shape mismatches.
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self, let asrManager = self.asrManager else { return }
                do {
                    let warm = [Float](repeating: 0.0, count: 240_000)  // 15s at 16kHz to match [1, 240000] shape and min requirements
                    _ = try await asrManager.transcribe(warm, source: .system)
                    print("ASR warm-up completed.")
                } catch {
                    print("ASR warm-up skipped/failed (possible shape issue): \(error.localizedDescription)")
                }
            }
        } catch {
            self.asrManager = nil
            self.initialized = false
            self.currentModelVersion = nil
            self.currentModelDirectoryPath = nil
            self.lastInitializationErrorDescription = error.localizedDescription
            if let asrError = error as? ASRError {
                self.isSetupIssue = asrError.isSetupRelated
                self.lastASRError = asrError
            } else {
                self.isSetupIssue = true
                self.lastASRError = nil
            }
            throw error
        }
    }
    
    func reinitializeIfNeeded() async throws {
        let config = ModelsConfiguration.load()
        let version = config.asrVersion
        let targetPath = config.modelDirectoryURL(for: version)?.standardizedFileURL.path

        if !initialized || currentModelVersion != version || currentModelDirectoryPath != targetPath {
            print("ASR model configuration changed. Reinitializing...")
            asrManager = nil
            initialized = false
            try await initialize(using: config)
        }
    }
    
    func transcribe(samples: [Float]) async throws -> String {
        let config = ModelsConfiguration.load()
        let targetPath = config.modelDirectoryURL(for: config.asrVersion)?.standardizedFileURL.path
        if !initialized || currentModelVersion != config.asrVersion || currentModelDirectoryPath != targetPath {
            try await reinitializeIfNeeded()
        }
        
        guard let asrManager = asrManager, initialized else {
            throw ASRError.notInitialized
        }
        // Parakeet TDT expects 16kHz mono Float32
        let result = try await asrManager.transcribe(samples, source: .system)
        return result.text
    }
}

// MARK: - Paste into focused app

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

final class PasteService {
    private let logPrefix = "[PasteService]"

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
            print("\(logPrefix) Accessibility not trusted; aborting paste.")
            throw PasteServiceError.accessibilityNotTrusted
        }

        if postUnicodeTextIfPossible(text) {
            print("\(logPrefix) Paste succeeded via CGEvent unicode.")
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = waitForPasteboardCommit(targetChangeCount: targetChangeCount)

        if postCmdV() {
            print("\(logPrefix) Paste succeeded via Cmd+V.")
            restoreClipboardIfNeeded(snapshot)
            return
        }

        if let error = insertTextViaAccessibility(text) {
            print("\(logPrefix) Paste failed after AX fallback: \(error)")
            throw PasteServiceError.pasteExecutionFailed(reason: error)
        }

        print("\(logPrefix) Paste succeeded via Accessibility.")
        restoreClipboardIfNeeded(snapshot)
    }

    private func restoreClipboardIfNeeded(_ snapshot: PasteboardSnapshot) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snapshot.restore(to: NSPasteboard.general)
            print("\(self.logPrefix) Clipboard restored.")
        }
    }

    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        if after == before {
            return after + 1
        }
        return after
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
            print("\(logPrefix) Failed to create Cmd+V CGEvents.")
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
            print("\(logPrefix) CGEvent unicode skipped (len=\(utf16Array.count) > 200).")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            print("\(logPrefix) Failed to create CGEvent unicode events.")
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
// MARK: - Silence Trimmer (robust energy-based endpointer with hysteresis)

enum SilenceTrimmer {
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
        print(String(format: "Trimming audio - Max amplitude: %.5f", maxAmplitude))
        
        if maxAmplitude < 0.00001 {
            print("Audio is completely silent (max amplitude < 1e-5)")
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
        print(String(format: "Noise floor: %.1f dB, startThr: %.1f dB, stopThr: %.1f dB",
                     noiseFloorDb, startThresholdDb, stopThresholdDb))
        
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
            print("No speech detected after endpointing")
            // Conservative fallback: send full audio if it looks speech-y
            if maxAmplitude > 0.001 {
                print("Returning full audio for ASR to process (fallback)")
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
        
        print(String(format: "Trim decision: %d segments, padWins=%d -> kept=%d (%.2fs), original=%.2fs, keepRatio=%.0f%%",
                     segments.count, padWins, trimmedCount, trimmedDur, originalDur, keepRatio*100.0))
        print(String(format: "Trim fallback thresholds (dynamic): minSeconds=%.2f, minKeepRatio=%.0f%%",
                     dynamicMinSeconds, dynamicMinKeepRatio * 100.0))
        
        let shouldFallback =
        (originalDur >= 1.2 && trimmedDur < dynamicMinSeconds) ||
        (keepRatio < dynamicMinKeepRatio)
        
        if trimmedCount <= 0 || shouldFallback {
            print("Fallback to full clip (conservative).")
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
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
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

// MARK: - CoreAudio device diagnostics

// MARK: - Dictionary Model

// MARK: - Dictionary Model
struct DictionaryEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var trigger: String
    var replacement: String
    
    // New: Toggle to enable/disable the entry
    var isEnabled: Bool = true
    
    // Options (recommended defaults)
    var wholeWord: Bool = true
    var caseInsensitive: Bool = true
    var preserveCase: Bool = true
    var morphological: Bool = true
    
    // isPhrase is now a computed property, not stored. It's always in sync.
    var isPhrase: Bool {
        trigger.contains(where: { $0.isWhitespace })
    }
    
    // Track if user-added (for empty state on first launch)
    var userAdded: Bool = true
    
    init(id: UUID = UUID(),
         trigger: String,
         replacement: String,
         isEnabled: Bool = true,
         wholeWord: Bool = true,
         caseInsensitive: Bool = true,
         preserveCase: Bool = true,
         morphological: Bool = true,
         userAdded: Bool = true)
    {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.wholeWord = wholeWord
        self.caseInsensitive = caseInsensitive
        self.preserveCase = preserveCase
        self.morphological = morphological
        self.userAdded = userAdded
    }
    
    // Computed: Non-default options for badges (simplified)
    var nonDefaultOptions: [String] {
        var options: [String] = []
        if !caseInsensitive { options.append("Case Sensitive") }
        if !preserveCase { options.append("Ignore Case") }
        if isPhrase { options.append("Phrase") }
        return options
    }
    
    // Computed: Live examples of what this entry covers
    var exampleMatches: [String] {
        guard !trigger.isEmpty && !replacement.isEmpty else { return [] }
        
        func format(_ s: String) -> String {
            let r: String
            if !isPhrase {
                // Check for common suffixes in the source matching variant to show realistic output
                let commonSuffixes = ["'s", "’s", "s'", "es", "s"]
                var foundSuffix = ""
                let lowerS = s.lowercased()
                let lowerTrigger = trigger.lowercased()
                
                for suffix in commonSuffixes {
                    if lowerS == lowerTrigger + suffix {
                        foundSuffix = suffix
                        break
                    }
                }
                
                if !foundSuffix.isEmpty {
                    // Match the base casing first, then append the suffix
                    let baseMatched = String(s.dropLast(foundSuffix.count))
                    let adjustedBase = CaseHelper.adjustCase(of: replacement, toMatch: baseMatched)
                    r = adjustedBase + foundSuffix
                } else {
                    r = CaseHelper.adjustCase(of: replacement, toMatch: s)
                }
            } else {
                r = CaseHelper.adjustCaseForPhrase(of: replacement, toMatch: s)
            }
            return "\(s) → \(r)"
        }
        
        var variants: [String] = []
        
        // Casing variants
        if caseInsensitive || preserveCase {
            variants.append(trigger.lowercased())
            // Title case
            if trigger.count > 0 {
                let title = trigger.prefix(1).uppercased() + trigger.dropFirst().lowercased()
                variants.append(title)
            }
            // ALL CAPS (only for 2+ chars)
            if trigger.count > 1 {
                variants.append(trigger.uppercased())
            }
        } else {
            // Literal casing match
            variants.append(trigger)
        }
        
        // Suffixes for single words to show coverage
        if !isPhrase {
            let base = trigger.lowercased()
            variants.append("\(base)s")
            variants.append("\(base)'s")
        }
        
        // Return sorted, formatted unique examples
        return Array(Set(variants))
            .sorted { a, b in
                // Sort by length then alphabetically
                if a.count != b.count { return a.count < b.count }
                return a < b
            }
            .map { format($0) }
    }
}

// In-memory compiled rule
struct CompiledRule {
    let entry: DictionaryEntry
    let regex: NSRegularExpression
    let isWordRule: Bool
    // Groups for word rules
    let baseGroupIndex: Int
    let suffixGroupIndex: Int?
}

// Compiled engine
struct CompiledReplacementEngine {
    var phraseRules: [CompiledRule] = []
    var wordRules: [CompiledRule] = []
    
    static let empty = CompiledReplacementEngine(phraseRules: [], wordRules: [])
    
    func apply(to text: String) -> (String, Int) {
        var total = 0
        var out = text
        for rule in phraseRules {
            let (newText, count) = CompiledReplacementEngine.apply(rule: rule, to: out)
            out = newText
            total += count
        }
        for rule in wordRules {
            let (newText, count) = CompiledReplacementEngine.apply(rule: rule, to: out)
            out = newText
            total += count
        }
        return (out, total)
    }
    
    private static func apply(rule: CompiledRule, to text: String) -> (String, Int) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = rule.regex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty { return (text, 0) }
        
        var result = String()
        var lastLocation = 0
        var count = 0
        
        for m in matches {
            let mRange = m.range
            guard mRange.location != NSNotFound else { continue }
            // Append preceding segment
            let beforeRange = NSRange(location: lastLocation, length: mRange.location - lastLocation)
            result.append(nsText.substring(with: beforeRange))
            
            let entry = rule.entry
            let matchedString = nsText.substring(with: mRange)
            
            // Build replacement with options
            let replacement: String
            if rule.isWordRule {
                // Base and suffix
                let baseRange = m.range(at: rule.baseGroupIndex)
                let baseText = baseRange.location != NSNotFound ? nsText.substring(with: baseRange) : matchedString
                let suffixText: String = {
                    if let sIdx = rule.suffixGroupIndex {
                        let r = m.range(at: sIdx)
                        if r.location != NSNotFound, r.length > 0 {
                            return nsText.substring(with: r)
                        }
                    }
                    return ""
                }()
                
                let baseRepl = entry.preserveCase ? CaseHelper.adjustCase(of: entry.replacement, toMatch: baseText) : entry.replacement
                replacement = baseRepl + suffixText
            } else {
                // Phrase rule
                let baseRepl: String
                if entry.preserveCase {
                    baseRepl = CaseHelper.adjustCaseForPhrase(of: entry.replacement, toMatch: matchedString)
                } else {
                    baseRepl = entry.replacement
                }
                replacement = baseRepl
            }
            
            result.append(replacement)
            count += 1
            lastLocation = mRange.location + mRange.length
        }
        
        // Append trailing segment
        if lastLocation < nsText.length {
            let tailRange = NSRange(location: lastLocation, length: nsText.length - lastLocation)
            result.append(nsText.substring(with: tailRange))
        }
        
        return (result, count)
    }
}

enum ReplacementCompiler {
    static func compile(entries: [DictionaryEntry]) -> CompiledReplacementEngine {
        // Filter invalid/empty triggers AND disabled entries
        let cleaned = entries
            .filter { $0.isEnabled } // Only compile enabled entries
            .map { e -> DictionaryEntry in
                var e = e
                // Trim whitespace from trigger and replacement
                e.trigger = e.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                e.replacement = e.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                // The 'isPhrase' logic is now automatic in the struct, so we no longer set it here.
                return e
            }
            .filter { !$0.trigger.isEmpty && !$0.replacement.isEmpty }
        
        // Deduplicate by (trigger, options) — last wins
        var seen = Set<String>()
        var deduped: [DictionaryEntry] = []
        for e in cleaned.reversed() {
            let k = "\(e.trigger.lowercased())|\(e.caseInsensitive)|\(e.preserveCase)|\(e.isPhrase)"
            if !seen.contains(k) {
                deduped.append(e)
                seen.insert(k)
            }
        }
        deduped.reverse()
        
        // Compile phrase rules first (longest triggers first)
        let phrases = deduped.filter { $0.isPhrase }.sorted { $0.trigger.count > $1.trigger.count }
        let words = deduped.filter { !$0.isPhrase }.sorted { $0.trigger.count > $1.trigger.count }
        
        var phraseRules: [CompiledRule] = []
        var wordRules: [CompiledRule] = []
        
        for e in phrases {
            if let r = compilePhraseRule(e) {
                phraseRules.append(r)
            }
        }
        for e in words {
            if let r = compileWordRule(e) {
                wordRules.append(r)
            }
        }
        
        print("CustomDictionary: compiled \(phraseRules.count) phrase rules, \(wordRules.count) word rules from \(entries.filter{$0.isEnabled}.count) enabled entries")
        return CompiledReplacementEngine(phraseRules: phraseRules, wordRules: wordRules)
    }
    
    private static func compilePhraseRule(_ e: DictionaryEntry) -> CompiledRule? {
        // Escape tokens, allow flexible whitespace between them
        let tokens = e.trigger.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return nil }
        var pattern = tokens.joined(separator: "\\s+")
        // Enforce whole word for phrases
        pattern = "\\b" + pattern + "\\b"
        
        var opts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if e.caseInsensitive {
            opts.insert(.caseInsensitive)
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return CompiledRule(entry: e, regex: re, isWordRule: false, baseGroupIndex: 0, suffixGroupIndex: nil)
    }
    
    private static func compileWordRule(_ e: DictionaryEntry) -> CompiledRule? {
        let trigger = NSRegularExpression.escapedPattern(for: e.trigger)
        let baseGroupIndex = 1
        
        // Always enforce morphological (suffixes) and whole word for single words
        // Capture base, then optional suffix, enforce trailing boundary after suffix
        // Suffix includes: 's, ’s, s', es, s
        let pattern = "\\b(" + trigger + ")" + "(" + "'s|’s|s'|es|s" + ")?\\b" // group 1 = base, group 2 = suffix
        let suffixIndex = 2
        
        var opts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if e.caseInsensitive { opts.insert(.caseInsensitive) }
        
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        return CompiledRule(entry: e, regex: re, isWordRule: true, baseGroupIndex: baseGroupIndex, suffixGroupIndex: suffixIndex)
    }
}


enum CaseHelper {
    static func adjustCase(of replacement: String, toMatch source: String) -> String {
        if source.isEmpty || replacement.isEmpty { return replacement }
        
        // If replacement is truly mixed-case/branded (e.g. "iPad", "eBay", "Main St"),
        // we respect the user's explicit casing unless the source is ALL CAPS (shouting).
        if isMixedCase(replacement) {
            if isAllUpper(source) && source.count > 1 {
                return replacement.uppercased()
            }
            return replacement
        }
        
        if isAllUpper(source) && source.count > 1 {
            return replacement.uppercased()
        }
        if isAllLower(source) {
            return replacement.lowercased()
        }
        if isTitleWord(source) {
            return titleWord(replacement)
        }
        // Mixed or branded case, leave as user-specified replacement
        return replacement
    }
    
    static func adjustCaseForPhrase(of replacement: String, toMatch source: String) -> String {
        if source.isEmpty || replacement.isEmpty { return replacement }
        
        if isMixedCase(replacement) {
            if isAllUpper(source) && source.count > 1 {
                return replacement.uppercased()
            }
            return replacement
        }
        
        if isAllUpper(source) && source.count > 1 {
            return replacement.uppercased()
        }
        if isAllLower(source) {
            return replacement.lowercased()
        }
        if isTitlePhrase(source) {
            // Capitalize each word token in replacement
            return replacement
                .split(whereSeparator: { $0.isWhitespace })
                .map { titleWord(String($0)) }
                .joined(separator: " ")
        }
        return replacement
    }
    
    private static func isAllUpper(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }
    
    private static func isAllLower(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
    }
    
    private static func isTitleWord(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var sawLetter = false
        var firstHandled = false
        for ch in s {
            if ch.isLetter {
                if !firstHandled {
                    if !String(ch).uppercased().elementsEqual(String(ch)) { return false }
                    firstHandled = true
                } else {
                    if !String(ch).lowercased().elementsEqual(String(ch)) { return false }
                }
                sawLetter = true
            }
        }
        return sawLetter
    }
    
    private static func titleWord(_ s: String) -> String {
        guard let first = s.first else { return s }
        let firstUpper = String(first).uppercased()
        let rest = String(s.dropFirst()).lowercased()
        return firstUpper + rest
    }
    
    private static func isTitlePhrase(_ s: String) -> Bool {
        let tokens = s.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return false }
        // Require each token to be title-cased
        return tokens.allSatisfy { isTitleWord(String($0)) }
    }
    
    private static func isMixedCase(_ s: String) -> Bool {
        // We consider it "Mixed/Branded" if there is an uppercase letter 
        // that is NOT at the very beginning of the string.
        // e.g. "iPad", "eBay", "Main St", "123 Main St" vs "Orange" or "orange"
        guard s.count > 1 else { return false }
        let suffix = s.dropFirst()
        return suffix.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }
}

// Persistence + Manager
final class CustomDictionaryManager: ObservableObject {
    static let shared = CustomDictionaryManager()
    private init() {}
    
    @Published var entries: [DictionaryEntry] = []
    
    private let fileName = "user_dictionary.json"
    private var appSupportURL: URL {
        let fm = FileManager.default
        let appName = "Kalam"
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(fileName)
    }
    
    private let queue = DispatchQueue(label: "Kalam.CustomDictionary", attributes: .concurrent)
    private var compiled: CompiledReplacementEngine = .empty
    
    private var debounceWork: DispatchWorkItem?
    
    // New: Flag for first-launch detection
    var isFirstLaunch: Bool {
        guard FileManager.default.fileExists(atPath: appSupportURL.path) else { return true }
        // Check if file has userAdded entries; if all false or empty, treat as first
        return entries.isEmpty || !entries.contains(where: { $0.userAdded })
    }
    
    func bootstrap() {
        print("[\(Date())] CustomDictionaryManager: Bootstrapping - loading from \(appSupportURL.path)")
        load()
        recompile()
        print("[\(Date())] CustomDictionaryManager: Bootstrap complete. Loaded \(entries.count) entries, first launch: \(isFirstLaunch)")
    }
    
    func apply(to text: String) -> (String, Int) {
        var engine: CompiledReplacementEngine = .empty
        queue.sync { engine = self.compiled }
        let (out, count) = engine.apply(to: text)
        if count > 0 {
            print("[\(Date())] CustomDictionary: applied \(count) replacement(s). Output length: \(out.count)")
        }
        return (out, count)
    }
    
    func addEntry(_ entry: DictionaryEntry) {
        print("[\(Date())] CustomDictionaryManager: Adding entry (ID: \(entry.id), trigger: '\(entry.trigger)'). Previous count: \(entries.count)")
        entries.append(entry)
        print("[\(Date())] CustomDictionaryManager: Added entry. New count: \(entries.count)")
        entriesDidChange()
    }
    
    func removeEntries(withIds ids: [UUID]) {
        guard !ids.isEmpty else { return }
        print("[\(Date())] CustomDictionaryManager: Removing \(ids.count) entries (IDs: \(ids)). Previous count: \(entries.count)")
        let beforeCount = entries.count
        entries.removeAll { ids.contains($0.id) }
        print("[\(Date())] CustomDictionaryManager: Removed entries. New count: \(entries.count) (removed \(beforeCount - entries.count))")
        entriesDidChange()
    }
    
    func sortEntriesByTrigger() {
        print("[\(Date())] CustomDictionaryManager: Sorting \(entries.count) entries by trigger")
        entries.sort { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        entriesDidChange()
    }
    
    func importJSON(from url: URL) throws {
        print("[\(Date())] CustomDictionaryManager: Importing from \(url.path)")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        entries = decoded
        print("[\(Date())] CustomDictionaryManager: Import complete. Loaded \(entries.count) entries")
        save()
        recompile()
    }
    
    func exportJSON(to url: URL) throws {
        print("[\(Date())] CustomDictionaryManager: Exporting \(entries.count) entries to \(url.path)")
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
        print("[\(Date())] CustomDictionaryManager: Export complete")
    }
    
    private func load() {
        let url = appSupportURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            print("[\(Date())] CustomDictionaryManager: No saved file found, starting empty (first launch)")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            entries = decoded.filter { $0.userAdded }  // New: Filter non-user (samples) on first launch
            print("[\(Date())] CustomDictionaryManager: Loaded \(decoded.count) entries from \(url.path), showing \(entries.count) user entries")
        } catch {
            print("[\(Date())] CustomDictionaryManager: Load failed: \(error.localizedDescription)")
            entries = []
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: appSupportURL, options: .atomic)
            print("[\(Date())] CustomDictionaryManager: Saved \(entries.count) entries to \(appSupportURL.path)")
        } catch {
            print("[\(Date())] CustomDictionaryManager: Save failed: \(error.localizedDescription)")
        }
    }
    
    // New: Immediate save for explicit actions
    func saveImmediately() {
        debounceWork?.cancel()
        debounceWork = nil
        save()
        recompile()
        print("[\(Date())] CustomDictionaryManager: Immediate save triggered")
    }
    
    func entriesDidChange() {
        debounceWork?.cancel()
        recompile()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    
    private func recompile() {
        let engine = ReplacementCompiler.compile(entries: entries)
        queue.async(flags: .barrier) { [weak self] in
            self?.compiled = engine
        }
    }
    
    func reloadFromDisk() {
        load()
        recompile()
    }
}
