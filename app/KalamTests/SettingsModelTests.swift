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
}
