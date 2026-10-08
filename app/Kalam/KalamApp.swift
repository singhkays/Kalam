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
        /// K-50 experiment kill switch (default OFF — ships dark).
        static let pidPasteEnabledKey = "internal.latency.pidPasteEnabled"
        static let enableStageTimingKey = "internal.latency.enableStageTiming"
        static let startStageTimingKey = "internal.latency.startStageTiming"
        // Task 5 (K-56): Tier-1 SET+verify per-reference timeout override (default OFF, 0 = unset).
        // Legal per AX law: non-system-wide set does NOT propagate.
        static let pasteSetVerifyTimeoutOverrideMsKey = "internal.paste.setVerifyTimeoutOverrideMs"
        // Task 3 (K-54): SNR-aware extension kill switches + retune path.
        static let snrAwareEnabledKey = "internal.latency.snrAwareEnabled"
        static let snrTrustDbKey = "internal.latency.snrTrustDb"
        static let snrAbsoluteCapMsKey = "internal.latency.snrAbsoluteCapMs"
        static let snrQuietToStopMsKey = "internal.latency.snrQuietToStopMs"
        static let snrRelativeCapKey = "internal.latency.snrRelativeCap"
        static let snrFloorMarginDbKey = "internal.latency.snrFloorMarginDb"

        static let defaultPostRollMinMs = 100
        static let defaultPostRollMaxMs = 150
        static let defaultPasteDelayShortMs = 50
        static let defaultPasteDelayLongMs = 80
        static let defaultPasteFallbackTotalMs = 120
        static let defaultEnableStageTiming = true
        static let defaultSnrAwareEnabled = true
        static let defaultSnrTrustDb: Float = 12
        static let defaultSnrAbsoluteCapMs = 1500
        static let defaultSnrQuietToStopMs = 250
        static let defaultSnrRelativeCap: Float = 0.30
        static let defaultSnrFloorMarginDb: Float = 3

        /// Build the Task-3 config from defaults. When the kill switch is OFF,
        /// returns a `.fixed` config identical to the K-49 behavior. When ON,
        /// returns `.snrAware` with per-key overrides (missing keys fall back
        /// to the Jot-derived constants). Documented retune path: write the
        /// `internal.latency.snr*` keys and restart; no code change required.
        nonisolated static func snrConstants(from defaults: UserDefaults) -> PostRollDecision.ExtensionConstants {
            var c = PostRollDecision.ExtensionConstants()
            // Each key may be absent (0 sentinel) — only override when
            // explicitly set. Float keys require object check to disambiguate
            // "not set" (0.0) from intentional 0; use object(forKey:) presence.
            if defaults.object(forKey: snrTrustDbKey) != nil {
                c.trustSnrDb = defaults.float(forKey: snrTrustDbKey)
            }
            if defaults.object(forKey: snrAbsoluteCapMsKey) != nil {
                let v = defaults.integer(forKey: snrAbsoluteCapMsKey)
                if v > 0 { c.absoluteCapMs = v }
            }
            if defaults.object(forKey: snrQuietToStopMsKey) != nil {
                let v = defaults.integer(forKey: snrQuietToStopMsKey)
                if v > 0 { c.quietToStopMs = v }
            }
            if defaults.object(forKey: snrRelativeCapKey) != nil {
                c.relativeCap = defaults.float(forKey: snrRelativeCapKey)
            }
            if defaults.object(forKey: snrFloorMarginDbKey) != nil {
                c.floorMarginDb = defaults.float(forKey: snrFloorMarginDbKey)
            }
            return c
        }

        nonisolated static func postRollConfig(postRollMs: Int, defaults: UserDefaults) -> PostRollDecision.Config {
            if defaults.object(forKey: snrAwareEnabledKey) != nil {
                if !defaults.bool(forKey: snrAwareEnabledKey) {
                    return PostRollDecision.Config(minMs: AppDelegate.postRollEarlyExitMinMs, maxMs: postRollMs)
                }
            } else if !defaultSnrAwareEnabled {
                return PostRollDecision.Config(minMs: AppDelegate.postRollEarlyExitMinMs, maxMs: postRollMs)
            }
            // Enabled (default ON after Task 3)
            let constants = snrConstants(from: defaults)
            return PostRollDecision.Config(
                minMs: AppDelegate.postRollEarlyExitMinMs,
                maxMs: postRollMs,
                extensionPolicy: .snrAware(constants)
            )
        }
    }

    /// K-49: small safety floor for the early-exit stop. The trailing-phoneme
    /// protection comes from the 3-consecutive-silent-polls rule; this floor
    /// just avoids finishing on the very first polls after key-up.
    nonisolated static let postRollEarlyExitMinMs = 60

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
        if KalamDiagnosticFlags.verboseAudio {
            logger.debug("Post-roll computed segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public)")
        }
        return postRollMs
    }

    private var statusItem: NSStatusItem!
    private var setupMenuItem: NSMenuItem!
    /// Dedup for the partial-AX capture failure (Sublime etc.): expected on every
    /// press, so log once per pid per launch and only when verbose.
    private static nonisolated(unsafe) var loggedPartialAXPIDs = Set<pid_t>()
    private static let loggedPartialAXPIDsLock = NSLock()
    private let asr = ASRService()
    private let audio = AudioRecorder()
    private let warmPool = WarmEnginePool()
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
    /// K-52: which session the hold slot belongs to. Cleanup is scoped by
    /// OWNERSHIP — a session's success path may only clear its own slot, so a
    /// preserved transcript from a superseded session survives (the wipe found
    /// in manual round 2: B's `heldTranscript = nil` destroyed A's preserved
    /// text because the slot was shared and the cleanup unconditional).
    private var heldTranscriptSession: SessionID?

    // K-52: pure lifecycle decision state (DictationStateMachine). Mutated
    // only through dispatchLifecycle, which realizes the machine's ordered
    // effects against app state.
    private var lifecycle: DictationState = .idle
    /// App-side record of the committed text for the most recent session (the
    /// machine deliberately carries no payload). Preserve effects copy this
    /// into the hold chip; a newer session's commit overwrites it. The target
    /// PID is snapshotted at stop time — by the time the text lands, a newer
    /// session may have re-captured the target.
    private struct CommittedTranscript {
        let session: SessionID
        let text: String
        let targetPID: pid_t?
    }
    private var committedTranscript: CommittedTranscript?
    /// A preserved transcript's hold chip is deferred while a newer session
    /// owns the capsule; surfaced the moment the machine rests.
    private var pendingHeldNotice = false
    /// Preserve effect fired BEFORE the text existed (interrupt during the
    /// ASR await): remember whose transcript to materialize when the task
    /// returns with text — even though the task was cancelled meanwhile.
    private var pendingPreserveSession: SessionID?

    private var isRecording: Bool { pttState.isRecording }
    private var isASRReady = false
    private var isASRSetupIssue = false
    private var asrRecordingBlockMessage = "Model loading..."
    private var isAudioReady = false
    private var pttDownTime: CFAbsoluteTime = 0
    private var startLatencyProbe: RecordingStartLatencyProbe?
    private var napActivity: NSObjectProtocol?
    private var cachedOnboardingSnapshot: OnboardingStatusSnapshot?
    private var cachedOnboardingSnapshotAt: Date?
    /// Freshness backstop; event-driven invalidation below is the primary mechanism.
    private static let onboardingSnapshotMaxAgeSeconds: TimeInterval = 2.0
    private var pttUpTime: CFAbsoluteTime = 0
    private var hotkeyConfiguration: PTTHotkeyConfiguration = .load()
    private var transcriptionTask: Task<Void, Never>?
    /// Mid-hold stall watchdog (Bluetooth-dropout hardening): warns live when
    /// tap callbacks stop arriving mid-recording. Cancelled on every stop,
    /// cancel, wake-teardown, and terminate path alongside transcriptionTask.
    private var micStallWatchdogTask: Task<Void, Never>?
    /// Audio teardown for the current stop/cancel (post-roll + drain + engine stop).
    /// New recordings await its completion before collecting, so sessions never
    /// overlap in the audio layer even when the transcription task is cancelled.
    private var recordingStopTask: Task<[Float], Never>?
    private var runtimePrepTask: Task<Void, Never>?
    /// Bounded-start pending state (engine-start freeze hardening): a press
    /// whose engine start is still in flight off-main. Between key-down and
    /// commit the PTT machine stays idle — key-up, Esc, a superseding press,
    /// quit, wake, or a device change during the window abandons the attempt
    /// instead of freezing or half-committing a session.
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartGeneration = 0
    private var recordingSessions = RecordingSessionTracker()
    private let ptt = PTTStateMachine()
    private var pttState = PTTStateMachine.State()
    
    private var settingsWC: NSWindowController?
    private var onboardingWC: NSWindowController?
    private var onboardingController: OnboardingFlowController?
    private var hotkeyObserver: NSObjectProtocol?
    private var modelsConfigObserver: NSObjectProtocol?
    private var modelsConfigCoalesceTask: Task<Void, Never>?
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
        
        // Register user defaults for ducking + Task-3 SNR tuning (retune path:
        // `defaults write singhkays.Kalam internal.latency.snr* …` then restart)
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
            LatencyTuningOptions.startStageTimingKey: true,
            LatencyTuningOptions.pasteSetVerifyTimeoutOverrideMsKey: 0,
            LatencyTuningOptions.snrAwareEnabledKey: LatencyTuningOptions.defaultSnrAwareEnabled,
            LatencyTuningOptions.snrTrustDbKey: LatencyTuningOptions.defaultSnrTrustDb,
            LatencyTuningOptions.snrAbsoluteCapMsKey: LatencyTuningOptions.defaultSnrAbsoluteCapMs,
            LatencyTuningOptions.snrQuietToStopMsKey: LatencyTuningOptions.defaultSnrQuietToStopMs,
            LatencyTuningOptions.snrRelativeCapKey: LatencyTuningOptions.defaultSnrRelativeCap,
            LatencyTuningOptions.snrFloorMarginDbKey: LatencyTuningOptions.defaultSnrFloorMarginDb,
            // Diagnostic console gating (default OFF): high-frequency audio /
            // enumeration telemetry. Enable with:
            // defaults write singhkays.Kalam internal.logging.verboseAudio -bool YES
            KalamDiagnosticFlags.verboseAudioKey: false
        ])

        // App Nap guard: defeats timer coalescing so hotkey handling stays
        // immediate. userInitiated ONLY - never block system/display sleep.
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Dictation hotkey responsiveness"
        )

        SystemAudioDucker.shared.initialize()
        overlay.setWaveformProvider { [weak self] in
            self?.audio.recentWaveform(sampleCount: 512) ?? []
        }
        overlay.setPasteHeldTranscriptAction { [weak self] in
            self?.pasteHeldTranscript()
        }
        // K-52 discard: clear the held-transcript slot without delivering.
        overlay.setDestroyHeldTranscriptAction { [weak self] in
            self?.discardHeldTranscript()
        }
        overlay.prewarm()

        // TEMP-DIAG-HALO (revert before commit): headless pill screenshot.
        // KALAM_DEBUG_PILL=1 shows the live recording pill with no audio/hotkey.
        if ProcessInfo.processInfo.environment["KALAM_DEBUG_PILL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.overlay.showRecording(isHoldMode: true)
            }
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
        warmupPostProcessing()
        
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Coalesce rapid posts (e.g. browsing the Step-3 picker fires
                // one per tap): cancel the pending run so snapshot refresh +
                // ASR prep execute once for the settled selection instead of
                // once per tap (~520ms of MainActor work each). Settings UI
                // itself updates synchronously via store ping and never waits
                // on this path.
                self.invalidateOnboardingSnapshot()
                self.modelsConfigCoalesceTask?.cancel()
                let run = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    // Refresh first so the UI reflects the new config immediately
                    // (availability is a fast disk check); ASR prep runs in the
                    // background, then a final refresh flips isASRReady.
                    self.refreshOnboardingState(reopenIfNeeded: false)
                    // Picker-only browsing with no models installed changes
                    // nothing the prep could act on (its model branch no-ops
                    // without an installed model): skip the audio/ASR prep +
                    // final refresh and spare ~60ms of MainActor work per
                    // settled tap. Any installed model restores the full
                    // sequence; rescan/folder-change paths are untouched.
                    let installed = ModelSetupSupport.installedModelVersions(in: ModelsConfiguration.load())
                    if !installed.isEmpty {
                        await self.prepareRuntimeIfPossible()
                        self.refreshOnboardingState(reopenIfNeeded: false)
                    }
                }
                self.modelsConfigCoalesceTask = run
                await run.value
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

        // Task 7 (K-58) FnUsageAdvisor removed 2026-10-02 with the Fn hotkey
        // option (owner: unreliable trigger) — the advisor only protected Fn
        // users, so it goes with the option. Karabiner launch/terminate
        // observers below were advisor-only and go too.
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
        // Termination must never wait on the audio stack: a HAL-wedged engine
        // start cannot block quit anymore. The pending attempt (if any) is
        // abandoned — it self-cleans or dies with the process.
        cancelPendingStartIfActive(reason: "quit")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Abandon any pending bounded start FIRST so an in-flight (possibly
        // HAL-wedged) attempt can never commit or surface UI during teardown.
        // Deliberately no engine.stop() here: the audio stack is the one thing
        // that can hang, and process death reclaims the mic indicator anyway.
        cancelPendingStartIfActive(reason: "terminate")
        transcriptionTask?.cancel()
        cancelMicStallWatchdog()
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
            self.hotkeyObserver = nil
        }
        if let modelsConfigObserver {
            NotificationCenter.default.removeObserver(modelsConfigObserver)
            self.modelsConfigObserver = nil
        }
        modelsConfigCoalesceTask?.cancel()
        modelsConfigCoalesceTask = nil
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
        // A pending bounded start is not yet a committed recording: abandon it
        // regardless of the escapeCancelsRecording setting (that setting gates
        // committed sessions only). The PTT machine was never advanced.
        if cancelPendingStartIfActive(reason: "escDuringPending") { return }
        // off-main post-processing: cheap checks FIRST — the global monitor fires on every
        // Escape keystroke system-wide, so the defaults load must sit
        // behind the isRecording gate.
        guard isRecording else { return }
        let settings = GeneralSettingsConfiguration.load()
        guard settings.escapeCancelsRecording else { return }
        // K-52: policy FIRST — the machine records the cancel for whatever is
        // live (P0 #2: Esc is no longer a silent no-op during transcription;
        // its cancelWork effect kills the in-flight ASR task) and, if text was
        // already delivered, parks it in the hold chip instead of destroying.
        dispatchLifecycle(.escPressed, context: "esc")
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

    /// First-use warmup for post-processing subsystems whose lazy init would
    /// otherwise land inside the FIRST dictation after every launch (measured
    /// 2026-08-25: cleanup+itn+dictionary stage 52 ms first press vs 5 ms warm,
    /// dominated by NSSpellChecker.shared first use in the grammar pass).
    /// Utility QoS, off the critical path; results discarded.
    private func warmupPostProcessing() {
        Task(priority: .utility) {
            _ = NemoTextProcessing.normalizeSentence("warmup one two three")
            #if canImport(AppKit)
            // Mirror the engine's grammar-pass call shape (checkString with
            // .spelling + .grammar) so the same subsystems initialize now.
            let checker = NSSpellChecker.shared
            let docTag = NSSpellChecker.uniqueSpellDocumentTag()
            _ = checker.check(
                "warmup sentence",
                range: NSRange(location: 0, length: 15),
                types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.union(.grammar).rawValue),
                options: nil,
                inSpellDocumentWithTag: docTag,
                orthography: nil,
                wordCount: nil
            )
            checker.closeSpellDocument(withTag: docTag)
            #endif
            await MainActor.run { [weak self] in
                self?.logger.info("Post-processing warmup complete")
            }
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
                // Same candidate walk as press time so preparedInputDeviceID already
                // matches the device the first press will request (early-return path).
                _ = try prepareAudioForRecording()
                isAudioReady = true
                // Task-1: fill the spare so the next press hits the pool.
                warmPool.prewarmNext()
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
        // Settings "Being heard" mic list live-refresh: the pane renders a cached
        // one-shot enumeration, so a device that connects while settings is open
        // (AirPods' input side registers seconds after Control Center says
        // "connected") would stay OFFLINE until the window was closed and
        // reopened. handleSystemWake delegates here, so wake is covered too.
        NotificationCenter.default.post(name: .audioDevicesDidChange, object: nil)
        // Bounded-start guard: if an off-main engine start is in flight —
        // exactly the device-churn scenario that wedged the HAL — abandon it
        // (it self-cleans) and DEFER the graph rebuild: prepare() must never
        // touch engine state concurrently. The invalidated flag makes the
        // next press rebuild the graph from fresh topology.
        if audio.isStartInFlight {
            audio.abandonPendingStart()
            audio.invalidatePreparedState()
            warmPool.invalidate(reason: "deviceChangeDuringStart")
            logger.info("Audio refresh deferred: engine start in flight; graph rebuilds on next press")
            invalidateOnboardingSnapshot()
            refreshOnboardingState(reopenIfNeeded: false)
            return
        }
        invalidateOnboardingSnapshot()
        // Normalize persisted priority list here (infrequent path) instead of on
        // every press — normalize itself enumerates CoreAudio.
        let loaded = MicrophonePriorityConfiguration.load()
        let normalized = MicrophoneDeviceService.normalize(config: loaded)
        if normalized != loaded {
            normalized.save()
        }
        audio.invalidatePreparedState()
        warmPool.invalidate(reason: "deviceChange")
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
        warmPool.invalidate(reason: "wake")
        logger.info("System wake: resetting PTT state and refreshing audio input")
        // A bounded start in flight across sleep cannot be trusted to commit:
        // abandon it (self-cleans) so the first post-wake press starts fresh.
        cancelPendingStartIfActive(reason: "wake")
        if isRecording {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            cancelMicStallWatchdog()
            dictationTargetPID = nil
            dictationTargetElement = nil
            // K-52: heldTranscript survives — same never-destroyed policy as
            // cancelRecording (a parked transcript is a settled session's).
            let audio = self.audio
            // Pin the teardown to the session being torn down on wake.
            let audioGeneration = audio.captureGeneration
            let stopTask = Task(priority: .userInitiated) { [audio, audioGeneration] in
                let samples = audio.finishStop(expectedGeneration: audioGeneration)
                return samples
            }
            recordingStopTask = stopTask
            overlay.hide()
        }
        // K-52: out-of-band reset — system wake tore the session down with no
        // lifecycle event in the vocabulary. The one sanctioned bypass of
        // dispatchLifecycle (logged alongside the wake line above).
        lifecycle = .idle
        pendingHeldNotice = false
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
                // The machine latches the pending start SYNCHRONOUSLY: the
                // bounded engine commit lands up to ~2 s later, and every key
                // event in that window must decide against the pending start
                // (stop press aborts; holdOrToggle quick release converts),
                // never against a stale idle machine.
                pttState.beginPending(triggerMode)
                // Bounded start runs async off-main (freeze hardening): the
                // hotkey loop stays responsive. The machine now routes
                // pending-window second presses to .stop, so this supersede
                // branch is belt-and-braces for any .start that slips through.
                if pendingStartTask != nil {
                    audio.abandonPendingStart()
                    pendingStartTask?.cancel()
                    pendingStartTask = nil
                    pendingStartGeneration &+= 1
                }
                pendingStartGeneration &+= 1
                let pendingGeneration = pendingStartGeneration
                pendingStartTask = Task { @MainActor [weak self] in
                    await self?.startRecording(triggerMode: triggerMode)
                    self?.clearPendingStart(generation: pendingGeneration)
                }
            case .stop:
                pttUpTime = now
                stopRecordingAndTranscribe()
            case .suppressNextKeyUp:
                pttState.suppressNextKeyUp()
            }
        }
    }

    private func resolvePriorityOrderedMicrophones() -> [MicrophoneDeviceDescriptor] {
        // Hot path (every press): single enumeration. Config normalization
        // (which itself enumerates) stays on the infrequent device-change path
        // so one press doesn't cost 2-3 full CoreAudio sweeps + log bursts.
        let config = MicrophonePriorityConfiguration.load()
        return MicrophoneDeviceService.mergedPriorityList(config: config)
            .filter(\.isAvailable)
    }

    private func prepareAudioForRecording() throws -> String? {
        let candidates = resolvePriorityOrderedMicrophones()
        for candidate in candidates {
            do {
                try audio.prepare(preferredInputDeviceID: candidate.deviceID, warmPool: warmPool)
                // Last-used convergence: a prepare that misses the spare
                // schedules nothing by itself, so nudge toward the just-used
                // device (no-op when fresh or when a refill is in flight).
                warmPool.ensureSpare(for: candidate.uid)
                return candidate.uid
            } catch {
                logger.warning("Audio input bind failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                continue
            }
        }
        try audio.prepare(preferredInputDeviceID: nil, warmPool: warmPool)
        warmPool.ensureSpare(for: nil)
        return nil
    }

    /// Rolls the machine's pending start back if the recording did not commit
    /// (guard failure, engine start failure/timeout/supersede, stale commit).
    /// A failed start leaves the machine idle — the pre-hardening contract.
    @discardableResult
    private func startRecording(triggerMode: PTTStateMachine.TriggerMode) async -> Bool {
        let started = await performStartRecording(triggerMode: triggerMode)
        if !started {
            pttState.rollbackPending()
        }
        return started
    }

    private func performStartRecording(triggerMode: PTTStateMachine.TriggerMode) async -> Bool {
        guard !isRecording else { return false }
        // K-52: superseding an in-flight transcription/paste is decided by the
        // lifecycle machine, not by an unconditional cancel here — the old
        // unconditional cancel vaporized a COMPLETED transcript in the rapid
        // re-record window (P0 #1). The machine's keyDown effect runs only if
        // the start below actually commits (dispatch after startCollecting).
        // failed-start hardening: never leave a previous session's paste target alive
        dictationTargetPID = nil
        dictationTargetElement = nil
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
        // K-52: identity for every lifecycle event of this session; minted
        // before the async legs so stale completions name their session.
        let sessionID = recordingSessions.currentSessionID ?? UUID()

        do {
            // Bounded start: the engine start runs off-main under a hard
            // deadline — a HAL wedged mid-start (USB device churn) can no
            // longer freeze the app. Timeout and abandonment behave exactly
            // like a thrown failure: mic error + PTT machine left idle +
            // immediate retry available on the next press.
            let startOutcome = await audio.startCollectingBounded()
            guard startOutcome == .started else {
                logger.warning("Audio collection start did not commit outcome=\(String(describing: startOutcome), privacy: .public)")
                // Superseded (key-up/Esc/supersede/device-change during the
                // window) is a silent no-op by design — the user canceled the
                // press; only genuine failures surface the mic error.
                if startOutcome != .superseded {
                    overlay.showError("Microphone unavailable", action: .openMicrophoneSettings, autoHideAfter: 4.0)
                }
                return false
            }
        } catch {
            logger.warning("Audio collection start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
            overlay.showError("Microphone unavailable", action: .openMicrophoneSettings, autoHideAfter: 4.0)
            return false
        }
        startLatencyProbe?.mark(.engineStarted)
        // Commit the machine's pending start. Latches the trigger mode the
        // pending window decided (holdOrToggle quick-tap converts hold→toggle
        // mid-flight). A false return means the pending start was rolled back
        // while the engine was starting (stop/Esc/wake/quit during the
        // window): the engine is live but the session is unwanted — tear it
        // down and drop everything silently.
        guard pttState.commitPending() else {
            audio.stopEngineFromStaleCommit()
            logger.debug("Stale recording commit dropped: pending start rolled back during engine start")
            return false
        }
        overlay.showRecording(isHoldMode: triggerMode == .hold)
        // K-52: the start committed — advance the machine (this is where a
        // superseded session's transcript gets preserved / its tasks killed).
        dispatchLifecycle(.keyDown(session: sessionID), context: "start")
        // Credit-on-start approximation: the recorder exposes no main-thread
        // first-buffer hook, so `warming` collapses here. The warming-state
        // policy (abandon / Esc) stays exercised headlessly in the machine
        // tests; `locked` mirrors the PTT trigger mode (toggle = latched).
        dispatchLifecycle(.captureStarted(session: sessionID, locked: triggerMode == .toggle), context: "capture")
        startLatencyProbe?.mark(.indicatorShown)
        if UserDefaults.standard.bool(forKey: LatencyTuningOptions.startStageTimingKey),
           let line = startLatencyProbe?.summaryLine() {
            // Task 0: route tag lets Appendix-B baseline rows filter by mic transport.
            logger.info("Recording start latency \(line, privacy: .public) transport=\(self.audio.lastSessionTiming.transportTag, privacy: .public)")
        }
        startLatencyProbe = nil
        // Mid-hold stall watchdog starts only on a committed recording (same
        // gate as the lifecycle machine advance below).
        startMicStallWatchdog(isHoldMode: triggerMode == .hold)

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

        // record-time paste target capture - deliberately AFTER the mic is live and
        // the indicator is up. Every AX reference involved is timeout-bounded
        // (AccessibilityFocusResolver bounds the system-wide query AND every
        // element it returns, so attribute reads cannot inherit the 6 s default).
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            switch AccessibilityFocusResolver.resolveFocusedElement(frontmostApp: frontmost) {
            case .success(let resolution):
                dictationTargetPID = frontmost.processIdentifier
                dictationTargetElement = resolution.element
                if KalamDiagnosticFlags.verboseAudio {
                    logger.debug("Dictation target captured appName=\(resolution.appName, privacy: .public) strategy=\(resolution.strategy, privacy: .public) pid=\(frontmost.processIdentifier, privacy: .public)")
                }
                overlay.refinePlacementIfMoved(focusHint: resolution.element)
            case .failure(let error):
                // partial-AX target capture no-op: partial-AX apps (e.g. Sublime Text) answer none of the AX
                // queries, but the pid alone still identifies the record-time target —
                // keep it so paste-time routing can reactivate this app instead of
                // degrading to frontmost-at-paste-time.
                dictationTargetPID = frontmost.processIdentifier
                dictationTargetElement = nil
                // Partial-AX apps answer none of the AX queries on every press —
                // expected, not a warning. Gated + deduped per pid per launch.
                if KalamDiagnosticFlags.verboseAudio,
                   Self.claimFirstPartialAXLog(pid: frontmost.processIdentifier) {
                    logger.debug("Dictation target element capture FAILED reason=\(error.reason, privacy: .public) pidKept=\(frontmost.processIdentifier, privacy: .public)")
                }
            }
        } else {
            dictationTargetPID = nil
            dictationTargetElement = nil
            logger.warning("Dictation target capture SKIPPED: no frontmost application")
        }
        // Task 5 (K-56): AX wake prefetch while the user is still speaking (not after transcript lands).
        // Lightweight, best-effort — warms the AX connection for the later Tier-1 SET.
        if let pid = dictationTargetPID {
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            // Fire and forget; no await, no log of transcript.
            _ = AccessibilityWaker.wakeIfNeeded(bundleID: bundleID, pid: pid)
        }
        return true
    }

    /// Sync (non-async) dedupe claim for the per-launch partial-AX log, so the
    /// NSLock calls stay legal under Swift concurrency: `startRecording` became
    /// async with the bounded-start hardening, and locking directly from an
    /// async context is unavailable.
    private static func claimFirstPartialAXLog(pid: Int32) -> Bool {
        loggedPartialAXPIDsLock.lock()
        defer { loggedPartialAXPIDsLock.unlock() }
        let seen = loggedPartialAXPIDs.contains(pid)
        if !seen { loggedPartialAXPIDs.insert(pid) }
        return !seen
    }
    
    /// Returns true when a pending bounded start was active and has been
    /// abandoned. Rolls the machine's pending state back (a pending start IS
    /// machine decision state since the freeze hardening) and abandons the
    /// in-flight — possibly HAL-wedged — attempt, which self-cleans in the
    /// recorder. On success the machine has already committed, so this is
    /// only reachable while pending.
    @discardableResult
    private func cancelPendingStartIfActive(reason: String) -> Bool {
        guard pendingStartTask != nil || pttState.isPending else { return false }
        pttState.rollbackPending()
        audio.abandonPendingStart()
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingStartGeneration &+= 1
        logger.debug("Pending engine start abandoned reason=\(reason, privacy: .public)")
        return true
    }

    /// A finished pending-start task clears itself only if it is still the
    /// current one — a superseding press already advanced the generation, so
    /// the stale task's exit must not clobber the new pending handle.
    private func clearPendingStart(generation: Int) {
        guard pendingStartGeneration == generation else { return }
        pendingStartTask = nil
    }

    /// Mid-hold stall watchdog (Bluetooth-dropout hardening). Polls the tap
    /// callback count after a start grace; on stall it replaces the recording
    /// pill with a mic error (with a mic-settings action) so the user can
    /// release and retry instead of dictating into a dead mic. On recovery it
    /// re-shows the recording pill (timer restarts — cosmetic, documented).
    /// Warn-only: capture, transcription, and paste behavior are unchanged.
    private func startMicStallWatchdog(isHoldMode: Bool) {
        cancelMicStallWatchdog()
        micStallWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(MicStallMonitor.graceMs) * 1_000_000)
            guard !Task.isCancelled, self.isRecording else { return }
            var monitor = MicStallMonitor()
            while !Task.isCancelled, self.isRecording {
                try? await Task.sleep(nanoseconds: UInt64(MicStallMonitor.pollIntervalMs) * 1_000_000)
                guard !Task.isCancelled, self.isRecording else { return }
                switch monitor.observe(count: self.audio.publishedCallbackCount()) {
                case .ok:
                    break
                case .warn:
                    // Warning level (not gated): visible at default log levels
                    // without verboseAudio, with a route-filterable transport tag.
                    self.logger.warning("Mic stall detected: no audio callbacks recently transport=\(self.audio.lastSessionTiming.transportTag, privacy: .public)")
                    self.overlay.showError("Microphone signal lost — check your AirPods", action: .openMicrophoneSettings, autoHideAfter: nil)
                case .recovered:
                    self.logger.info("Mic stall recovered; signal flowing again")
                    self.overlay.showRecording(isHoldMode: isHoldMode)
                }
            }
        }
    }

    private func cancelMicStallWatchdog() {
        micStallWatchdogTask?.cancel()
        micStallWatchdogTask = nil
    }

    private func stopRecordingAndTranscribe() {
        // A stop that lands in the bounded-start pending window aborts the
        // attempt: no engine session ever committed, so there is nothing to
        // transcribe — and per the silent-cancellation ruling, no toast. The
        // machine routes this press here precisely so it cannot be eaten by
        // a stale idle read (the holdOrToggle double-press regression).
        if pttState.isPending || pendingStartTask != nil {
            cancelPendingStartIfActive(reason: "stopDuringPending")
            return
        }
        guard isRecording else { return }
        pttState.recordingDidStop()
        cancelMicStallWatchdog()
        
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
        // K-52: identity of the session being stopped — carried into the
        // transcription task so every pipeline callback names its session.
        let stopSessionID = recordingSessions.currentSessionID ?? UUID()
        // Pin the audio stop to the capture session being stopped NOW, before
        // any suspension. A rapid re-record bumps this id; the stale stop will
        // then no-op instead of draining the new session.
        let audioGeneration = audio.captureGeneration

        // K-52: the unconditional cancels that lived here (and in
        // startRecording) are replaced by machine policy — a superseded
        // session's COMMITTED transcript is preserved, not vaporized (P0 #1);
        // an ASR-unfinished one is cancelled with its bytes discarded.
        dispatchLifecycle(.keyUp(session: stopSessionID), context: "stop")
        // K-52 (manual-gate finding): snapshot THIS session's paste target
        // now — a re-record re-captures the target before the interrupted
        // ASR returns, and the preserved text must promise the ORIGINAL app.
        let pasteTargetPID = self.dictationTargetPID

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
            // K-49: the tail-silence poll is the trailing-phoneme protection
            // (3 consecutive silent 20 ms windows + a small safety floor). The
            // old adaptive post-roll value is now the CEILING for the fixed
            // path; the SNR-aware policy (Task 3) extends it per room SNR.
            let segmentEstimateMs = Int((pttUp - pttDown) * 1000)
            let config = LatencyTuningOptions.postRollConfig(postRollMs: postRollMs, defaults: .standard)
            return await self.audio.stopWithEarlyExit(
                pinnedGeneration: audioGeneration,
                config: config,
                segmentEstimateMs: segmentEstimateMs
            )
        }
        recordingStopTask = stopTask
        
        // Run as an actor-inherited task instead of Task.detached so Swift 6 does not
        // send MainActor app state into an unisolated closure. Add post-roll to preserve trailing phonemes.
        transcriptionTask = Task(priority: .userInitiated) { [weak self, pttDown, pttUp, generation, stopTask, stopSessionID, pasteTargetPID] in
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
                if KalamDiagnosticFlags.verboseAudio {
                    self.logger.debug("Stop superseded by a newer recording; skipping transcription")
                }
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
            var sessionTimingExtras = ""
            if stageTimingEnabled {
                let st = self.audio.lastSessionTiming
                if let fb = st.firstBufferAt {
                    sessionTimingExtras += " pttDownToFirstBufferMs=\(max(0, Int((fb - pttDown) * 1000)))"
                    if let es = st.engineStartAt {
                        sessionTimingExtras += " engineStartToFirstBufferMs=\(max(0, Int((fb - es) * 1000)))"
                    }
                }
                sessionTimingExtras += " transport=\(st.transportTag)"
                // Task 3: tag post-roll mode + room SNR with the latency summary
                // (ring read-back SNR estimated at key-up; still 0 if fixed path).
                let snr = self.audio.lastPostRollSNR
                sessionTimingExtras += String(format: " roomSNR=%.1f", snr)
                // Derive mode from the last config's policy + SNR trust gate for
                // human-readable logs; exact effectiveMax is in the PostRoll log.
                let trustDb = LatencyTuningOptions.snrConstants(from: defaults).trustSnrDb
                let mode: String
                let awareEnabled: Bool = {
                    if UserDefaults.standard.object(forKey: LatencyTuningOptions.snrAwareEnabledKey) != nil {
                        return UserDefaults.standard.bool(forKey: LatencyTuningOptions.snrAwareEnabledKey)
                    }
                    return LatencyTuningOptions.defaultSnrAwareEnabled
                }()
                if !awareEnabled {
                    mode = "fixed"
                } else {
                    mode = snr < trustDb ? "snrAware-low" : "snrAware-trusted"
                }
                sessionTimingExtras += " postRollMode=\(mode)"
            }
            if KalamDiagnosticFlags.verboseAudio {
                self.logger.debug("Recording timing holdMs=\(Int(keyDownToUp * 1000), privacy: .public) keyUpToSamplesMs=\(Int(upToSamples * 1000), privacy: .public) postRollMs=\(postRollMs, privacy: .public)\(sessionTimingExtras, privacy: .public)")
            }
            stageMark("audio-stop+fetch")

            // Capture-pathology gate (Bluetooth-dropout hardening): when the
            // microphone delivered far less audio than the hold implies, or
            // near-total digital silence over a long capture, ASR would only
            // transcribe garbage — refuse to paste and point at the
            // microphone instead. Counts/levels only, never content.
            // Conservative by design: short holds always pass; downstream
            // stages still own quiet-but-real speech.
            let captureAssessment = CaptureHealthGuard.assess(
                stats: self.audio.lastCaptureStats, holdMs: segmentEstimateMs)
            guard captureAssessment.healthy else {
                // User-visible no-paste outcome: one info line with the reason.
                self.logger.info("Capture pathological reason=\(captureAssessment.reason?.logName ?? "unknown", privacy: .public) capturedMs=\(captureAssessment.capturedMs, privacy: .public) holdMs=\(captureAssessment.holdMs, privacy: .public) nonZeroPct=\(Int(captureAssessment.nonZeroRatio * 100), privacy: .public)")
                await MainActor.run {
                    self.dispatchLifecycle(.captureEnded(session: stopSessionID, result: .noSpeech), context: "capture-pathology")
                    self.overlay.showError("Microphone delivered no usable audio", action: .openMicrophoneSettings, autoHideAfter: 5.0)
                }
                return
            }
            
            // Trim with hysteresis/hangover/padding + conservative fallback
            // K-51: fused endpointing + peak normalization (one pass).
            let trimmed = SilenceTrimmer.trimAndNormalize(samples: samples, sampleRate: 16_000)
            // Pipeline telemetry (counts/timings only, never content): correlates
            // the SilenceTrimmer-category trim decision with this session so
            // user-provided logs can distinguish "trimmer cut speech" (low
            // keepPct on a short hold) from "mic delivered silence".
            let originalMs = Int(Double(samples.count) / 16_000.0 * 1000)
            let trimmedMs = Int(Double(trimmed.count) / 16_000.0 * 1000)
            let keepPct = samples.isEmpty ? 0 : Int(Double(trimmed.count) / Double(samples.count) * 100)
            if KalamDiagnosticFlags.verboseAudio {
                self.logger.debug("Trim summary originalMs=\(originalMs, privacy: .public) trimmedMs=\(trimmedMs, privacy: .public) keepPct=\(keepPct, privacy: .public) holdMs=\(segmentEstimateMs, privacy: .public)")
            }
            stageMark("trim")
            guard !trimmed.isEmpty else {
                // User-visible no-paste outcome: one info line with the reason.
                self.logger.info("No speech detected after trimming")
                await MainActor.run {
                    self.dispatchLifecycle(.captureEnded(session: stopSessionID, result: .noSpeech), context: "trim-empty")
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }

            // noise-clip ASR rejection: never feed noise-only clips to ASR — Parakeet TDT
            // hallucinates filler words ("yeah") on boosted room tone.
            // Telemetry reports the guard's floor/threshold/run so a rejected
            // quiet-voice clip (small floor-to-peak delta) reads differently
            // from true silence in user-provided logs. Counts/levels only.
            let guardDiag = SpeechQualityGuard.diagnose(samples: trimmed, sampleRate: 16_000)
            guard guardDiag.verdict else {
                // User-visible no-paste outcome: one info line with the reason.
                self.logger.info("Clip rejected by speech-quality guard floorDb=\(guardDiag.noiseFloorDb, privacy: .public) thresholdDb=\(guardDiag.speechThresholdDb, privacy: .public) peakDb=\(guardDiag.peakDb, privacy: .public) maxRun=\(guardDiag.maxRunWindows, privacy: .public)/\(guardDiag.requiredWindows, privacy: .public) windows=\(guardDiag.totalWindows, privacy: .public) trimmedMs=\(trimmedMs, privacy: .public) holdMs=\(segmentEstimateMs, privacy: .public)")
                await MainActor.run {
                    self.dispatchLifecycle(.captureEnded(session: stopSessionID, result: .noSpeech), context: "quality-reject")
                    self.overlay.showInfoAndAutoHide("No speech detected")
                }
                return
            }
            if KalamDiagnosticFlags.verboseAudio {
                self.logger.debug("Clip accepted by speech-quality guard floorDb=\(guardDiag.noiseFloorDb, privacy: .public) thresholdDb=\(guardDiag.speechThresholdDb, privacy: .public) peakDb=\(guardDiag.peakDb, privacy: .public) maxRun=\(guardDiag.maxRunWindows, privacy: .public)/\(guardDiag.requiredWindows, privacy: .public) windows=\(guardDiag.totalWindows, privacy: .public)")
            }
            
            do {
                // K-52: capture delivered → transcribing, then the ASR marker.
                await MainActor.run {
                    self.dispatchLifecycle(.captureEnded(session: stopSessionID, result: .delivered), context: "asr-in")
                    self.dispatchLifecycle(.asrStarted(session: stopSessionID), context: "asr-start")
                }
                // Normalize before ASR without spawning an extra child task; this keeps the
                // transcription flow inside one actor-inherited task for Swift 6 safety.
                let asrStart = CFAbsoluteTimeGetCurrent()
                var normalized = trimmed   // already peak-normalized by the fused trim stage
                
                // Ensure audio is at least 300ms (4800 samples at 16kHz) to avoid FluidAudio short-utterance rejection
                if normalized.count < 4800 {
                    normalized.append(contentsOf: [Float](repeating: 0.0, count: 4800 - normalized.count))
                }
                
                let text = try await self.asr.transcribe(samples: normalized)
                let asrEnd = CFAbsoluteTimeGetCurrent()
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty/whitespace-only ASR output is NOT committed: committing it
                // would enter `inserting` with no paste leg to rest it, leaving the
                // machine stuck in inserting and causing the next start to preserve
                // a phantom ("Earlier transcript ready" for nothing). Route to
                // done(empty) instead so the next session starts from rest.
                guard !trimmedText.isEmpty else {
                    // User-visible no-paste outcome: one info line with the reason.
                    self.logger.info("Empty transcription result; skipping paste")
                    await MainActor.run {
                        if self.pendingPreserveSession == stopSessionID {
                            self.pendingPreserveSession = nil
                        }
                        self.dispatchLifecycle(.asrFinished(session: stopSessionID, result: .empty), context: "asr-empty")
                        self.overlay.showInfoAndAutoHide("No speech detected")
                    }
                    return
                }
                // K-52 P0 #1 (manual-gate finding): text is COMMITTED the
                // moment ASR returns it — even if the task was cancelled
                // during the await. The old `guard !Task.isCancelled` here
                // discarded finished ASR output, which was the exact
                // destruction this machine exists to prevent. Cancellation
                // now only stops the paste leg, never the record of text.
                await MainActor.run {
                    self.committedTranscript = CommittedTranscript(session: stopSessionID, text: text, targetPID: pasteTargetPID)
                    self.dispatchLifecycle(.asrFinished(session: stopSessionID, result: .text(text)), context: "asr-done")
                    self.fulfillPendingPreservation(session: stopSessionID)
                }
                // K-52 (round-3 finding): the PASTE leg dies here, never the
                // record of text. Esc cancels the task (guard below stops
                // the leg); a re-record supersession no longer cancels —
                // instead the session-currency check diverts this stale leg
                // to the hold already fulfilled above.
                guard !Task.isCancelled,
                      recordingSessions.isCurrentSession(stopSessionID) else { return }
                stageMark("asr")
                
                // off-main post-processing: snapshot Sendable inputs on-main, run cleanup+ITN+
                // dictionary OFF the main actor, keep only counts in logs.
                // ValidationGate (kept, silent): validates TextCleanupEngine
                // output only (ITN/dictionary are curated); on reject the
                // processor falls back to raw. The K-55 auto-degrade trip
                // store + banner were removed 2026-10-02 (owner: unrequested
                // feature) — rejects fall back silently, every time.
                let baseCleanupConfig = ModelsConfiguration.load().textCleanup
                let processor = TranscriptPostProcessor(
                    cleanupConfig: baseCleanupConfig,
                    dictionaryEngine: CustomDictionaryManager.shared.currentCompiledEngine
                )
                let post = await Self.postProcessTranscript(processor, trimmedText)
                stageMark("cleanup+itn+dictionary")
                // Post-processing (cleanup gate fallback aside) can empty the text:
                // rest the machine instead of stranding it in inserting.
                if post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // User-visible no-paste outcome: one info line with the reason.
                    self.logger.info("Post-processed transcript empty; skipping paste")
                    await MainActor.run {
                        self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .empty), context: "post-empty")
                        self.overlay.showInfoAndAutoHide("No speech detected")
                    }
                    return
                }
                if KalamDiagnosticFlags.verboseAudio {
                    let gateReason: String
                    switch post.gateVerdict {
                    case .accept: gateReason = "accept"
                    case .reject(let r): gateReason = r
                    }
                    self.logger.debug("ValidationGate verdict=\(gateReason, privacy: .public) fallback=\(post.gateRawFallback, privacy: .public) lengthRatio=\(String(format: "%.2f", post.gateMetrics.lengthRatio), privacy: .public) containment=\(String(format: "%.2f", post.gateMetrics.tokenContainment), privacy: .public) trigram=\(post.gateMetrics.trigramOverlap.map { String(format: "%.2f", $0) } ?? "nil", privacy: .public) rawLen=\(trimmedText.count, privacy: .public) cleanedLen=\(post.text.count, privacy: .public)")
                }
                let asrMs = Int((asrEnd - asrStart) * 1000)
                let asrInputMs = Int(Double(normalized.count) / 16_000.0 * 1000)
                if KalamDiagnosticFlags.verboseAudio {
                    self.logger.debug("Transcription completed outputLength=\(post.text.count, privacy: .public) asrMs=\(asrMs, privacy: .public) asrInputMs=\(asrInputMs, privacy: .public) cleanupEdits=\(post.stats.totalEdits, privacy: .public) cleanupMs=\(Int(post.stats.durationMs), privacy: .public) grammarEdits=\(post.stats.grammarEdits, privacy: .public) grammarAttempted=\(post.stats.grammarAttempted, privacy: .public) grammarTimedOut=\(post.stats.grammarTimedOut, privacy: .public) grammarSkippedForLength=\(post.stats.grammarSkippedForLength, privacy: .public) itnSpansMasked=\(post.itnSpansMasked, privacy: .public) itnEnabled=\(post.itnEnabled, privacy: .public) itnAvailable=\(post.itnAvailable, privacy: .public) itnChanged=\(post.itnChanged, privacy: .public) itnMs=\(post.itnMs, privacy: .public) replacements=\(post.replacements, privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) gateFallback=\(post.gateRawFallback, privacy: .public)")
                }

                // K-50: route decided BEFORE the settle wait so only the
                // frontmost route pays it. One frontmost read feeds decision
                // AND logs (T14 invariant). Behavioral note (accepted): the
                // routing/frontmost read now happens ~50–80 ms earlier than
                // before; record-time capture semantics are unchanged.
                let frontmostPIDAtDecision = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let route = PasteService.PasteRouting.target(
                    capturedPID: self.dictationTargetPID,
                    capturedElement: self.dictationTargetElement,
                    frontmostPID: frontmostPIDAtDecision
                )
                let pidPostingEnabled = defaults.bool(forKey: LatencyTuningOptions.pidPasteEnabledKey)

                // Adaptive paste delay for routes that depend on the frontmost
                // app having settled: 50ms for short segments (<5s) or 80ms
                // otherwise. Captured routes skip it entirely.
                // Fallback on error: Retry after additional delay to approx. total 120ms.
                let pasteDelayShortMs = max(20, min(300, defaults.integer(forKey: LatencyTuningOptions.pasteDelayShortMsKey)))
                let pasteDelayLongMs = max(20, min(300, defaults.integer(forKey: LatencyTuningOptions.pasteDelayLongMsKey)))
                let pasteDelayMs: Double
                if PasteService.requiresFrontmostSettle(route) {
                    pasteDelayMs = Double(segmentEstimateMs) < 5000 ? Double(pasteDelayShortMs) : Double(pasteDelayLongMs)
                } else {
                    pasteDelayMs = 0
                    if KalamDiagnosticFlags.verboseAudio {
                        self.logger.debug("Paste settle skipped for captured route")
                    }
                }
                let fallbackTotalMs = max(pasteDelayMs, Double(max(20, min(500, defaults.integer(forKey: LatencyTuningOptions.pasteFallbackTotalMsKey)))))
                let pasteDelay = pasteDelayMs / 1000.0
                let fallbackAdditionalDelay = (fallbackTotalMs - pasteDelayMs) / 1000.0

                if pasteDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(pasteDelay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                guard self.recordingSessions.isCurrent(generation) else {
                    if KalamDiagnosticFlags.verboseAudio {
                        self.logger.debug("Paste suppressed: recording superseded by a newer session")
                    }
                    return
                }
                stageMark("paste-wait")

                do {
                    switch route {
                    case .frontmost:
                        if KalamDiagnosticFlags.verboseAudio {
                            self.logger.debug("Paste route=frontmost capturedPID=\(self.dictationTargetPID.map { String($0) } ?? "nil", privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        }
                        try await self.paster.paste(post.text, preferPid: self.dictationTargetPID, pidPostingEnabled: pidPostingEnabled)
                    case .capturedElement(let element):
                        // record-time paste target capture: the user switched apps while transcribing — insert into the
                        // record-time target (bypasses the pasteboard entirely).
                        if KalamDiagnosticFlags.verboseAudio {
                            self.logger.debug("Paste route=capturedElement capturedPID=\(self.dictationTargetPID.map { String($0) } ?? "nil", privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        }
                        do {
                            try await self.paster.paste(into: element, text: post.text)
                        } catch {
                            // The captured target is gone (app quit / field closed): hold the
                            // transcript with a notice instead of pasting into the wrong app.
                            self.heldTranscript = post.text
                            self.heldTranscriptTargetPID = self.dictationTargetPID
                            self.heldTranscriptSession = stopSessionID
                            self.dictationTargetElement = nil
                            self.dictationTargetPID = nil
                            let promisedName = NSRunningApplication(processIdentifier: self.heldTranscriptTargetPID ?? 0)?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
                            await MainActor.run {
                                self.overlay.showHeldTranscript(message: "Transcript ready. Paste into \(promisedName)?")
                            }
                            // The captured target is gone: hold the transcript with a
                            // user-visible notice. Rare + user-visible: info.
                            self.logger.info("Captured-target paste failed; transcript held errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                            self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .held), context: "captured-element-held")
                            return
                        }
                    case .capturedApp(let capturedPid):
                        // partial-AX target capture no-op Option A: the record-time app has partial AX support (no
                        // element), so bring it back to front and paste via the normal
                        // path. If it cannot be reactivated or won't settle as frontmost,
                        // hold the transcript for the promised app (the Paste button will
                        // retry activation there).
                        if KalamDiagnosticFlags.verboseAudio {
                            self.logger.debug("Paste route=capturedApp capturedPID=\(capturedPid, privacy: .public) frontmostPIDAtDecision=\(frontmostPIDAtDecision.map { String($0) } ?? "nil", privacy: .public)")
                        }
                        guard await self.activateCapturedApp(capturedPid) != nil,
                              await self.waitForFrontmost(pid: capturedPid) else {
                            self.heldTranscript = post.text
                            self.heldTranscriptTargetPID = capturedPid
                            self.heldTranscriptSession = stopSessionID
                            let appName = NSRunningApplication(processIdentifier: capturedPid)?.localizedName ?? "the original app"
                            await MainActor.run {
                                self.overlay.showHeldTranscript(message: "Transcript ready. Paste into \(appName)?")
                            }
                            self.logger.warning("Captured-app activation failed; transcript held pid=\(capturedPid, privacy: .public)")
                            self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .held), context: "captured-app-held")
                            return
                        }
                        try await self.paster.paste(post.text)
                    }
                    if self.heldTranscriptSession == stopSessionID {
                        // Ownership-scoped cleanup: clear only THIS session's
                        // hold slot. A preserved transcript from a superseded
                        // session (different tag) survives — never-destroyed.
                        self.heldTranscript = nil
                        self.heldTranscriptTargetPID = nil
                        self.heldTranscriptSession = nil
                    }
                    self.dictationTargetElement = nil
                    self.dictationTargetPID = nil
                    self.overlay.hide() // Silent success (D-1): pasted text in the target app IS the confirmation
                    self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .pasted), context: "paste-ok")
                    stageMark("paste-dispatch")
                    if stageTimingEnabled {
                        let totalMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000.0
                        self.logger.debug("Latency summary pasteDispatchMs=\(Int(totalMs), privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public) pasteDelayMs=\(Int(pasteDelayMs), privacy: .public)")
                    }
                    if KalamDiagnosticFlags.verboseAudio {
                        self.logger.debug("Paste dispatched via initial path delayMs=\(Int(pasteDelay * 1000), privacy: .public)")
                    }
                } catch {
                    // Task 5 (K-56): Tier-1 hard refusals never blind-paste or fallback — hold.
                    if let pasteError = error as? PasteServiceError {
                        switch pasteError {
                        case .secureField, .secureInputActive, .pidMismatch, .frontmostChanged:
                            self.heldTranscript = post.text
                            self.heldTranscriptTargetPID = self.dictationTargetPID
                            self.heldTranscriptSession = stopSessionID
                            self.dictationTargetElement = nil
                            self.dictationTargetPID = nil
                            let reason: String
                            switch pasteError {
                            case .secureField: reason = "Secure field"
                            case .secureInputActive: reason = "Secure input active"
                            case .pidMismatch: reason = "PID mismatch"
                            case .frontmostChanged: reason = "Frontmost changed"
                            default: reason = "Hold"
                            }
                            let promisedName = NSRunningApplication(processIdentifier: self.heldTranscriptTargetPID ?? 0)?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
                            await MainActor.run {
                                self.overlay.showHeldTranscript(message: "\(reason) — transcript ready. Paste into \(promisedName)?")
                            }
                            self.logger.warning("Tier-1 hard refusal hold reason=\(reason, privacy: .public) errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                            self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .held), context: "tier1-hold")
                            return
                        default: break
                        }
                    }
                    self.logger.warning("Initial paste failed delayMs=\(Int(pasteDelay * 1000), privacy: .public) errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                    try await Task.sleep(nanoseconds: UInt64(max(0, fallbackAdditionalDelay) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    stageMark("paste-fallback-wait")

                    do {
                        try await self.paster.paste(post.text)
                        self.overlay.hide() // Silent success (D-1): pasted text in the target app IS the confirmation
                        self.dispatchLifecycle(.insertSucceeded(session: stopSessionID, outcome: .pasted), context: "paste-fallback-ok")
                        stageMark("paste-fallback-dispatch")
                        if stageTimingEnabled {
                            let totalMs = (CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000.0
                            self.logger.debug("Latency summary pasteFallbackDispatchMs=\(Int(totalMs), privacy: .public) segmentEstimateMs=\(segmentEstimateMs, privacy: .public) postRollMs=\(postRollMs, privacy: .public) fallbackTotalMs=\(Int(fallbackTotalMs), privacy: .public)")
                        }
                        if KalamDiagnosticFlags.verboseAudio {
                            self.logger.debug("Fallback paste dispatched totalDelayMs=\(Int((pasteDelay + fallbackAdditionalDelay) * 1000), privacy: .public)")
                        }
                    } catch {
                        self.logger.warning("Fallback paste failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                        await MainActor.run {
                            self.overlay.showError("Enable Accessibility to paste", action: .openAccessibilitySettings, autoHideAfter: 4.0)
                            AccessibilityHelper.explainAccessibilityIfNeeded()
                        }
                        // K-52: paste failed — park the committed transcript via
                        // the machine (inserting → done(.held), notice .never:
                        // the accessibility surface owns the user's attention).
                        dispatchLifecycle(.insertFailed(session: stopSessionID), context: "paste-fallback-fail")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.logger.warning("Transcription failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
                await MainActor.run {
                    // K-52: failure routed by phase — ASR-unfinished maps to
                    // asrFailed (no transcript existed); a paste-stage failure
                    // parks the committed transcript instead of dropping it.
                    if case .transcribing = self.lifecycle {
                        self.dispatchLifecycle(.asrFinished(session: stopSessionID, result: .failed), context: "asr-fail")
                    } else {
                        self.dispatchLifecycle(.insertFailed(session: stopSessionID), context: "insert-fail")
                    }
                    self.overlay.showError("Transcription failed", action: nil, autoHideAfter: 4.0)
                }
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        pttState.recordingDidStop()
        cancelMicStallWatchdog()

        // record-time paste target capture: a canceled session must not retain its paste target.
        // K-52: heldTranscript is deliberately NOT cleared here — a preserved
        // transcript from a superseded session must survive a later cancel
        // (the machine's never-destroyed policy).
        dictationTargetPID = nil
        dictationTargetElement = nil

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
            let samples = audio.finishStop(expectedGeneration: audioGeneration)
            return samples
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

    // MARK: - K-52 lifecycle plumbing

    /// Single mutation point for the dictation lifecycle: applies the pure
    /// machine, then realizes its ordered effects against app state. Illegal
    /// and stale events change nothing (machine contract).
    private func dispatchLifecycle(_ event: DictationEvent, context: String) {
        let diagnostics = UserDefaults.standard.bool(forKey: LatencyTuningOptions.enableStageTimingKey)
        let before = lifecycle
        guard let transition = DictationStateMachine.transition(lifecycle, event) else {
            if diagnostics {
                logger.debug("Lifecycle drop ctx=\(context, privacy: .public) state=\(before, privacy: .public) event=\(event, privacy: .public)")
            }
            return
        }
        lifecycle = transition.next

        for effect in transition.effects {
            switch effect {
            case .preserveTranscript(let session, let notice):
                // Materialize the committed text into the hold chip — never
                // destroy. Text lives app-side (`committedTranscript`); if it
                // has not landed yet (interrupt during the ASR await), record
                // the intent — `fulfillPendingPreservation` completes it when
                // the task returns with text despite being cancelled.
                // Defense-in-depth for the empty-transcript phantom: whitespace-only
                // commits are never materialized and never arm a notice.
                if let committed = committedTranscript, committed.session == session {
                    if committed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if heldTranscriptSession == session {
                            heldTranscript = nil
                            heldTranscriptTargetPID = nil
                            heldTranscriptSession = nil
                        }
                        if pendingPreserveSession == session {
                            pendingPreserveSession = nil
                        }
                    } else {
                        heldTranscript = committed.text
                        heldTranscriptTargetPID = committed.targetPID
                        heldTranscriptSession = session
                        switch notice {
                        case .now, .deferredUntilSettled:
                            pendingHeldNotice = true
                        case .never:
                            break
                        }
                    }
                } else {
                    pendingPreserveSession = session
                    switch notice {
                    case .now, .deferredUntilSettled:
                        pendingHeldNotice = true
                    case .never:
                        break
                    }
                }
            case .cancelWork:
                transcriptionTask?.cancel()
            case .discardAudio:
                // Buffers are session-scoped inside the recorder and never
                // persisted; nothing is retained across sessions to wipe.
                break
            }
        }

        settlePendingHeldNotice()

        if diagnostics {
            logger.info("Lifecycle ctx=\(context, privacy: .public) \(before, privacy: .public) -> \(self.lifecycle, privacy: .public) effects=\(transition.effects.count, privacy: .public)")
        }
    }

    /// Completes a deferred preserve: the interrupted task's ASR returned
    /// text after the preserve effect already fired. Runs on MainActor.
    private func fulfillPendingPreservation(session: SessionID) {
        guard pendingPreserveSession == session,
              let committed = committedTranscript, committed.session == session else { return }
        // Empty commits (whitespace-only) never become a hold — clear the intent.
        guard !committed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingPreserveSession = nil
            return
        }
        pendingPreserveSession = nil
        heldTranscript = committed.text
        heldTranscriptTargetPID = committed.targetPID
        heldTranscriptSession = session
        // Rare + user-visible (a held chip follows): info, not gated.
        logger.info("Lifecycle deferred preserve fulfilled session=\(String(session.uuidString.prefix(8)), privacy: .public)")
        // Surface the chip now if the machine is at rest; otherwise defer to
        // the next settle (a newer session may still own the overlay — its
        // settle pass picks the notice up once it rests).
        if lifecycle.phase == nil {
            let promisedName = NSRunningApplication(processIdentifier: heldTranscriptTargetPID ?? 0)?.localizedName
                ?? NSWorkspace.shared.frontmostApplication?.localizedName
                ?? "the frontmost app"
            overlay.showHeldTranscript(message: "Earlier transcript ready. Paste into \(promisedName)?")
        } else {
            pendingHeldNotice = true
        }
    }

    /// Surfaces a deferred hold chip the moment the machine rests.
    private func settlePendingHeldNotice() {
        guard pendingHeldNotice, lifecycle.phase == nil else { return }
        pendingHeldNotice = false
        guard let held = heldTranscript,
              !held.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Drop phantom holds (empty/whitespace) instead of surfacing a chip.
            if heldTranscript != nil {
                heldTranscript = nil
                heldTranscriptTargetPID = nil
                heldTranscriptSession = nil
            }
            return
        }
        let promisedName = NSRunningApplication(processIdentifier: heldTranscriptTargetPID ?? 0)?.localizedName
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "the frontmost app"
        overlay.showHeldTranscript(message: "Earlier transcript ready. Paste into \(promisedName)?")
    }

    /// partial-AX target capture no-op: activate another app from a background/menu-bar context. Plain
    /// `NSRunningApplication.activate()` is routinely refused by TCC for
    /// non-frontmost apps (observed live 2026-08-24: "activation refused");
    /// the LaunchServices route carries the user-intent semantics needed here.
    @MainActor
    private func activateCapturedApp(_ pid: pid_t) async -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if app.activate() { return app }
        if KalamDiagnosticFlags.verboseAudio {
            logger.debug("Plain activate refused; trying LaunchServices openApplication pid=\(pid, privacy: .public)")
        }
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
        guard let text = heldTranscript,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let promisedPID = heldTranscriptTargetPID
        let ownerSession = heldTranscriptSession
        heldTranscript = nil
        heldTranscriptTargetPID = nil
        heldTranscriptSession = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let promisedPID, NSRunningApplication(processIdentifier: promisedPID) != nil {
                guard await self.activateCapturedApp(promisedPID) != nil,
                      await self.waitForFrontmost(pid: promisedPID) else {
                    let appName = NSRunningApplication(processIdentifier: promisedPID)?.localizedName ?? "the app"
                    self.logger.warning("Held-transcript reactivation failed pid=\(promisedPID, privacy: .public)")
                    self.overlay.showError("Could not bring \(appName) to front", action: nil, autoHideAfter: 4.0)
                    // Never-destroyed: restore the slot so Paste can be retried.
                    self.heldTranscript = text
                    self.heldTranscriptTargetPID = promisedPID
                    self.heldTranscriptSession = ownerSession
                    return
                }
            }
            do {
                try await self.paster.paste(text)
                self.overlay.hide() // Silent success (D-1): pasted text in the target app IS the confirmation
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

    /// K-52 discard: clear the held-transcript slot WITHOUT delivering it. The
    /// user chose not to paste the preserved (earlier) transcript. Leaves no
    /// trace, consistent with the zero-retention posture for discarded text.
    private func discardHeldTranscript() {
        heldTranscript = nil
        heldTranscriptTargetPID = nil
        heldTranscriptSession = nil
        pendingPreserveSession = nil
        pendingHeldNotice = false
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
