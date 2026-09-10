import XCTest
import Observation
@testable import Kalam_test

/// settings redesign (settings UI): derived map/dive state lives in SettingsModel — pins attention priority,
/// spanning, hero copy, map card strings, contents states, and the revision mechanism that
/// makes the @Observable façade react to external store changes (plan §4.1).
@MainActor
final class SettingsModelTests: XCTestCase {

    private func makeModel(_ store: InMemorySettingsStore = InMemorySettingsStore()) -> SettingsModel {
        SettingsModel(store: store)
    }

    /// Pump the main runloop so the store's onChange stream reaches the model's revision task.
    private func spinMainRunLoop(until condition: () -> Bool, timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Attention priority (single winner)

    func testAttentionNilWhenSettled() {
        XCTAssertNil(makeModel(InMemorySettingsStore.fixtureSettled()).attention)
    }

    func testAttentionEmptyDictionaryIsLowestPriority() {
        XCTAssertEqual(
            makeModel(InMemorySettingsStore.fixtureDefaultEmptyDictionary()).attention,
            .dictionary
        )
    }

    func testAttentionEngineMissingBeatsEmptyDictionary() {
        let store = InMemorySettingsStore.fixtureEngineMissing()
        store.rules = [] // two problems — engine must win
        XCTAssertEqual(makeModel(store).attention, .engine)
    }

    func testAttentionEngineIncompleteBeatsEverything() {
        let store = InMemorySettingsStore.fixtureEngineIncomplete()
        store.rules = []
        store.hotkey = nil
        store.microphones = []
        XCTAssertEqual(makeModel(store).attention, .engine)
    }

    func testAttentionNoMicrophone() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).attention, .beingHeard)
    }

    func testAttentionPermissionDeniedIsNoMicrophone() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixturePermissionDenied()).attention, .beingHeard)
    }

    func testAttentionKeyUnset() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).attention, .trigger)
    }

    // MARK: - Spanning (always exactly one span-2 card)

    func testSpanningIsAttentionWhenAttentionExists() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).spanning, .beingHeard)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).spanning, .engine)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).spanning, .trigger)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureDefaultEmptyDictionary()).spanning, .dictionary)
    }

    func testSpanningIsEngineFillWhenSettled() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureSettled()).spanning, .engine)
    }

    // MARK: - Hero

    func testHeroReadyWhenSettled() {
        let model = makeModel(InMemorySettingsStore.fixtureSettled())
        XCTAssertEqual(model.hero, .ready)
        XCTAssertEqual(model.hero.text, "Everything is ready.")
        XCTAssertEqual(model.hero.italicSuffix, "ready.")
    }

    func testHeroEngineMissingForBothMissingAndIncomplete() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).hero, .engineMissing)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineIncomplete()).hero, .engineMissing)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).hero.text, "The engine needs a model.")
    }

    func testHeroNoMicrophoneAndKeyUnset() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).hero, .noMicrophone)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).hero, .keyUnset)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).hero.italicSuffix, "set.")
    }

    func testMapNeedCTAOnlyForActionableAttention() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).mapNeedCTA, "Open the engine →")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).mapNeedCTA, "Open being heard →")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).mapNeedCTA, "Open the trigger →")
        // Empty dictionary is span-attention only — no CTA.
        XCTAssertNil(makeModel(InMemorySettingsStore.fixtureDefaultEmptyDictionary()).mapNeedCTA)
        XCTAssertNil(makeModel(InMemorySettingsStore.fixtureSettled()).mapNeedCTA)
    }

    // MARK: - Map card strings

    func testMapCardTitle() {
        let model = makeModel(InMemorySettingsStore.fixtureSettled())
        XCTAssertEqual(model.mapCardTitle(for: .beingHeard), "HD Pro Webcam C920")
        XCTAssertEqual(model.mapCardTitle(for: .trigger), "Right Command")
        XCTAssertEqual(model.mapCardTitle(for: .cleanup), "3 rules, light")
        XCTAssertEqual(model.mapCardTitle(for: .dictionary), "3 rules")
        XCTAssertEqual(model.mapCardTitle(for: .engine), "Parakeet v3")
        XCTAssertEqual(model.mapCardTitle(for: .updates), "Updates")
    }

    func testMapCardTitleEdgeStates() {
        let empty = makeModel(InMemorySettingsStore.fixtureDefaultEmptyDictionary())
        XCTAssertEqual(empty.mapCardTitle(for: .dictionary), "No rules yet")
        XCTAssertEqual(empty.mapCardTitle(for: .beingHeard), "HD Pro Webcam C920")

        let keyUnset = makeModel(InMemorySettingsStore.fixtureKeyUnset())
        XCTAssertEqual(keyUnset.mapCardTitle(for: .trigger), "No key")

        let missing = makeModel(InMemorySettingsStore.fixtureEngineMissing())
        XCTAssertEqual(missing.mapCardTitle(for: .engine), "No model found")

        let incomplete = makeModel(InMemorySettingsStore.fixtureEngineIncomplete())
        XCTAssertEqual(incomplete.mapCardTitle(for: .engine), "Incomplete")
    }

    func testMapCardState() {
        let model = makeModel(InMemorySettingsStore.fixtureSettled())
        XCTAssertEqual(model.mapCardState(for: .beingHeard).text, "Ready")
        XCTAssertEqual(model.mapCardState(for: .beingHeard).tone, .ok)
        XCTAssertEqual(model.mapCardState(for: .trigger).text, "Set")
        XCTAssertEqual(model.mapCardState(for: .cleanup).text, "On")
        XCTAssertEqual(model.mapCardState(for: .dictionary).text, "Ready")
        XCTAssertEqual(model.mapCardState(for: .engine).text, "Verified")

        // F-07 tones: warn = needs attention, bad = blocked, neutral = off-but-fine.
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureCleanupOff()).mapCardState(for: .cleanup).tone, .neutral)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineIncomplete()).mapCardState(for: .engine).text, "Incomplete")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineIncomplete()).mapCardState(for: .engine).tone, .warn)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).mapCardState(for: .engine).tone, .bad)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).mapCardState(for: .beingHeard).text, "Offline")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureNoDevices()).mapCardState(for: .beingHeard).tone, .warn)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).mapCardState(for: .trigger).tone, .warn)
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixturePermissionDenied()).mapCardState(for: .beingHeard).text, "Blocked")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixturePermissionDenied()).mapCardState(for: .beingHeard).tone, .bad)
    }

    func testMapCardDescriptionAttentionLongForm() {
        let missing = makeModel(InMemorySettingsStore.fixtureEngineMissing())
        XCTAssertEqual(
            missing.mapCardDescription(for: .engine),
            "Put the five Parakeet files in ~/Kalam/models/ and Kalam will load them from disk."
        )
        let incomplete = makeModel(InMemorySettingsStore.fixtureEngineIncomplete())
        XCTAssertEqual(
            incomplete.mapCardDescription(for: .engine),
            "This folder has part of a model; add the rest of the Parakeet files so Kalam can load it from disk."
        )
        let settled = makeModel(InMemorySettingsStore.fixtureSettled())
        XCTAssertEqual(settled.mapCardDescription(for: .engine), "Recognition runs on this Mac.") // wide fill
    }

    func testCleanupMapTitle() {
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureSettled()).cleanupMapTitle, "3 rules, light")

        let off = InMemorySettingsStore.fixtureCleanupOff()
        off.removeFillers = true
        XCTAssertEqual(makeModel(off).cleanupMapTitle, "Off")

        let full = InMemorySettingsStore.fixtureSettled()
        full.removeFillers = false
        full.handleBacktracks = false
        full.formatLists = false
        full.normalizePunctuation = false
        full.grammarPass = .full
        XCTAssertEqual(makeModel(full).cleanupMapTitle, "0 rules, full") // grammar-only config
    }

    // MARK: - Contents nav states

    func testContentsState() {
        let model = makeModel(InMemorySettingsStore.fixtureSettled())
        XCTAssertEqual(model.contentsState(for: .beingHeard), "Ready")
        XCTAssertEqual(model.contentsState(for: .trigger), "Right Cmd")
        XCTAssertEqual(model.contentsState(for: .cleanup), "3/4")
        XCTAssertEqual(model.contentsState(for: .dictionary), "3 rules")
        XCTAssertEqual(model.contentsState(for: .engine), "v3")

        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureKeyUnset()).contentsState(for: .trigger), "Unset")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureDefaultEmptyDictionary()).contentsState(for: .dictionary), "Empty")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureCleanupOff()).contentsState(for: .cleanup), "Off")
        XCTAssertEqual(makeModel(InMemorySettingsStore.fixtureEngineMissing()).contentsState(for: .engine), "Missing")
    }

    // MARK: - Microphone status (IN USE = first connected, NOT row zero)

    func testMicrophoneStatusInUseIsFirstConnectedNotRowZero() {
        let store = InMemorySettingsStore()
        store.microphones = [
            .init(id: "usb", name: "USB audio CODEC", isConnected: false),
            .init(id: "cam", name: "HD Pro Webcam C920", isConnected: true),
            .init(id: "mbp", name: "MacBook Pro Microphone", isConnected: true),
        ]
        store.lastUsedID = "mbp"
        let model = makeModel(store)
        XCTAssertEqual(model.microphoneStatus(for: store.microphones[0]), "OFFLINE")
        XCTAssertEqual(model.microphoneStatus(for: store.microphones[1]), "IN USE") // not row zero!
        XCTAssertEqual(model.microphoneStatus(for: store.microphones[2]), "LAST USED")
    }

    func testMicrophoneStatusPermissionDeniedIsOfflineForAll() {
        let store = InMemorySettingsStore.fixturePermissionDenied()
        store.microphones = [.init(id: "cam", name: "Cam", isConnected: true)]
        let model = makeModel(store)
        XCTAssertEqual(model.microphoneStatus(for: store.microphones[0]), "OFFLINE")
        XCTAssertNil(model.connectedMicrophone)
    }

    func testMoveMicrophoneReordersThroughStore() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
        model.moveMicrophone(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.microphones.map(\.id), ["mbp", "usb", "cam"])
    }

    // MARK: - Mic priority steps (D.1 rank + up/down, no drag handles)

    func testMoveMicrophoneUpSwapsWithPreviousRow() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
        model.moveMicrophoneUp(id: "mbp")
        XCTAssertEqual(model.microphones.map(\.id), ["mbp", "cam", "usb"])
    }

    func testMoveMicrophoneUpOnFirstRowIsNoOp() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        model.moveMicrophoneUp(id: "cam")
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
    }

    func testMoveMicrophoneDownSwapsWithNextRow() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        model.moveMicrophoneDown(id: "cam")
        XCTAssertEqual(model.microphones.map(\.id), ["mbp", "cam", "usb"])
    }

    func testMoveMicrophoneDownOnLastRowIsNoOp() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        model.moveMicrophoneDown(id: "usb")
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
    }

    func testMoveMicrophoneStepWithUnknownIDIsNoOp() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        model.moveMicrophoneUp(id: "nope")
        model.moveMicrophoneDown(id: "nope")
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
    }

    // MARK: - Forwarded settings (store path)

    func testIndicatorStyleReadsAndWritesThroughStore() {
        let store = InMemorySettingsStore()
        let model = makeModel(store)
        XCTAssertEqual(model.indicatorStyle, .machined)
        model.indicatorStyle = .caret
        XCTAssertEqual(store.indicatorStyle, .caret)
        XCTAssertEqual(model.indicatorStyle, .caret)
    }

    // MARK: - Revision mechanism (plan §4.1 — the @Observable reactivity fix)

    func testRevisionBumpsOnExternalStoreChange() async {
        let store = InMemorySettingsStore.fixtureSettled()
        let model = makeModel(store)
        await Task.yield() // let the model's onChange subscription start before mutating
        let before = model.revision
        store.hotkey = nil
        for _ in 0..<50 where model.revision == before {
            await Task.yield()
        }
        XCTAssertGreaterThan(model.revision, before)
    }

    func testExternalStoreChangeInvalidatesObservation() async {
        let store = InMemorySettingsStore.fixtureSettled()
        let model = makeModel(store)
        await Task.yield() // subscribe before mutating
        // withObservationTracking's onChange is @Sendable — box the flag (test-only).
        final class Flag: @unchecked Sendable { var value = false }
        let changed = Flag()
        withObservationTracking {
            _ = model.attention
        } onChange: {
            changed.value = true
        }
        store.rules.removeAll()
        for _ in 0..<50 where !changed.value {
            await Task.yield()
        }
        XCTAssertTrue(changed.value, "a store change must invalidate views reading model state")
    }

    func testActiveInstalledVersionsFiltersToInstalled() {
        let store = InMemorySettingsStore()
        store.testSetInstalledVersions([.v2, .v3])
        let model = makeModel(store)
        XCTAssertEqual(model.activeInstalledVersions, [.v2, .v3])
        XCTAssertEqual(model.activeSelection, .v2)
    }

    func testFixtureMultipleHasTwoInstalled() {
        let s = InMemorySettingsStore.fixtureEngineMultiple()
        let m = makeModel(s)
        XCTAssertEqual(m.activeInstalledVersions.count, 2)
        XCTAssertEqual(m.activeInstalledVersions, [.v2, .v3])
        XCTAssertEqual(m.activeSelection, .v2)
        XCTAssertTrue(m.isModelVersionInstalled(.v2))
        XCTAssertTrue(m.isModelVersionInstalled(.v3))
        XCTAssertFalse(m.isModelVersionInstalled(.tdtCtc110m))
    }

    func testFixtureMultipleIncompleteHasTwoInstalled() {
        let s = InMemorySettingsStore.fixtureEngineMultipleIncomplete()
        let m = makeModel(s)
        XCTAssertEqual(m.activeInstalledVersions.count, 2)
        XCTAssertEqual(m.activeInstalledVersions, [.v2, .v3])
        XCTAssertEqual(m.activeSelection, .v2)
        XCTAssertEqual(m.engine, .incomplete)
        XCTAssertTrue(m.isModelVersionInstalled(.v2))
        XCTAssertTrue(m.isModelVersionInstalled(.v3))
    }

    func testIsModelVersionInstalledReflectsInstalled() {
        let store = InMemorySettingsStore()
        store.testSetInstalledVersions([.v3])
        let m = makeModel(store)
        XCTAssertFalse(m.isModelVersionInstalled(.v2))
        XCTAssertTrue(m.isModelVersionInstalled(.v3))
        XCTAssertFalse(m.isModelVersionInstalled(.tdtCtc110m))
        store.testSetInstalledVersions([])
        XCTAssertFalse(m.isModelVersionInstalled(.v3))
    }

    func testApplyModelFolderForTestingStillWorks() {
        let store = InMemorySettingsStore()
        let url = URL(fileURLWithPath: "/tmp/KalamTestModels")
        store.applyModelFolderForTesting(url, presence: .missing)
        let m = makeModel(store)
        XCTAssertEqual(m.modelFolder, url)
        XCTAssertEqual(m.engine, .missing)
        let url2 = URL(fileURLWithPath: "/tmp/KalamTestModels2")
        store.applyModelFolderForTesting(url2, presence: .verified(ModelInfo(name: "Parakeet v2", detail: "English-only \u{00B7} 5 of 5")))
        XCTAssertEqual(m.modelFolder, url2)
        if case .verified(let info) = m.engine {
            XCTAssertEqual(info.name, "Parakeet v2")
        } else {
            XCTFail("expected verified")
        }
    }

    // MARK: - Option D wizard routing (Task 1: backing contract + derived routing)

    func testSetupStep1ActiveOnFirstRun() {
        let model = makeModel(InMemorySettingsStore.fixtureSetupMissingDefault())
        // Bookmark-unresolvable renders this same figure (no bookmark stored,
        // so no not-found branch — the Step-1 body shows the default-path sub).
        XCTAssertFalse(model.isFolderMissingOnDisk)
        XCTAssertFalse(model.hasConfirmedHFCLIInstall)
        XCTAssertEqual(model.setupStep.activeStep, .folder)
        XCTAssertTrue(model.setupStep.isToolLocked)
        XCTAssertTrue(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "1 of 3 · ~450 MB")
        XCTAssertEqual(model.setupStep.headerTone, .neutral)
        XCTAssertEqual(
            model.setupStep.lede,
            "No model in this folder yet. 3 steps · ~5 min · Terminal once — Kalam verifies the folder automatically."
        )
    }

    func testSetupStep2ActiveWhenFolderChosen() {
        let model = makeModel(InMemorySettingsStore.fixtureSetupFolderChosen())
        XCTAssertFalse(model.isFolderMissingOnDisk)
        XCTAssertEqual(model.setupStep.activeStep, .tool)
        XCTAssertFalse(model.setupStep.isToolLocked)
        XCTAssertTrue(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "2 of 3 · ~450 MB")
        XCTAssertEqual(model.setupStep.lede, "Folder chosen. Install the tool, then download a model into it.")
    }

    func testSetupConfirmFlagAdvancesToStep3() {
        let store = InMemorySettingsStore.fixtureSetupFolderChosen()
        let model = makeModel(store)
        XCTAssertFalse(model.hasConfirmedHFCLIInstall)
        model.hasConfirmedHFCLIInstall = true
        XCTAssertTrue(store.hasConfirmedHFCLIInstall)
        XCTAssertEqual(model.setupStep.activeStep, .download)
        XCTAssertFalse(model.setupStep.isToolLocked)
        XCTAssertFalse(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "3 of 3 · ~450 MB")
        XCTAssertEqual(
            model.setupStep.lede,
            "Tool confirmed. Pick how you dictate, then run one command in Terminal."
        )
    }

    func testSetupIncompleteRoutesToStep3WithCounts() {
        let store = InMemorySettingsStore.fixtureSetupIncomplete()
        let model = makeModel(store)
        XCTAssertFalse(model.isFolderMissingOnDisk)
        XCTAssertEqual(model.setupStep.activeStep, .download)
        XCTAssertFalse(model.setupStep.isToolLocked)
        XCTAssertFalse(model.setupStep.isDownloadLocked)
        let manifest = model.modelFileManifest(for: .v2)
        XCTAssertEqual(manifest.count, ModelSetupSupport.requiredModelFiles(for: .v2).count)
        XCTAssertEqual(manifest.filter(\.isPresent).count, 3)
        XCTAssertEqual(model.setupStep.headerTrailing, "Incomplete — 3 of \(manifest.count)")
        XCTAssertEqual(model.setupStep.headerTone, .warn)
        XCTAssertEqual(
            model.setupStep.lede,
            "This folder has part of a model. Run the command again — it skips files already on disk."
        )
    }

    func testSetupVerifiedSingleCollapses() {
        let model = makeModel(InMemorySettingsStore.fixtureSetupVerifiedSingle())
        XCTAssertFalse(model.isFolderMissingOnDisk)
        XCTAssertEqual(model.setupStep.activeStep, .done)
        XCTAssertFalse(model.setupStep.isToolLocked)
        XCTAssertFalse(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "Verified")
        XCTAssertEqual(model.setupStep.headerTone, .ok)
        XCTAssertEqual(
            model.setupStep.lede,
            "You supply the model and Kalam loads it locally on the Apple Neural Engine."
        )
    }

    func testSetupVerifiedMultiCollapses() {
        let model = makeModel(InMemorySettingsStore.fixtureSetupVerifiedMulti())
        XCTAssertEqual(model.setupStep.activeStep, .done)
        XCTAssertFalse(model.setupStep.isToolLocked)
        XCTAssertFalse(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "Verified")
        XCTAssertEqual(model.setupStep.headerTone, .ok)
        XCTAssertEqual(model.setupStep.lede, "Two models in this folder — pick which one Kalam loads.")
    }

    func testSetupFolderDeletedRoutesToStep1WithNotFound() {
        let store = InMemorySettingsStore.fixtureSetupFolderDeleted()
        let model = makeModel(store)
        XCTAssertTrue(model.isFolderMissingOnDisk)
        // The Step-2 attestation is machine-wide: it stays confirmed even
        // though routing falls back to Step 1 (completion ≠ routing).
        XCTAssertTrue(store.hasConfirmedHFCLIInstall)
        XCTAssertEqual(model.setupStep.activeStep, .folder)
        XCTAssertTrue(model.setupStep.isToolLocked)
        XCTAssertTrue(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "Folder not found")
        XCTAssertEqual(model.setupStep.headerTone, .bad)
        XCTAssertEqual(
            model.setupStep.lede,
            "The chosen folder is gone. Pick it again or choose a new one — Kalam will verify automatically."
        )
    }

    func testSetupRepoGuardRoutesToStep1() {
        let model = makeModel(InMemorySettingsStore.fixtureSetupRepoGuard())
        XCTAssertFalse(model.isFolderMissingOnDisk)
        XCTAssertEqual(model.setupStep.activeStep, .folder)
        XCTAssertTrue(model.setupStep.isToolLocked)
        XCTAssertTrue(model.setupStep.isDownloadLocked)
        XCTAssertTrue(model.setupStep.isRepoGuard)
        XCTAssertEqual(model.setupStep.headerTrailing, "1 of 3 · ~450 MB")
    }

    func testSetupChangeFolderReactivatesStep3() {
        let store = InMemorySettingsStore.fixtureSetupVerifiedSingle()
        let model = makeModel(store)
        XCTAssertEqual(model.setupStep.activeStep, .done)
        let newURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NewModels")
        store.applyModelFolderForTesting(newURL, presence: .missing)
        XCTAssertTrue(store.hasConfirmedHFCLIInstall, "folder change must not reset the machine-wide tool attestation")
        XCTAssertEqual(model.modelFolder, newURL)
        XCTAssertEqual(model.setupStep.activeStep, .download)
        XCTAssertFalse(model.setupStep.isToolLocked, "Step 2 stays complete after Change")
        XCTAssertFalse(model.setupStep.isDownloadLocked)
        XCTAssertEqual(model.setupStep.headerTrailing, "3 of 3 · ~450 MB")
    }

    func testSetupPickerChangeRederivesRouting() {
        // Header size follows the picker with no engine change.
        let store = InMemorySettingsStore.fixtureSetupMissingDefault()
        let model = makeModel(store)
        XCTAssertEqual(model.setupStep.headerTrailing, "1 of 3 · ~450 MB")
        store.selectedDownloadVersion = .tdtCtc110m
        XCTAssertEqual(model.setupStep.headerTrailing, "1 of 3 · ~220 MB")

        // Live picker coupling: writing asrVersion can flip engine
        // verified→missing; routing must re-derive on that change.
        let verified = InMemorySettingsStore.fixtureSetupVerifiedSingle()
        let verifiedModel = makeModel(verified)
        XCTAssertEqual(verifiedModel.setupStep.activeStep, .done)
        verified.selectedDownloadVersion = .v3
        verified.testSetEnginePresence(.missing)
        XCTAssertEqual(verifiedModel.setupStep.activeStep, .download)
        XCTAssertFalse(verifiedModel.setupStep.isToolLocked)
        XCTAssertFalse(verifiedModel.setupStep.isDownloadLocked)
        XCTAssertEqual(verifiedModel.setupStep.headerTrailing, "3 of 3 · ~450 MB")
    }

    func testSetupManifestPassthrough() {
        let store = InMemorySettingsStore.fixtureSetupIncomplete()
        store.testSetManifest(presentCount: 3, totalFor: .v2)
        let model = makeModel(store)
        let manifest = model.modelFileManifest(for: .v2)
        XCTAssertEqual(manifest.map(\.name), ModelSetupSupport.requiredModelFiles(for: .v2))
        XCTAssertEqual(manifest.filter(\.isPresent).count, 3)
        XCTAssertTrue(manifest.dropFirst(3).allSatisfy { !$0.isPresent })
    }

    func testSetupDiskSpaceSummary() {
        let store = InMemorySettingsStore.fixtureSetupFolderChosen()
        store.engineFolderFreeBytes = 410_000_000
        let model = makeModel(store)
        XCTAssertEqual(model.engineDiskSpace.freeBytes, 410_000_000)
        XCTAssertEqual(model.engineDiskSpace.neededDescription, "~450 MB")
        XCTAssertTrue(model.engineDiskSpace.summary.hasPrefix("Needed ~450 MB · Free "))
        XCTAssertTrue(model.engineDiskSpace.summary.contains("410"))
        store.selectedDownloadVersion = .tdtCtc110m
        XCTAssertEqual(model.engineDiskSpace.neededDescription, "~220 MB")
        XCTAssertTrue(model.engineDiskSpace.summary.hasPrefix("Needed ~220 MB · Free "))
    }
}
