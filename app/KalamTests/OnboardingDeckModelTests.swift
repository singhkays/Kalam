import AVFoundation
import XCTest
@testable import Kalam_test

final class OnboardingDeckModelTests: XCTestCase {
    func testInitialRouteShowsWelcomeOnAnEmptyFirstRun() {
        XCTAssertEqual(initialDeckRoute(mode: .firstRun, snapshot: makeSnapshot()), .welcome)
    }

func testFirstRunAlwaysOpensWelcomeEvenWhenConfigSurvives() {
        // firstRun = setup never completed. Welcome ("The promise, before the
        // paperwork") is the deck's FIRST screen per the mockup — it is not
        // skippable because some requirements are already satisfied (e.g. a
        // DEBUG reset preserved hotkey/model config, or tccutil-only reset).
        let snapshot = makeSnapshot(
            microphoneAuthorization: .denied,
            accessibilityTrusted: false,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        XCTAssertEqual(
            initialDeckRoute(mode: .firstRun, snapshot: snapshot, isFreshStart: true),
            .welcome
        )
        // The flag is no longer load-bearing: firstRun lands on welcome regardless.
        XCTAssertEqual(
            initialDeckRoute(mode: .firstRun, snapshot: snapshot),
            .welcome
        )
    }

    func testRepairResumesAtFirstBrokenGate() {
        // repair = setup WAS completed, something broke later. Resume at the
        // broken gate — do not make the user re-read the promise card.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .denied,
            accessibilityTrusted: false,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        XCTAssertEqual(initialDeckRoute(mode: .repair, snapshot: snapshot), .microphone)
    }

    // MARK: - Human-centric step kickers (Task A)

    func testStepKickerUsesHumanCentricLanguage() {
        XCTAssertEqual(stepKicker(for: .welcome), "Welcome")
        XCTAssertEqual(stepKicker(for: .microphone), "Step 1 of 4 · Microphone")
        XCTAssertEqual(stepKicker(for: .microphoneSelection), "Step 1 of 4 · Microphone")
        XCTAssertEqual(stepKicker(for: .accessibility), "Step 2 of 4 · Accessibility")
        XCTAssertEqual(stepKicker(for: .modelFolder), "Step 3 of 4 · The model")
        XCTAssertEqual(stepKicker(for: .modelAcquisition), "Step 3 of 4 · The model")
        XCTAssertEqual(stepKicker(for: .hotkey), "Step 4 of 4 · The key")
        XCTAssertEqual(stepKicker(for: .ready), "Ready")
    }

    func testStepKickerAvoidsGateJargon() {
        for route in [OnboardingDeckRoute.microphone, .accessibility, .modelFolder, .hotkey] {
            let kicker = stepKicker(for: route)
            XCTAssertFalse(kicker.contains("Gate"), "Kicker '\(kicker)' should not contain 'Gate'")
        }
    }

    // MARK: - Canonical welcome copy (Task B)

    func testWelcomeCopyIsPlanCompliant() {
        let copy = kalamOnboardingWelcomeCopy
        // Banned absolutes from the rejected v1.2 wording must not appear.
        XCTAssertFalse(copy.contains("two minutes"), "Welcome copy must not hardcode a duration")
        XCTAssertFalse(copy.contains("no data collection"), "Welcome copy must not claim 'no data collection'")
        XCTAssertFalse(copy.contains("never connects to the internet"), "Welcome copy must not claim offline absolutism")
        // Required honest claims must be present.
        XCTAssertTrue(copy.contains("not saved"), "Welcome copy must state audio/transcripts are not saved")
        XCTAssertTrue(copy.contains("entirely on this Mac"), "Welcome copy must state local processing")
        // 2026-08-22 user decision: welcome carries the CORE PROMISE only.
        // Download/Terminal mechanics live on the model step card, in
        // actionable context — the welcome plate must not preview them.
        XCTAssertFalse(copy.contains("Terminal"), "Welcome copy must not discuss the Terminal download step")
    }

    // MARK: - Rail milestone mapping (Task 2)

    func testRailMilestoneMappingCoversAllRoutes() {
        XCTAssertEqual(railMilestone(for: .welcome).milestone, .microphone)
        XCTAssertEqual(railMilestone(for: .welcome).subtick, 1)
        XCTAssertEqual(railMilestone(for: .microphone).milestone, .microphone)
        XCTAssertEqual(railMilestone(for: .microphone).subtick, 1)
        XCTAssertEqual(railMilestone(for: .microphoneSelection).milestone, .microphone)
        XCTAssertEqual(railMilestone(for: .microphoneSelection).subtick, 2)
        XCTAssertEqual(railMilestone(for: .accessibility).milestone, .accessibility)
        XCTAssertEqual(railMilestone(for: .accessibility).subtick, 1)
        XCTAssertEqual(railMilestone(for: .modelFolder).milestone, .model)
        XCTAssertEqual(railMilestone(for: .modelFolder).subtick, 1)
        XCTAssertEqual(railMilestone(for: .modelAcquisition).milestone, .model)
        XCTAssertEqual(railMilestone(for: .modelAcquisition).subtick, 2)
        XCTAssertEqual(railMilestone(for: .hotkey).milestone, .key)
        XCTAssertEqual(railMilestone(for: .hotkey).subtick, 1)
    }

    func testRailMilestoneTickCountsMatchPlan() {
        // Microphone and the model have two sub-steps; Accessibility and the key have one.
        XCTAssertEqual(OnboardingDeckMilestone.microphone.tickCount, 2)
        XCTAssertEqual(OnboardingDeckMilestone.accessibility.tickCount, 1)
        XCTAssertEqual(OnboardingDeckMilestone.model.tickCount, 2)
        XCTAssertEqual(OnboardingDeckMilestone.key.tickCount, 1)
        // Every mapped subtick must fit inside its milestone's tick count.
        for route in [OnboardingDeckRoute.welcome, .microphone, .microphoneSelection, .accessibility, .modelFolder, .modelAcquisition, .hotkey, .ready] {
            let mapped = railMilestone(for: route)
            XCTAssertTrue((1...mapped.milestone.tickCount).contains(mapped.subtick),
                          "\(route) subtick \(mapped.subtick) out of range for \(mapped.milestone)")
        }
    }

    func testInitialRouteResumesAtFirstIncompleteRequirement() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .missingModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        // New rule: firstRun always opens welcome; gate-resume is repair behavior.
        XCTAssertEqual(initialDeckRoute(mode: .firstRun, snapshot: snapshot), .welcome)
        XCTAssertEqual(initialDeckRoute(mode: .repair, snapshot: snapshot), .modelAcquisition)
    }

    func testInitialRouteStartsRepairAtFirstBrokenRequirement() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: true
        )

        XCTAssertEqual(initialDeckRoute(mode: .repair, snapshot: snapshot), .accessibility)
    }

    func testInitialRouteSkipsModelAcquisitionWhenModelIsInstalled() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        // New rule: firstRun always opens welcome even when a later gate is done.
        XCTAssertEqual(initialDeckRoute(mode: .firstRun, snapshot: snapshot), .welcome)
        XCTAssertEqual(initialDeckRoute(mode: .repair, snapshot: snapshot), .hotkey)
    }

    func testPendingAccessibilityRecoveryKeepsAccessibilityRouteActive() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasAttemptedAccessibilitySetup: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        XCTAssertEqual(nextDeckRoute(after: .accessibility, snapshot: snapshot), .accessibility)
    }

    func testReadyRouteRequiresRuntimePreparation() {
        let preparing = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            isAudioReady: true,
            isASRReady: false
        )
        let ready = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            isAudioReady: true,
            isASRReady: true
        )

        XCTAssertEqual(nextDeckRoute(after: .hotkey, snapshot: preparing), .ready)
        XCTAssertEqual(nextDeckRoute(after: .hotkey, snapshot: ready), .ready)
    }

    func testSelectionCardIsPinnedThroughSnapshotRefreshes() {
        // A multi-choice card must not auto-advance when its rows refresh the
        // snapshot (2026-08-21): picking a microphone updates the highlight;
        // Continue is the contract.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: false,
            hasPickedHotkey: false
        )

        XCTAssertEqual(
            routeAfterSnapshotUpdate(current: .microphoneSelection, snapshot: snapshot),
            .microphoneSelection
        )
    }

    func testPermissionCardsKeepFollowingSnapshots() {
        // Permission cards intentionally keep snapshot-following so "Check
        // again" can advance them once macOS reports the grant.
        let snapshot = makeSnapshot(microphoneAuthorization: .authorized)

        XCTAssertEqual(
            routeAfterSnapshotUpdate(current: .microphone, snapshot: snapshot),
            .microphoneSelection
        )
    }

    func testDebugResetKeepsDeckOnWelcomeThroughSnapshotRefresh() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2"),
            isAudioReady: true,
            isASRReady: true
        )

        XCTAssertEqual(
            routeAfterSnapshotUpdate(current: .ready, snapshot: snapshot, preservingDebugResetWelcome: true),
            .welcome
        )
        // Welcome is pinned IN THE ROUTER since 2026-08-21 (was a View-level
        // guard): Begin setup is the only exit; snapshot refreshes never move
        // the deck off the promise card.
        XCTAssertEqual(
            routeAfterSnapshotUpdate(current: .welcome, snapshot: snapshot),
            .welcome
        )
    }

    func testDeckProgressUsesTheFourLiveRequirements() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
            selectedModelAvailability: .installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        XCTAssertEqual(
            deckProgress(for: snapshot),
            OnboardingDeckProgress(
                completedRequirements: 4,
                totalRequirements: 4,
                activeRequirement: nil
            )
        )
    }

    // MARK: - Carried-over model acknowledgment (2026-08-22)

    private let carriedOverModelFixture = (
        url: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
        availability: ASRModelAvailability.installed(path: "/tmp/models/parakeet-tdt-0.6b-v2")
    )

    func testFirstRunWithCarriedOverModelStopsAtModelFolderFromWelcome() {
        // The carried-over-install bug: model satisfied → deck skipped the
        // model step entirely. First run must stop there ONCE for
        // acknowledgment, even though the gate is already green.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(nextDeckRoute(after: .welcome, snapshot: snapshot), .modelFolder)
        // Sitting on the card, a snapshot refresh (its rows refresh the
        // snapshot on every tap) must not bounce the user past the
        // confirmation — Continue is the contract, same as the selection card.
        XCTAssertEqual(routeAfterSnapshotUpdate(current: .modelFolder, snapshot: snapshot), .modelFolder)
    }

    func testConfirmingModelLocationReleasesTheAckHold() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability,
            hasConfirmedModelLocation: true
        )

        XCTAssertEqual(nextDeckRoute(after: .modelFolder, snapshot: snapshot), .hotkey)
        XCTAssertEqual(routeAfterSnapshotUpdate(current: .modelFolder, snapshot: snapshot), .hotkey)
    }

    func testAckOccupiesTheModelSlotInTheWalk() {
        // Sequence, not tail: with the key ALSO unpicked, the acknowledgment
        // still comes before the key card (it owns the model step's slot).
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(nextDeckRoute(after: .accessibility, snapshot: snapshot), .modelFolder)
    }

    func testAckDoesNotDragBackFromLaterCards() {
        // Once the walk has passed the model step, snapshot refreshes on the
        // hotkey card must not pull the user backwards to re-confirm.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(nextDeckRoute(after: .hotkey, snapshot: snapshot), .hotkey)
    }

    func testAckDoesNotFireInRepairMode() {
        // Repair resumes at broken gates only; a satisfied model is never
        // re-shown, so a fully-satisfied repair snapshot is simply done.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability,
            hasCompletedRequiredSetup: true,
            isAudioReady: true,
            isASRReady: true
        )
        XCTAssertEqual(snapshot.mode, .repair)

        XCTAssertEqual(initialDeckRoute(mode: .repair, snapshot: snapshot), .ready)
        XCTAssertEqual(nextDeckRoute(after: .modelFolder, snapshot: snapshot), .ready)
    }

    func testRailStaysTruthfulDuringModelAck() {
        // The acknowledgment stop is routing metadata, not an unmet
        // requirement: all four requirements ARE satisfied, so the rail
        // reports 4/4 with no active column even while the model card holds.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: true,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(
            deckProgress(for: snapshot),
            OnboardingDeckProgress(completedRequirements: 4, totalRequirements: 4, activeRequirement: nil)
        )
    }

    func testBackFromHotkeySkipsSatisfiedModelStep() {
        // A satisfied model card cannot hold Back's destination (the forward
        // router would bounce straight back to hotkey), so skip past it.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(previousDeckRoute(before: .hotkey, snapshot: snapshot), .accessibility)
    }

    func testBackFromHotkeyLandsOnBrokenModelStep() {
        // A BROKEN model card is a valid Back destination — its card holds.
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: .missingModelFolder(expectedPath: "/tmp/models/parakeet-tdt-0.6b-v2")
        )

        XCTAssertEqual(previousDeckRoute(before: .hotkey, snapshot: snapshot), .modelAcquisition)
    }

    func testBackFromModelAckLandsOnMicrophoneSelection() {
        let snapshot = makeSnapshot(
            microphoneAuthorization: .authorized,
            accessibilityTrusted: true,
            hasPickedHotkey: false,
            modelLibraryURL: carriedOverModelFixture.url,
            selectedModelAvailability: carriedOverModelFixture.availability
        )

        XCTAssertEqual(previousDeckRoute(before: .modelFolder, snapshot: snapshot), .microphoneSelection)
    }

    private func makeSnapshot(
        microphoneAuthorization: AVAuthorizationStatus = .notDetermined,
        accessibilityTrusted: Bool = false,
        hasAttemptedAccessibilitySetup: Bool = false,
        hasPickedHotkey: Bool = false,
        selectedModelVersion: ASRModelVersion = .v2,
        modelLibraryURL: URL? = nil,
        selectedModelAvailability: ASRModelAvailability = .modelLibraryNotConfigured,
        hasCompletedRequiredSetup: Bool = false,
        hasConfirmedModelLocation: Bool = false,
        isAudioReady: Bool = false,
        isASRReady: Bool = false
    ) -> OnboardingStatusSnapshot {
        OnboardingStatusSnapshot.evaluate(
            microphoneAuthorization: microphoneAuthorization,
            selectedMicrophoneName: nil,
            accessibilityTrusted: accessibilityTrusted,
            hasAttemptedAccessibilitySetup: hasAttemptedAccessibilitySetup,
            hotkeyConfig: .defaults,
            hasPickedHotkey: hasPickedHotkey,
            selectedModelVersion: selectedModelVersion,
            modelLibraryURL: modelLibraryURL,
            selectedModelAvailability: selectedModelAvailability,
            installedModelVersions: selectedModelAvailability.isInstalled ? [selectedModelVersion] : [],
            hasCompletedRequiredSetup: hasCompletedRequiredSetup,
            hasConfirmedModelLocation: hasConfirmedModelLocation,
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }
}
