import SwiftUI
import AVFoundation
import AppKit
import OSLog



struct OnboardingConfiguration: Equatable {
    static let defaults = OnboardingConfiguration(
        hasCompletedRequiredSetup: false,
        hasAttemptedAccessibilitySetup: false,
        hasPickedHotkey: false,
        hasConfirmedHFCLIInstall: false,
        hasConfirmedModelLocation: false
    )

    var hasCompletedRequiredSetup: Bool
    var hasAttemptedAccessibilitySetup: Bool
    var hasPickedHotkey: Bool
    var hasConfirmedHFCLIInstall: Bool
    /// Set when the user confirms the model library location during a first
    /// run (the model card's Continue). Drives the router's model
    /// acknowledgment stop: a carried-over model must be shown once, then
    /// never re-asked. Cleared by `reset()` so DEBUG rehearsals replay it.
    var hasConfirmedModelLocation: Bool

    private static let hasCompletedRequiredSetupKey = "internal.hasCompletedRequiredSetup"
    private static let hasAttemptedAccessibilitySetupKey = "internal.hasAttemptedAccessibilitySetup"
    private static let hasPickedHotkeyKey = "internal.hasPickedHotkey"
    private static let hasConfirmedHFCLIInstallKey = "internal.hasConfirmedHFCLIInstall"
    private static let hasConfirmedModelLocationKey = "internal.hasConfirmedModelLocation"
    private static let debugFreshStartKey = "internal.debugFreshStart"

    static func load(from defaults: UserDefaults = .standard) -> OnboardingConfiguration {
        OnboardingConfiguration(
            hasCompletedRequiredSetup: bool(
                forKey: hasCompletedRequiredSetupKey,
                defaults: defaults,
                fallback: Self.defaults.hasCompletedRequiredSetup
            ),
            hasAttemptedAccessibilitySetup: bool(
                forKey: hasAttemptedAccessibilitySetupKey,
                defaults: defaults,
                fallback: Self.defaults.hasAttemptedAccessibilitySetup
            ),
            hasPickedHotkey: bool(
                forKey: hasPickedHotkeyKey,
                defaults: defaults,
                fallback: false
            ),
            hasConfirmedHFCLIInstall: bool(
                forKey: hasConfirmedHFCLIInstallKey,
                defaults: defaults,
                fallback: Self.defaults.hasConfirmedHFCLIInstall
            ),
            hasConfirmedModelLocation: bool(
                forKey: hasConfirmedModelLocationKey,
                defaults: defaults,
                fallback: Self.defaults.hasConfirmedModelLocation
            )
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(hasCompletedRequiredSetup, forKey: Self.hasCompletedRequiredSetupKey)
        defaults.set(hasAttemptedAccessibilitySetup, forKey: Self.hasAttemptedAccessibilitySetupKey)
        defaults.set(hasPickedHotkey, forKey: Self.hasPickedHotkeyKey)
        defaults.set(hasConfirmedHFCLIInstall, forKey: Self.hasConfirmedHFCLIInstallKey)
        defaults.set(hasConfirmedModelLocation, forKey: Self.hasConfirmedModelLocationKey)
    }

    static func reset(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hasCompletedRequiredSetupKey)
        defaults.removeObject(forKey: hasAttemptedAccessibilitySetupKey)
        defaults.removeObject(forKey: hasPickedHotkeyKey)
        defaults.removeObject(forKey: hasConfirmedHFCLIInstallKey)
        defaults.removeObject(forKey: hasConfirmedModelLocationKey)
    }

    /// Marks the next onboarding window open as a fresh start. Set by the DEBUG
    /// reset so the deck opens on the welcome card even though a non-destructive
    /// reset keeps microphone/hotkey config intact (the model LOCATION is
    /// cleared too — see `resetAllOnboardingState()`). Consumed once, on read.
    static func requestDebugFreshStart(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: debugFreshStartKey)
    }

    /// Reads the fresh-start flag WITHOUT clearing it (survives window
    /// reopen until `clearDebugFreshStart()` runs on leaving welcome).
    static func peekDebugFreshStart(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: debugFreshStartKey)
    }

    /// Clears the fresh-start flag once setup has actually begun.
    static func clearDebugFreshStart(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: debugFreshStartKey)
    }

    private static func bool(forKey key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

enum OnboardingMode: Equatable {
    case firstRun
    case repair

    var windowTitle: String {
        switch self {
        case .firstRun:
            return "Welcome to Kalam"
        case .repair:
            return "Kalam Needs Attention"
        }
    }
}

enum OnboardingRequirement: CaseIterable, Equatable {
    case microphone
    case accessibility
    case hotkey
    case model
}

enum OnboardingRequirementStatus: Equatable {
    case notDetermined(message: String)
    case actionRequired(message: String)
    case pendingExternal(message: String)
    case pendingRelaunch(message: String)
    case denied(message: String)
    case invalid(message: String)
    case ready(message: String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var isNotDetermined: Bool {
        if case .notDetermined = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .notDetermined(let message),
             .actionRequired(let message),
             .pendingExternal(let message),
             .pendingRelaunch(let message),
             .denied(let message),
             .invalid(let message),
             .ready(let message):
            return message
        }
    }
}

enum AccessibilitySetupState: Equatable {
    case idle
    case needsExternalEnable
    case enabledPendingRelaunch
}

struct OnboardingStatusSnapshot: Equatable {
    let mode: OnboardingMode
    let microphoneStatus: OnboardingRequirementStatus
    let accessibilityStatus: OnboardingRequirementStatus
    let hotkeyStatus: OnboardingRequirementStatus
    let storageFolderStatus: OnboardingRequirementStatus
    let modelStatus: OnboardingRequirementStatus
    
    let selectedMicrophoneName: String?
    let selectedHotkeyDisplay: String
    let selectedModelVersion: ASRModelVersion
    let installedModelVersions: [ASRModelVersion]
    let modelAvailability: ASRModelAvailability
    let modelLibraryURL: URL?
    /// Whether the user has confirmed the model location during this first
    /// run. Drives the router's one-time model acknowledgment stop for
    /// carried-over installs; irrelevant once setup is complete (repair mode
    /// routes by broken gates only). Var: `confirmModelLocation()` flips it
    /// synchronously on the controller's copy so the Continue press advances
    /// against the confirmed state before the app-wide refresh lands.
    var hasConfirmedModelLocation: Bool
    let isAudioReady: Bool
    let isASRReady: Bool

    var completedRequirements: Int {
        [microphoneStatus, accessibilityStatus, hotkeyStatus, modelStatus].filter(\.isReady).count
    }

    var hasIncompleteRequirements: Bool {
        completedRequirements < 4
    }

    var canStartDictating: Bool {
        completedRequirements == 4 && isAudioReady && isASRReady
    }

    var isStartDictatingDisabled: Bool {
        !canStartDictating
    }

    var runtimePreparationMessage: String? {
        if completedRequirements == 4 {
            if !isAudioReady {
                return "Preparing microphone…"
            }
            if !isASRReady {
                return "Preparing dictation engine…"
            }
            return nil
        }
        // First-run folder-pick: the model files are already present but the
        // engine is still loading in the background — surface that progress
        // even before the remaining requirements are complete, instead of
        // leaving the window looking frozen on "Choose Folder…".
        if modelStatus.isReady && !isASRReady {
            return "Preparing dictation engine…"
        }
        return nil
    }

    var brokenRequirements: Set<OnboardingRequirement> {
        var broken: Set<OnboardingRequirement> = []
        if !microphoneStatus.isReady {
            broken.insert(.microphone)
        }
        if !accessibilityStatus.isReady {
            broken.insert(.accessibility)
        }
        if !hotkeyStatus.isReady {
            broken.insert(.hotkey)
        }
        if !modelStatus.isReady {
            broken.insert(.model)
        }
        return broken
    }

    static func evaluate(
        microphoneAuthorization: AVAuthorizationStatus,
        selectedMicrophoneName: String?,
        accessibilityTrusted: Bool,
        hasAttemptedAccessibilitySetup: Bool,
        hotkeyConfig: PTTHotkeyConfiguration,
        hasPickedHotkey: Bool,
        selectedModelVersion: ASRModelVersion,
        modelLibraryURL: URL?,
        selectedModelAvailability: ASRModelAvailability,
        installedModelVersions: [ASRModelVersion],
        hasCompletedRequiredSetup: Bool,
        hasConfirmedModelLocation: Bool,
        isAudioReady: Bool,
        isASRReady: Bool
    ) -> OnboardingStatusSnapshot {
        let microphoneStatus: OnboardingRequirementStatus
        switch microphoneAuthorization {
        case .authorized:
            microphoneStatus = .ready(message: "Allowed")
        case .notDetermined:
            microphoneStatus = .actionRequired(message: "Needs access to hear your voice.")
        case .denied, .restricted:
            microphoneStatus = .denied(message: "Access denied. Please enable in System Settings.")
        @unknown default:
            microphoneStatus = .denied(message: "Access denied. Please enable in System Settings.")
        }

        let accessibilityStatus: OnboardingRequirementStatus =
            accessibilityTrusted
            ? .ready(message: "Granted")
            : (
                hasAttemptedAccessibilitySetup
                ? .pendingExternal(message: "Kalam still can't verify Accessibility access. Confirm the switch is on in System Settings. If it is already on, restart Kalam and return here.")
                : .actionRequired(message: "Required to type text into other applications.")
            )

        let hotkeyStatus: OnboardingRequirementStatus =
            hasPickedHotkey
            ? .ready(message: "Shortcut: \(hotkeyConfig.displayString)")
            : .actionRequired(message: "Choose a key combination to trigger dictation.")

        let storageFolderStatus: OnboardingRequirementStatus
        if let modelLibraryURL = modelLibraryURL {
            storageFolderStatus = .ready(message: modelLibraryURL.path)
        } else {
            storageFolderStatus = .actionRequired(message: "Kalam runs securely on-device. Choose a folder to store your dictation models.")
        }

        let modelStatus: OnboardingRequirementStatus
        switch selectedModelAvailability {
        case .installed:
            modelStatus = .ready(message: "Downloaded and ready")
        case .modelLibraryNotConfigured:
            modelStatus = .actionRequired(message: "Set up your local speech model for on-device dictation.")
        case .missingModelFolder, .invalidModelFolder:
            modelStatus = .notDetermined(message: "Finish setting up your local speech model.")
        case .partial(_, let missing, let total):
            modelStatus = .notDetermined(message: "\(total - missing.count) of \(total) model files arrived. Run the download command again; it skips files already on disk.")
        }

        let mode: OnboardingMode = hasCompletedRequiredSetup ? .repair : .firstRun

        return OnboardingStatusSnapshot(
            mode: mode,
            microphoneStatus: microphoneStatus,
            accessibilityStatus: accessibilityStatus,
            hotkeyStatus: hotkeyStatus,
            storageFolderStatus: storageFolderStatus,
            modelStatus: modelStatus,
            selectedMicrophoneName: selectedMicrophoneName,
            selectedHotkeyDisplay: hotkeyConfig.displayString,
            selectedModelVersion: selectedModelVersion,
            installedModelVersions: installedModelVersions,
            modelAvailability: selectedModelAvailability,
            modelLibraryURL: modelLibraryURL,
            hasConfirmedModelLocation: hasConfirmedModelLocation,
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }

    func updatingModelStatus(version: ASRModelVersion, availability: ASRModelAvailability) -> OnboardingStatusSnapshot {
        let newModelStatus: OnboardingRequirementStatus
        switch availability {
        case .installed:
            newModelStatus = .ready(message: "Downloaded and ready")
        case .modelLibraryNotConfigured:
            newModelStatus = .actionRequired(message: "Set up your local speech model for on-device dictation.")
        case .missingModelFolder, .invalidModelFolder:
            newModelStatus = .notDetermined(message: "Finish setting up your local speech model.")
        case .partial(_, let missing, let total):
            newModelStatus = .notDetermined(message: "\(total - missing.count) of \(total) model files arrived. Run the download command again; it skips files already on disk.")
        }
        
        return OnboardingStatusSnapshot(
            mode: mode,
            microphoneStatus: microphoneStatus,
            accessibilityStatus: accessibilityStatus,
            hotkeyStatus: hotkeyStatus,
            storageFolderStatus: storageFolderStatus,
            modelStatus: newModelStatus,
            selectedMicrophoneName: selectedMicrophoneName,
            selectedHotkeyDisplay: selectedHotkeyDisplay,
            selectedModelVersion: version,
            installedModelVersions: installedModelVersions,
            modelAvailability: availability,
            modelLibraryURL: modelLibraryURL,
            // A version swap doesn't change whether the user confirmed the
            // library location this run.
            hasConfirmedModelLocation: hasConfirmedModelLocation,
            isAudioReady: isAudioReady,
            isASRReady: false // Reset ASR readiness as we switched models
        )
    }
}

@MainActor
final class OnboardingFlowController: ObservableObject {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "Onboarding")
    @Published private(set) var snapshot: OnboardingStatusSnapshot
    @Published var selectedDownloadVersion: ASRModelVersion {
        didSet {
            if oldValue != selectedDownloadVersion {
                downloadCommandCopied = false
                
                // Update global configuration so availability checks and download 
                // commands reflect the newly selected version.
                var config = ModelsConfiguration.load()
                if config.asrVersion != selectedDownloadVersion {
                    config.asrVersion = selectedDownloadVersion
                    config.save()
                    
                    // Locally update the snapshot for immediate UI feedback.
                    // This ensures the checkmarks and status messages update instantly.
                    let availability = config.availability(for: selectedDownloadVersion)
                    self.snapshot = snapshot.updatingModelStatus(
                        version: selectedDownloadVersion,
                        availability: availability
                    )

                    // Notify the app that the configuration changed. 
                    // This triggers prepareRuntimeIfPossible and refreshOnboardingState in KalamApp.
                    NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
                }
            }
        }
    }
    @Published private(set) var accessibilitySetupState: AccessibilitySetupState = .idle
    @Published private(set) var installCommandCopied = false
    @Published private(set) var downloadCommandCopied = false

    private let requestMicrophoneAccessAction: () -> Void
    private let refreshAction: () -> Void
    private let openSettingsAction: () -> Void
    private let requestAccessibilityAccessAction: () -> Void
    private let openAccessibilitySettingsAction: () -> Void
    private let accessibilityTrustCheck: () -> Bool
    private let relaunchAppAction: () -> Void
    private let startDictationAction: () -> Void
    private let selectMicrophoneAction: (MicrophoneDeviceDescriptor) -> Void
    private let clearMicrophoneSelectionAction: () -> Void
    private let availableMicrophoneDevicesAction: () -> [MicrophoneDeviceDescriptor]
    private let loadHotkeyConfiguration: () -> PTTHotkeyConfiguration
    private let saveHotkeyConfiguration: (PTTHotkeyConfiguration) -> Void
    let loadOnboardingConfiguration: () -> OnboardingConfiguration
    var availableMicrophones: [MicrophoneDeviceDescriptor] {
        availableMicrophoneDevicesAction()
    }

    var hotkeyConfiguration: PTTHotkeyConfiguration {
        loadHotkeyConfiguration()
    }
    private let saveOnboardingConfiguration: (OnboardingConfiguration) -> Void

    init(
        snapshot: OnboardingStatusSnapshot,
        requestMicrophoneAccessAction: @escaping () -> Void,
        refreshAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void,
        requestAccessibilityAccessAction: @escaping () -> Void = {
            _ = AccessibilityHelper.ensureTrusted(prompt: true)
        },
        openAccessibilitySettingsAction: @escaping () -> Void = {
            SystemSettingsNavigator.open(.accessibility)
        },
        accessibilityTrustCheck: @escaping () -> Bool = {
            AccessibilityHelper.isTrusted
        },
        relaunchAppAction: @escaping () -> Void,
        loadOnboardingConfiguration: @escaping () -> OnboardingConfiguration = {
            OnboardingConfiguration.load()
        },
        saveOnboardingConfiguration: @escaping (OnboardingConfiguration) -> Void = { config in
            config.save()
        },
        selectMicrophoneAction: @escaping (MicrophoneDeviceDescriptor) -> Void = { descriptor in
            UserDefaults.standard.set(descriptor.uid, forKey: GeneralSettingsKeys.selectedInputUID)
            // Steer the RECORDING path, not just the display: the runtime
            // resolves input via MicrophonePriorityConfiguration (the settings UI
            // "Microphone priority" list), so the chosen device must lead it.
            var priority = MicrophonePriorityConfiguration.load()
            priority.priorityUIDs.removeAll { $0 == descriptor.uid }
            priority.priorityUIDs.insert(descriptor.uid, at: 0)
            priority.saveAndNotify()
        },
        clearMicrophoneSelectionAction: @escaping () -> Void = {
            // "Unselect" = follow the Mac's own default input. That requires
            // BOTH dropping the display override AND emptying the priority
            // list — a non-empty list would keep steering recording to its
            // first available entry even when the system default changes.
            // (Empty list = highest-connected-wins; the settings UI pane already
            // presents that semantic.)
            UserDefaults.standard.removeObject(forKey: GeneralSettingsKeys.selectedInputUID)
            var priority = MicrophonePriorityConfiguration.load()
            priority.priorityUIDs = []
            priority.saveAndNotify()
        },
        availableMicrophoneDevicesAction: @escaping () -> [MicrophoneDeviceDescriptor] = {
            MicrophoneDeviceService.availableInputDevices()
        },
        loadHotkeyConfiguration: @escaping () -> PTTHotkeyConfiguration = {
            PTTHotkeyConfiguration.load()
        },
        saveHotkeyConfiguration: @escaping (PTTHotkeyConfiguration) -> Void = { config in
            config.save()
            NotificationCenter.default.post(name: .pttHotkeyConfigurationDidChange, object: nil)
        },
        startDictationAction: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.selectedDownloadVersion = snapshot.selectedModelVersion
        self.requestMicrophoneAccessAction = requestMicrophoneAccessAction
        self.refreshAction = refreshAction
        self.openSettingsAction = openSettingsAction
        self.requestAccessibilityAccessAction = requestAccessibilityAccessAction
        self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.relaunchAppAction = relaunchAppAction
        self.loadOnboardingConfiguration = loadOnboardingConfiguration
        self.saveOnboardingConfiguration = saveOnboardingConfiguration
        self.selectMicrophoneAction = selectMicrophoneAction
        self.clearMicrophoneSelectionAction = clearMicrophoneSelectionAction
        self.availableMicrophoneDevicesAction = availableMicrophoneDevicesAction
        self.loadHotkeyConfiguration = loadHotkeyConfiguration
        self.saveHotkeyConfiguration = saveHotkeyConfiguration
        self.startDictationAction = startDictationAction
    }

    func apply(snapshot: OnboardingStatusSnapshot) {
        self.snapshot = snapshot
        if !snapshot.installedModelVersions.contains(selectedDownloadVersion) && snapshot.modelLibraryURL == nil {
            selectedDownloadVersion = snapshot.selectedModelVersion
        }
        if snapshot.accessibilityStatus.isReady {
            accessibilitySetupState = .idle
        }
    }

    func requestMicrophoneAccess() {
        requestMicrophoneAccessAction()
    }

    func requestAccessibilityAccess() {
        accessibilitySetupState = .needsExternalEnable
        var config = loadOnboardingConfiguration()
        config.hasAttemptedAccessibilitySetup = true
        saveOnboardingConfiguration(config)
        requestAccessibilityAccessAction()
        refreshAction()
    }

    func openMicrophoneSettings() {
        SystemSettingsNavigator.open(.microphone)
    }

    func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }

    func confirmAccessibilityEnabled() {
        if accessibilityTrustCheck() {
            accessibilitySetupState = .idle
            refreshAction()
            return
        }
        accessibilitySetupState = .enabledPendingRelaunch
    }

    /// accessibility relaunch escape hatch: called on every snapshot refresh. Once the user has attempted Accessibility
    /// setup (state == `.needsExternalEnable`), surface the relaunch path whenever the
    /// running process still isn't trusted — previously `.enabledPendingRelaunch` (and the
    /// "Quit & Reopen Kalam" button) was unreachable because nothing called
    /// `confirmAccessibilityEnabled()` from the app.
    func confirmAccessibilityEnabledIfAttempted() {
        guard accessibilitySetupState == .needsExternalEnable else { return }
        confirmAccessibilityEnabled()
    }

    func relaunchApp() {
        relaunchAppAction()
    }

    func chooseModelFolder() {
        let currentURL = ModelsConfiguration.load().modelLibraryURL
        ModelSetupSupport.chooseModelLibraryFolder(currentURL: currentURL) { [weak self] url in
            guard let self, let url else { return }
            self.applyModelLibraryFolder(url)
        }
    }

    func clearModelFolder() {
        applyModelLibraryFolder(nil)
    }

    func useParentFolderForSelectedRepo() {
        guard let currentURL = snapshot.modelLibraryURL?.standardizedFileURL else { return }
        applyModelLibraryFolder(currentURL.deletingLastPathComponent())
    }

    func openModelFolderInFinder() {
        guard let url = snapshot.modelLibraryURL else { return }
        _ = ModelSetupSupport.openModelLibraryFolder(url)
    }

    func recheck() {
        refreshAction()
    }

    func copyInstallCommand() {
        copyToPasteboard(ModelSetupSupport.huggingFaceInstallCommand)
        installCommandCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.installCommandCopied = false
        }
    }

    func copyDownloadCommand() {
        copyToPasteboard(downloadCommand)
        downloadCommandCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.downloadCommandCopied = false
        }
    }

    func openSettings() {
        openSettingsAction()
    }

    func startDictating() {
        startDictationAction()
    }

    func beginHotkeyChange() {
        var config = loadOnboardingConfiguration()
        config.hasPickedHotkey = false
        saveOnboardingConfiguration(config)
        refreshAction()
    }

    func updateHotkeyConfiguration(_ configuration: PTTHotkeyConfiguration, markPicked: Bool = false) {
        saveHotkeyConfiguration(configuration)
        if markPicked {
            var onboardingConfiguration = loadOnboardingConfiguration()
            onboardingConfiguration.hasPickedHotkey = true
            saveOnboardingConfiguration(onboardingConfiguration)
        }
        refreshAction()
    }

    func confirmHotkey() {
        var config = loadOnboardingConfiguration()
        config.hasPickedHotkey = true
        saveOnboardingConfiguration(config)
        refreshAction()
    }

    func confirmHFCLIInstalled() {
        var config = loadOnboardingConfiguration()
        config.hasConfirmedHFCLIInstall = true
        saveOnboardingConfiguration(config)
        refreshAction()
    }

    /// First-run acknowledgment stop (2026-08-22): the model card's Continue
    /// records that the user confirmed the detected library location, so the
    /// router releases its hold and never re-shows a satisfied model step.
    /// The controller's own snapshot is flipped synchronously so the advance
    /// computed right after sees the confirmed state; the app-wide refresh
    /// then lands with the persisted value.
    func confirmModelLocation() {
        var config = loadOnboardingConfiguration()
        config.hasConfirmedModelLocation = true
        saveOnboardingConfiguration(config)
        snapshot.hasConfirmedModelLocation = true
        refreshAction()
        onAdvanceAfterModelConfirmation?()
    }

    /// Injected by the deck view: advances the route after the model-location
    /// confirmation. Optional so tests can construct the controller without it.
    var onAdvanceAfterModelConfirmation: (() -> Void)?

    func selectMicrophone(_ descriptor: MicrophoneDeviceDescriptor) {
        selectMicrophoneAction(descriptor)
        refreshAction()
    }

    /// Drops the microphone override so Kalam follows the Mac's default input.
    /// The selection card's "unselect" destination.
    func clearMicrophoneSelection() {
        clearMicrophoneSelectionAction()
        refreshAction()
    }

    #if DEBUG
    func resetAllOnboardingState() {
        logger.info("Onboarding state reset (DEBUG-only)")
        OnboardingConfiguration.reset()
        OnboardingConfiguration.requestDebugFreshStart()

        // 2026-08-22: a permission-reset rehearsal must also replay the MODEL
        // step. A carried-over bookmark would otherwise satisfy the gate and
        // skip the card (the carried-over-install bug). Clearing drops only
        // the pointer to the library folder — the files stay on disk and
        // re-picking the folder fully restores the setup. The -test flavor's
        // separate defaults domain keeps real installs untouched.
        ModelsConfiguration.clearStoredModelLibraryBookmark()

        // Provide TCC instructions
        let bundleID = Bundle.main.bundleIdentifier ?? "singhkays.Kalam"
        logger.info("To fully reset system permissions, run tccutil reset Microphone \(bundleID, privacy: .public) and tccutil reset Accessibility \(bundleID, privacy: .public)")

        refreshAction()
    }
    #endif

    var downloadCommand: String {
        ModelSetupSupport.downloadCommand(for: selectedDownloadVersion, config: ModelsConfiguration.load())
    }

    var selectedModelRepoFolderVersion: ASRModelVersion? {
        ModelSetupSupport.selectedModelRepoFolderVersion(for: snapshot.modelLibraryURL)
    }

    private func applyModelLibraryFolder(_ folderURL: URL?) {
        do {
            let config = try ModelSetupSupport.applyingModelLibraryFolder(folderURL, to: ModelsConfiguration.load())
            config.save()
            // Single trigger: refreshAction runs refresh → prepare → refresh.
            // Posting modelsConfigurationDidChange here too would double-fire
            // the same path (the observer also calls prepareRuntimeIfPossible).
            refreshAction()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to Use Folder"
            alert.runModal()
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

}

