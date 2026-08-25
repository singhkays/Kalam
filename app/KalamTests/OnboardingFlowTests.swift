import AVFoundation
import XCTest
@testable import Kalam_test

final class OnboardingFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testOnboardingConfigurationRoundTrip() {
        var config = OnboardingConfiguration.defaults
        config.hasCompletedRequiredSetup = true
        config.hasAttemptedAccessibilitySetup = true
        config.hasConfirmedHFCLIInstall = true
        config.hasConfirmedModelLocation = true
        config.save(to: defaults)

        let loaded = OnboardingConfiguration.load(from: defaults)
        XCTAssertTrue(loaded.hasCompletedRequiredSetup)
        XCTAssertTrue(loaded.hasAttemptedAccessibilitySetup)
        XCTAssertTrue(loaded.hasConfirmedHFCLIInstall)
        XCTAssertTrue(loaded.hasConfirmedModelLocation)
    }

    func testEvaluateReturnsFirstRunWhenNeverCompleted() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .notDetermined,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: nil,
            selectedModelAvailability: .modelLibraryNotConfigured,
            installedModelVersions: [],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false
        )

        XCTAssertEqual(snapshot.mode, .firstRun)
        XCTAssertTrue(snapshot.hasIncompleteRequirements)
        XCTAssertEqual(snapshot.completedRequirements, 0)
        XCTAssertFalse(snapshot.canStartDictating)
    }

    func testEvaluateReturnsRepairWhenCompletedUserRegresses() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: true,
            hasPickedHotkey: true
        )

        XCTAssertEqual(snapshot.mode, .repair)
        XCTAssertTrue(snapshot.hasIncompleteRequirements)
        XCTAssertEqual(snapshot.brokenRequirements, [.accessibility])
        XCTAssertFalse(snapshot.canStartDictating)
    }

    func testEvaluateAllowsStartOnlyAfterRuntimePrep() {
        let baseSnapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false,
            hasPickedHotkey: true
        )

        XCTAssertEqual(baseSnapshot.completedRequirements, 4)
        XCTAssertFalse(baseSnapshot.canStartDictating)
        XCTAssertTrue(baseSnapshot.isStartDictatingDisabled)
        XCTAssertEqual(baseSnapshot.runtimePreparationMessage, "Preparing microphone…")

        let readySnapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: true,
            hasPickedHotkey: true
        )

        XCTAssertTrue(readySnapshot.canStartDictating)
        XCTAssertFalse(readySnapshot.isStartDictatingDisabled)
        XCTAssertNil(readySnapshot.runtimePreparationMessage)
    }

    func testRuntimePreparationMessageShowsEnginePreparingWhileModelReadyButASRLoading() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: false,
            hasPickedHotkey: false
        )

        // Model files are present but the engine is still loading in the
        // background — the user should see progress even before all four
        // requirements are complete (first-run folder pick scenario).
        XCTAssertEqual(snapshot.completedRequirements, 3)
        XCTAssertEqual(snapshot.runtimePreparationMessage, "Preparing dictation engine…")
    }

    func testEvaluateMarksInvalidModelFolderAsBrokenRequirement() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v3,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .invalidModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v3"),
            installedModelVersions: [],
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: false,
            hasPickedHotkey: true
        )

        XCTAssertEqual(snapshot.mode, .repair)
        XCTAssertEqual(snapshot.brokenRequirements, [.model])
        XCTAssertFalse(snapshot.modelStatus.isReady)
    }

    @MainActor
    func testAccessibilityFlowTransitionsToPendingExternalAfterRequest() {
        let controller = makeController(accessibilityTrustCheck: { false })

        controller.requestAccessibilityAccess()

        XCTAssertEqual(controller.accessibilitySetupState, .needsExternalEnable)
    }

    @MainActor
    func testAccessibilityFlowTransitionsToPendingRelaunchAfterConfirmationIfStillUntrusted() {
        let controller = makeController(accessibilityTrustCheck: { false })

        controller.requestAccessibilityAccess()
        controller.confirmAccessibilityEnabled()

        XCTAssertEqual(controller.accessibilitySetupState, .enabledPendingRelaunch)
    }

    @MainActor
    func testAccessibilityFlowResetsWhenTrustBecomesAvailable() {
        var isTrusted = false
        let controller = makeController(accessibilityTrustCheck: { isTrusted })

        controller.requestAccessibilityAccess()
        isTrusted = true
        controller.confirmAccessibilityEnabled()
        controller.apply(snapshot: readySnapshot())

        XCTAssertEqual(controller.accessibilitySetupState, .idle)
    }

    // MARK: - accessibility relaunch escape hatch (relaunch path reachability)

    @MainActor
    func testConfirmAccessibilityEnabledIfAttemptedTransitionsToPendingRelaunchWhenUntrusted() {
        let controller = makeController(accessibilityTrustCheck: { false })

        controller.requestAccessibilityAccess()   // → .needsExternalEnable
        controller.confirmAccessibilityEnabledIfAttempted()

        XCTAssertEqual(controller.accessibilitySetupState, .enabledPendingRelaunch)
    }

    @MainActor
    func testConfirmAccessibilityEnabledIfAttemptedGoesIdleWhenTrusted() {
        var isTrusted = false
        let controller = makeController(accessibilityTrustCheck: { isTrusted })

        controller.requestAccessibilityAccess()
        isTrusted = true
        controller.confirmAccessibilityEnabledIfAttempted()

        XCTAssertEqual(controller.accessibilitySetupState, .idle)
    }

    @MainActor
    func testConfirmAccessibilityEnabledIfAttemptedIsNoopWhenIdle() {
        let controller = makeController(accessibilityTrustCheck: { false })

        // Setup never attempted — the refresh hook must not force a relaunch state.
        controller.confirmAccessibilityEnabledIfAttempted()

        XCTAssertEqual(controller.accessibilitySetupState, .idle)
    }

    @MainActor
    func testConfirmHFCLIInstalledPersistsFlag() {
        var savedConfiguration = OnboardingConfiguration.defaults
        let controller = makeController(
            loadOnboardingConfiguration: { savedConfiguration },
            saveOnboardingConfiguration: { savedConfiguration = $0 }
        )

        controller.confirmHFCLIInstalled()

        XCTAssertTrue(savedConfiguration.hasConfirmedHFCLIInstall)
    }

    @MainActor
    func testModelSetupWizardStateUnlocksWithManualCLIConfirmation() {
        var onboardingConfiguration = OnboardingConfiguration.defaults
        onboardingConfiguration.hasConfirmedHFCLIInstall = true

        let controller = makeController(
            snapshot: folderReadySnapshot(),
            loadOnboardingConfiguration: { onboardingConfiguration }
        )

        XCTAssertTrue(controller.modelSetupWizardState.isCLIComplete)
        XCTAssertTrue(controller.modelSetupWizardState.isCLIManuallyConfirmed)
        XCTAssertEqual(controller.modelSetupWizardState.currentStep, .download)
    }

    @MainActor
    func testModelSetupWizardStateRequiresManualConfirmationWhenModelMissing() {
        let controller = makeController(snapshot: folderReadySnapshot())

        XCTAssertFalse(controller.modelSetupWizardState.isCLIComplete)
        XCTAssertFalse(controller.modelSetupWizardState.isCLIManuallyConfirmed)
        XCTAssertEqual(controller.modelSetupWizardState.currentStep, .cli)
    }

    @MainActor
    func testChangingSelectedDownloadVersionClearsCopiedDownloadState() {
        let controller = makeController(snapshot: folderReadySnapshot())

        controller.copyDownloadCommand()
        XCTAssertTrue(controller.downloadCommandCopied)

        controller.selectedDownloadVersion = .v3

        XCTAssertFalse(controller.downloadCommandCopied)
    }

    @MainActor
    func testBeginHotkeyChangeClearsOnlyOnboardingProgress() {
        var savedConfiguration = OnboardingConfiguration.defaults
        savedConfiguration.hasPickedHotkey = true
        var refreshCount = 0
        let controller = makeController(
            loadOnboardingConfiguration: { savedConfiguration },
            saveOnboardingConfiguration: { savedConfiguration = $0 },
            refreshAction: { refreshCount += 1 }
        )

        controller.beginHotkeyChange()

        XCTAssertFalse(savedConfiguration.hasPickedHotkey)
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testConfirmHotkeyPersistsProgressAndRefreshes() {
        var savedConfiguration = OnboardingConfiguration.defaults
        var refreshCount = 0
        let controller = makeController(
            loadOnboardingConfiguration: { savedConfiguration },
            saveOnboardingConfiguration: { savedConfiguration = $0 },
            refreshAction: { refreshCount += 1 }
        )

        controller.confirmHotkey()

        XCTAssertTrue(savedConfiguration.hasPickedHotkey)
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testUpdateHotkeyConfigurationPersistsConfigurationAndProgressThroughInjectedActions() {
        var savedOnboardingConfiguration = OnboardingConfiguration.defaults
        var savedHotkeyConfiguration = PTTHotkeyConfiguration.defaults
        var refreshCount = 0
        var updatedHotkeyConfiguration = PTTHotkeyConfiguration.defaults
        updatedHotkeyConfiguration.activationMode = .toggle
        let controller = makeController(
            loadOnboardingConfiguration: { savedOnboardingConfiguration },
            saveOnboardingConfiguration: { savedOnboardingConfiguration = $0 },
            refreshAction: { refreshCount += 1 },
            loadHotkeyConfiguration: { savedHotkeyConfiguration },
            saveHotkeyConfiguration: { savedHotkeyConfiguration = $0 }
        )

        controller.updateHotkeyConfiguration(updatedHotkeyConfiguration, markPicked: true)

        XCTAssertEqual(savedHotkeyConfiguration, updatedHotkeyConfiguration)
        XCTAssertTrue(savedOnboardingConfiguration.hasPickedHotkey)
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testSelectMicrophoneUsesInjectedActionAndRefreshes() {
        let descriptor = MicrophoneDeviceDescriptor(
            id: "mic-1",
            uid: "mic-1",
            name: "Test Microphone",
            deviceID: 1,
            isAvailable: true,
            channelCount: 2
        )
        var selectedDescriptor: MicrophoneDeviceDescriptor?
        var refreshCount = 0
        let controller = makeController(
            refreshAction: { refreshCount += 1 },
            selectMicrophoneAction: { selectedDescriptor = $0 }
        )

        controller.selectMicrophone(descriptor)

        XCTAssertEqual(selectedDescriptor, descriptor)
        XCTAssertEqual(refreshCount, 1)
    }

    func testOnboardingResetPreservesRealUserConfiguration() {
        defaults.set(true, forKey: "internal.hasCompletedRequiredSetup")
        defaults.set(true, forKey: "internal.hasAttemptedAccessibilitySetup")
        defaults.set(true, forKey: "internal.hasPickedHotkey")
        defaults.set(true, forKey: "internal.hasConfirmedHFCLIInstall")
        defaults.set("v3", forKey: "models.asrVersion")
        let bookmark = Data([1, 2, 3])
        defaults.set(bookmark, forKey: "models.modelLibraryBookmark")
        defaults.set("mic-1", forKey: GeneralSettingsKeys.selectedInputUID)
        defaults.set("shiftCommand", forKey: "pttHotkey.keyCombination")

        OnboardingConfiguration.reset(from: defaults)

        XCTAssertFalse(defaults.bool(forKey: "internal.hasCompletedRequiredSetup"))
        XCTAssertFalse(defaults.bool(forKey: "internal.hasAttemptedAccessibilitySetup"))
        XCTAssertFalse(defaults.bool(forKey: "internal.hasPickedHotkey"))
        XCTAssertFalse(defaults.bool(forKey: "internal.hasConfirmedHFCLIInstall"))
        // Progress flags include the model-location acknowledgment.
        XCTAssertFalse(defaults.bool(forKey: "internal.hasConfirmedModelLocation"))
        XCTAssertEqual(defaults.string(forKey: "models.asrVersion"), "v3")
        // OnboardingConfiguration.reset itself preserves the model library
        // POINTER — clearing it is the DEBUG reset ceremony's explicit job
        // (testModelLocationClearDropsOnlyThePointer below).
        XCTAssertEqual(defaults.data(forKey: "models.modelLibraryBookmark"), bookmark)
        XCTAssertEqual(defaults.string(forKey: GeneralSettingsKeys.selectedInputUID), "mic-1")
        XCTAssertEqual(defaults.string(forKey: "pttHotkey.keyCombination"), "shiftCommand")
    }

    func testModelLocationClearDropsOnlyThePointer() {
        // 2026-08-22: the DEBUG reset clears the stored security-scoped
        // bookmark so a rehearsal replays the model step instead of silently
        // skipping it (the carried-over-install bug). Only the pointer to
        // the library drops — version choice and files on disk are untouched,
        // and re-picking the folder restores everything.
        defaults.set(Data([9, 9]), forKey: "models.modelLibraryBookmark")
        defaults.set("v3", forKey: "models.asrVersion")

        ModelsConfiguration.clearStoredModelLibraryBookmark(defaults)

        XCTAssertNil(defaults.data(forKey: "models.modelLibraryBookmark"))
        XCTAssertEqual(defaults.string(forKey: "models.asrVersion"), "v3")
    }

    @MainActor
    private func makeController(
        snapshot: OnboardingStatusSnapshot? = nil,
        accessibilityTrustCheck: @escaping () -> Bool = { false },
        loadOnboardingConfiguration: @escaping () -> OnboardingConfiguration = { .defaults },
        saveOnboardingConfiguration: @escaping (OnboardingConfiguration) -> Void = { _ in },
        refreshAction: @escaping () -> Void = {},
        selectMicrophoneAction: @escaping (MicrophoneDeviceDescriptor) -> Void = { _ in },
        availableMicrophoneDevicesAction: @escaping () -> [MicrophoneDeviceDescriptor] = { [] },
        loadHotkeyConfiguration: @escaping () -> PTTHotkeyConfiguration = { .defaults },
        saveHotkeyConfiguration: @escaping (PTTHotkeyConfiguration) -> Void = { _ in }
    ) -> OnboardingFlowController {
        OnboardingFlowController(
            snapshot: snapshot ?? baseSnapshot(),
            requestMicrophoneAccessAction: {},
            refreshAction: refreshAction,
            openSettingsAction: {},
            requestAccessibilityAccessAction: {},
            openAccessibilitySettingsAction: {},
            accessibilityTrustCheck: accessibilityTrustCheck,
            relaunchAppAction: {},
            loadOnboardingConfiguration: loadOnboardingConfiguration,
            saveOnboardingConfiguration: saveOnboardingConfiguration,
            selectMicrophoneAction: selectMicrophoneAction,
            availableMicrophoneDevicesAction: availableMicrophoneDevicesAction,
            loadHotkeyConfiguration: loadHotkeyConfiguration,
            saveHotkeyConfiguration: saveHotkeyConfiguration,
            startDictationAction: {}
        )
    }

    private func baseSnapshot() -> OnboardingStatusSnapshot {
        makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: nil,
            selectedModelAvailability: .modelLibraryNotConfigured,
            installedModelVersions: [],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false
        )
    }

    private func readySnapshot() -> OnboardingStatusSnapshot {
        makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: true,
            hasPickedHotkey: true
        )
    }

    private func folderReadySnapshot() -> OnboardingStatusSnapshot {
        makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .missingModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v2"),
            installedModelVersions: [],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: false
        )
    }

    private func makeSnapshot(
        microphoneAuthorization: AVAuthorizationStatus,
        accessibilityTrusted: Bool,
        hasAttemptedAccessibilitySetup: Bool,
        selectedModelVersion: ASRModelVersion,
        modelLibraryURL: URL?,
        selectedModelAvailability: ASRModelAvailability,
        installedModelVersions: [ASRModelVersion],
        hasCompletedRequiredSetup: Bool,
        hasConfirmedModelLocation: Bool = false,
        isAudioReady: Bool,
        isASRReady: Bool,
        selectedMicrophoneName: String? = nil,
        hotkeyConfig: PTTHotkeyConfiguration = .defaults,
        hasPickedHotkey: Bool = false
    ) -> OnboardingStatusSnapshot {
        OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: microphoneAuthorization,
            selectedMicrophoneName: selectedMicrophoneName,
            accessibilityTrusted: accessibilityTrusted,
            hasAttemptedAccessibilitySetup: hasAttemptedAccessibilitySetup,
            hotkeyConfig: hotkeyConfig,
            hasPickedHotkey: hasPickedHotkey,
            selectedModelVersion: selectedModelVersion,
            modelLibraryURL: modelLibraryURL,
            selectedModelAvailability: selectedModelAvailability,
            installedModelVersions: installedModelVersions,
            hasCompletedRequiredSetup: hasCompletedRequiredSetup,
            hasConfirmedModelLocation: hasConfirmedModelLocation,
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }

    func testEvaluatePreservesAccessibilityRecoveryStateAfterAttempt() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: true,
            selectedModelVersion: .v2,
            modelLibraryURL: nil,
            selectedModelAvailability: .modelLibraryNotConfigured,
            installedModelVersions: [],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false
        )

        guard case .pendingExternal(let message) = snapshot.accessibilityStatus else {
            return XCTFail("Expected pending accessibility recovery state")
        }

        XCTAssertTrue(message.contains("still can't verify Accessibility access"))
    }
}
