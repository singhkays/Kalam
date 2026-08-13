import XCTest
import Observation
@testable import Kalam_test

/// K-30 (Compass): derived map/dive state lives in SettingsModel — pins attention priority,
/// spanning, hero copy, map card strings, contents states, and the revision mechanism that
/// makes the @Observable façade react to external store changes (plan §4.1).
@MainActor
final class SettingsModelTests: XCTestCase {

    private func makeModel(_ store: InMemoryCompassStore = InMemoryCompassStore()) -> SettingsModel {
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
        XCTAssertNil(makeModel(InMemoryCompassStore.fixtureSettled()).attention)
    }

    func testAttentionEmptyDictionaryIsLowestPriority() {
        XCTAssertEqual(
            makeModel(InMemoryCompassStore.fixtureDefaultEmptyDictionary()).attention,
            .dictionary
        )
    }

    func testAttentionEngineMissingBeatsEmptyDictionary() {
        let store = InMemoryCompassStore.fixtureEngineMissing()
        store.rules = [] // two problems — engine must win
        XCTAssertEqual(makeModel(store).attention, .engine)
    }

    func testAttentionEngineIncompleteBeatsEverything() {
        let store = InMemoryCompassStore.fixtureEngineIncomplete()
        store.rules = []
        store.hotkey = nil
        store.microphones = []
        XCTAssertEqual(makeModel(store).attention, .engine)
    }

    func testAttentionNoMicrophone() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureNoDevices()).attention, .beingHeard)
    }

    func testAttentionPermissionDeniedIsNoMicrophone() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixturePermissionDenied()).attention, .beingHeard)
    }

    func testAttentionKeyUnset() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).attention, .trigger)
    }

    // MARK: - Spanning (always exactly one span-2 card)

    func testSpanningIsAttentionWhenAttentionExists() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureNoDevices()).spanning, .beingHeard)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineMissing()).spanning, .engine)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).spanning, .trigger)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureDefaultEmptyDictionary()).spanning, .dictionary)
    }

    func testSpanningIsEngineFillWhenSettled() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureSettled()).spanning, .engine)
    }

    // MARK: - Hero

    func testHeroReadyWhenSettled() {
        let model = makeModel(InMemoryCompassStore.fixtureSettled())
        XCTAssertEqual(model.hero, .ready)
        XCTAssertEqual(model.hero.text, "Everything is ready.")
        XCTAssertEqual(model.hero.italicSuffix, "ready.")
    }

    func testHeroEngineMissingForBothMissingAndIncomplete() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineMissing()).hero, .engineMissing)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineIncomplete()).hero, .engineMissing)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineMissing()).hero.text, "The engine needs a model.")
    }

    func testHeroNoMicrophoneAndKeyUnset() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureNoDevices()).hero, .noMicrophone)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).hero, .keyUnset)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).hero.italicSuffix, "set.")
    }

    func testMapNeedCTAOnlyForActionableAttention() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineMissing()).mapNeedCTA, "Open the engine →")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureNoDevices()).mapNeedCTA, "Open being heard →")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).mapNeedCTA, "Open the trigger →")
        // Empty dictionary is span-attention only — no CTA.
        XCTAssertNil(makeModel(InMemoryCompassStore.fixtureDefaultEmptyDictionary()).mapNeedCTA)
        XCTAssertNil(makeModel(InMemoryCompassStore.fixtureSettled()).mapNeedCTA)
    }

    // MARK: - Map card strings

    func testMapCardTitle() {
        let model = makeModel(InMemoryCompassStore.fixtureSettled())
        XCTAssertEqual(model.mapCardTitle(for: .beingHeard), "HD Pro Webcam C920")
        XCTAssertEqual(model.mapCardTitle(for: .trigger), "Right Command")
        XCTAssertEqual(model.mapCardTitle(for: .cleanup), "3 rules, light")
        XCTAssertEqual(model.mapCardTitle(for: .dictionary), "3 rules")
        XCTAssertEqual(model.mapCardTitle(for: .engine), "Parakeet v3")
        XCTAssertEqual(model.mapCardTitle(for: .updates), "Updates")
    }

    func testMapCardTitleEdgeStates() {
        let empty = makeModel(InMemoryCompassStore.fixtureDefaultEmptyDictionary())
        XCTAssertEqual(empty.mapCardTitle(for: .dictionary), "No rules yet")
        XCTAssertEqual(empty.mapCardTitle(for: .beingHeard), "HD Pro Webcam C920")

        let keyUnset = makeModel(InMemoryCompassStore.fixtureKeyUnset())
        XCTAssertEqual(keyUnset.mapCardTitle(for: .trigger), "No key")

        let missing = makeModel(InMemoryCompassStore.fixtureEngineMissing())
        XCTAssertEqual(missing.mapCardTitle(for: .engine), "No model found")

        let incomplete = makeModel(InMemoryCompassStore.fixtureEngineIncomplete())
        XCTAssertEqual(incomplete.mapCardTitle(for: .engine), "Incomplete")
    }

    func testMapCardState() {
        let model = makeModel(InMemoryCompassStore.fixtureSettled())
        XCTAssertEqual(model.mapCardState(for: .beingHeard).text, "Ready")
        XCTAssertTrue(model.mapCardState(for: .beingHeard).ok)
        XCTAssertEqual(model.mapCardState(for: .trigger).text, "Set")
        XCTAssertEqual(model.mapCardState(for: .cleanup).text, "On")
        XCTAssertEqual(model.mapCardState(for: .dictionary).text, "Ready")
        XCTAssertEqual(model.mapCardState(for: .engine).text, "Verified")

        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureCleanupOff()).mapCardState(for: .cleanup).text, "Off")
        XCTAssertFalse(makeModel(InMemoryCompassStore.fixtureCleanupOff()).mapCardState(for: .cleanup).ok)
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineIncomplete()).mapCardState(for: .engine).text, "Incomplete")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureNoDevices()).mapCardState(for: .beingHeard).text, "Offline")
    }

    func testMapCardDescriptionAttentionLongForm() {
        let missing = makeModel(InMemoryCompassStore.fixtureEngineMissing())
        XCTAssertEqual(
            missing.mapCardDescription(for: .engine),
            "Put the five Parakeet files in ~/Kalam/models/ and Kalam will load them from disk."
        )
        let incomplete = makeModel(InMemoryCompassStore.fixtureEngineIncomplete())
        XCTAssertEqual(
            incomplete.mapCardDescription(for: .engine),
            "This folder has part of a model; add the rest of the Parakeet files so Kalam can load it from disk."
        )
        let settled = makeModel(InMemoryCompassStore.fixtureSettled())
        XCTAssertEqual(settled.mapCardDescription(for: .engine), "Recognition runs on this Mac.") // wide fill
    }

    func testCleanupMapTitle() {
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureSettled()).cleanupMapTitle, "3 rules, light")

        let off = InMemoryCompassStore.fixtureCleanupOff()
        off.removeFillers = true
        XCTAssertEqual(makeModel(off).cleanupMapTitle, "Off")

        let full = InMemoryCompassStore.fixtureSettled()
        full.removeFillers = false
        full.handleBacktracks = false
        full.formatLists = false
        full.normalizePunctuation = false
        full.grammarPass = .full
        XCTAssertEqual(makeModel(full).cleanupMapTitle, "0 rules, full") // grammar-only config
    }

    // MARK: - Contents nav states

    func testContentsState() {
        let model = makeModel(InMemoryCompassStore.fixtureSettled())
        XCTAssertEqual(model.contentsState(for: .beingHeard), "Ready")
        XCTAssertEqual(model.contentsState(for: .trigger), "Right Cmd")
        XCTAssertEqual(model.contentsState(for: .cleanup), "3/4")
        XCTAssertEqual(model.contentsState(for: .dictionary), "3 rules")
        XCTAssertEqual(model.contentsState(for: .engine), "v3")

        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureKeyUnset()).contentsState(for: .trigger), "Unset")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureDefaultEmptyDictionary()).contentsState(for: .dictionary), "Empty")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureCleanupOff()).contentsState(for: .cleanup), "Off")
        XCTAssertEqual(makeModel(InMemoryCompassStore.fixtureEngineMissing()).contentsState(for: .engine), "Missing")
    }

    // MARK: - Microphone status (IN USE = first connected, NOT row zero)

    func testMicrophoneStatusInUseIsFirstConnectedNotRowZero() {
        let store = InMemoryCompassStore()
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
        let store = InMemoryCompassStore.fixturePermissionDenied()
        store.microphones = [.init(id: "cam", name: "Cam", isConnected: true)]
        let model = makeModel(store)
        XCTAssertEqual(model.microphoneStatus(for: store.microphones[0]), "OFFLINE")
        XCTAssertNil(model.connectedMicrophone)
    }

    func testMoveMicrophoneReordersThroughStore() {
        let store = InMemoryCompassStore()
        let model = makeModel(store)
        XCTAssertEqual(model.microphones.map(\.id), ["cam", "mbp", "usb"])
        model.moveMicrophone(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.microphones.map(\.id), ["mbp", "usb", "cam"])
    }

    // MARK: - Revision mechanism (plan §4.1 — the @Observable reactivity fix)

    func testRevisionBumpsOnExternalStoreChange() async {
        let store = InMemoryCompassStore.fixtureSettled()
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
        let store = InMemoryCompassStore.fixtureSettled()
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
}
