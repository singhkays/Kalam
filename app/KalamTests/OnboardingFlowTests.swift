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
        config.save(to: defaults)

        let loaded = OnboardingConfiguration.load(from: defaults)
        XCTAssertTrue(loaded.hasCompletedRequiredSetup)
        XCTAssertTrue(loaded.hasAttemptedAccessibilitySetup)
    }

    func testEvaluateReturnsFirstRunWhenNeverCompleted() {
        let snapshot = OnboardingStatusSnapshot.evaluate(
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
        let snapshot = OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: true
        )

        XCTAssertEqual(snapshot.mode, .repair)
        XCTAssertTrue(snapshot.hasIncompleteRequirements)
        XCTAssertEqual(snapshot.brokenRequirements, [.accessibility])
        XCTAssertFalse(snapshot.canStartDictating)
    }

    func testEvaluateAllowsStartOnlyAfterRuntimePrep() {
        let baseSnapshot = OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: false,
            isASRReady: false
        )

        XCTAssertEqual(baseSnapshot.completedRequirements, 3)
        XCTAssertFalse(baseSnapshot.canStartDictating)
        XCTAssertEqual(baseSnapshot.runtimePreparationMessage, "Preparing microphone…")

        let readySnapshot = OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: true
        )

        XCTAssertTrue(readySnapshot.canStartDictating)
        XCTAssertNil(readySnapshot.runtimePreparationMessage)
    }

    func testEvaluateMarksInvalidModelFolderAsBrokenRequirement() {
        let snapshot = OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v3,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .invalidModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v3-coreml"),
            installedModelVersions: [],
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: false
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
    private func makeController(accessibilityTrustCheck: @escaping () -> Bool) -> OnboardingFlowController {
        OnboardingFlowController(
            snapshot: baseSnapshot(),
            requestMicrophoneAccessAction: {},
            refreshAction: {},
            openSettingsAction: {},
            requestAccessibilityAccessAction: {},
            openAccessibilitySettingsAction: {},
            accessibilityTrustCheck: accessibilityTrustCheck,
            relaunchAppAction: {},
            saveOnboardingConfiguration: { _ in },
            startDictationAction: {}
        )
    }

    private func baseSnapshot() -> OnboardingStatusSnapshot {
        OnboardingStatusSnapshot.evaluate(
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
        OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasAttemptedAccessibilitySetup: false,
            selectedModelVersion: .v2,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2-coreml"),
            installedModelVersions: [.v2],
            hasCompletedRequiredSetup: false,
            isAudioReady: true,
            isASRReady: true
        )
    }

    func testEvaluatePreservesAccessibilityRecoveryStateAfterAttempt() {
        let snapshot = OnboardingStatusSnapshot.evaluate(
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
