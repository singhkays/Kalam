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
        config.save(to: defaults)

        let loaded = OnboardingConfiguration.load(from: defaults)
        XCTAssertTrue(loaded.hasCompletedRequiredSetup)
        XCTAssertTrue(loaded.hasAttemptedAccessibilitySetup)
        XCTAssertTrue(loaded.hasConfirmedHFCLIInstall)
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
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
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
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false,
            hasPickedHotkey: true
        )

        XCTAssertEqual(baseSnapshot.completedRequirements, 4)
        XCTAssertFalse(baseSnapshot.canStartDictating)
        XCTAssertEqual(baseSnapshot.runtimePreparationMessage, "Preparing microphone…")

        let readySnapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: true,
            hasPickedHotkey: true
        )

        XCTAssertTrue(readySnapshot.canStartDictating)
        XCTAssertNil(readySnapshot.runtimePreparationMessage)
    }

    func testEvaluateMarksInvalidModelFolderAsBrokenRequirement() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v3,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .invalidModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v3-coreml"),
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
    private func makeController(
        snapshot: OnboardingStatusSnapshot? = nil,
        accessibilityTrustCheck: @escaping () -> Bool = { false },
        loadOnboardingConfiguration: @escaping () -> OnboardingConfiguration = { .defaults },
        saveOnboardingConfiguration: @escaping (OnboardingConfiguration) -> Void = { _ in }
    ) -> OnboardingFlowController {
        OnboardingFlowController(
            snapshot: snapshot ?? baseSnapshot(),
            requestMicrophoneAccessAction: {},
            refreshAction: {},
            openSettingsAction: {},
            requestAccessibilityAccessAction: {},
            openAccessibilitySettingsAction: {},
            accessibilityTrustCheck: accessibilityTrustCheck,
            relaunchAppAction: {},
            loadOnboardingConfiguration: loadOnboardingConfiguration,
            saveOnboardingConfiguration: saveOnboardingConfiguration,
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
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
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
            selectedModelAvailability: .missingModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
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
