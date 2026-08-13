import XCTest
import KalamTextEngine
@testable import Kalam_test

/// K-30 (Compass): the LiveCompassBacking adapter maps the Compass protocol onto the live
/// stores without a second UserDefaults schema. Isolated defaults + temp dictionary files.
@MainActor
final class LiveCompassBackingTests: XCTestCase {

    private var suite: UserDefaults!
    private var manager: CustomDictionaryManager!
    private var dictURL: URL!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "LiveCompassBackingTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamCompassTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dictURL = dir.appendingPathComponent("user_dictionary.json")
        manager = CustomDictionaryManager(storeURL: dictURL)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dictURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeBacking() -> LiveCompassBacking {
        LiveCompassBacking(manager: manager, defaults: suite)
    }

    // MARK: - Indicator migration

    func testIndicatorCoercesLegacyBottomCenterToTopCenter() {
        suite.set("bottomCenter", forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        XCTAssertEqual(makeBacking().indicator, .topCenter)
    }

    func testIndicatorCoercesUnknownToTopCenter() {
        suite.set("Off", forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        XCTAssertEqual(makeBacking().indicator, .topCenter)
    }

    func testIndicatorWriteThroughPersistsNewRawValue() {
        let backing = makeBacking()
        backing.indicator = .topLeft
        XCTAssertEqual(suite.string(forKey: GeneralSettingsKeys.indicatorPlacementPreset), "topLeft")
        XCTAssertEqual(makeBacking().indicator, .topLeft)
    }

    // MARK: - Behavior toggles

    func testBehaviorTogglesRoundTrip() {
        let backing = makeBacking()
        backing.launchAtLogin = true
        backing.escapeCancels = true
        backing.muteOtherAudio = false
        XCTAssertTrue(GeneralSettingsConfiguration.load(from: suite).launchAtLogin)
        XCTAssertTrue(GeneralSettingsConfiguration.load(from: suite).escapeCancelsRecording)
        XCTAssertFalse(GeneralSettingsConfiguration.load(from: suite).muteWhileRecording)
        let fresh = makeBacking()
        XCTAssertTrue(fresh.launchAtLogin)
        XCTAssertTrue(fresh.escapeCancels)
        XCTAssertFalse(fresh.muteOtherAudio)
    }

    // MARK: - Hotkey

    func testHotkeyPresetRoundTrip() {
        var config = PTTHotkeyConfiguration.load(from: suite)
        config.apply(keyCombination: .rightCommand)
        config.save(to: suite)

        let backing = makeBacking()
        XCTAssertEqual(backing.hotkey?.displayVerbose, "Right Command")
        XCTAssertEqual(backing.hotkey?.displayCompact, "Right ⌘")

        backing.hotkey = nil
        let reloaded = PTTHotkeyConfiguration.load(from: suite)
        XCTAssertEqual(reloaded.keyCombination, .notSpecified)
        XCTAssertNil(reloaded.customChord)
        XCTAssertNil(makeBacking().hotkey)
    }

    func testCustomChordPersistsAndWins() {
        let chord = KeyChord(
            keyCode: 1,
            modifiersRaw: NSEvent.ModifierFlags.option.rawValue,
            side: .either,
            displayVerbose: "Option + S",
            displayCompact: "⌥ S"
        )
        let backing = makeBacking()
        backing.hotkey = chord

        let reloaded = PTTHotkeyConfiguration.load(from: suite)
        XCTAssertEqual(reloaded.customChord, chord)
        XCTAssertEqual(reloaded.keyCombination, .notSpecified)
        XCTAssertEqual(makeBacking().hotkey, chord)
    }

    func testPresetSelectionClearsCustomChord() {
        let chord = KeyChord(
            keyCode: 1,
            modifiersRaw: NSEvent.ModifierFlags.option.rawValue,
            side: .either,
            displayVerbose: "Option + S",
            displayCompact: "⌥ S"
        )
        let backing = makeBacking()
        backing.hotkey = chord
        backing.hotkey = HotkeyPreset.ctrlCmd.makeChord()
        let reloaded = PTTHotkeyConfiguration.load(from: suite)
        XCTAssertNil(reloaded.customChord)
        XCTAssertEqual(reloaded.keyCombination, .controlCommand)
    }

    // MARK: - Cleanup mapping

    func testCleanupMappingRoundTrip() {
        var config = ModelsConfiguration.load(from: suite)
        config.textCleanup.enabled = true
        config.textCleanup.removeFillers = false
        config.textCleanup.backtrack = true
        config.textCleanup.listFormatting = true
        config.textCleanup.punctuation = false
        config.textCleanup.grammarMode = .full
        config.save(to: suite)

        let backing = makeBacking()
        XCTAssertTrue(backing.cleanupEnabled)
        XCTAssertFalse(backing.removeFillers)
        XCTAssertTrue(backing.handleBacktracks)
        XCTAssertTrue(backing.formatLists)
        XCTAssertFalse(backing.normalizePunctuation)
        XCTAssertEqual(backing.grammarPass, .full)

        backing.removeFillers = true
        backing.grammarPass = .light
        let reloaded = ModelsConfiguration.load(from: suite).textCleanup
        XCTAssertTrue(reloaded.removeFillers)
        XCTAssertEqual(reloaded.grammarMode, .light)
    }

    // MARK: - Dictionary

    func testRulesMapToEntriesAndBack() {
        manager.entries = [
            DictionaryEntry(trigger: "siobhan", replacement: "Siobhan", isEnabled: true, caseInsensitive: true, preserveCase: true, userAdded: true),
            DictionaryEntry(trigger: "one on one", replacement: "1:1", isEnabled: true, caseInsensitive: false, preserveCase: false, userAdded: true),
        ]
        let backing = makeBacking()
        XCTAssertEqual(backing.rules.count, 2)
        XCTAssertEqual(backing.rules[0].mode, .smart)
        XCTAssertEqual(backing.rules[1].mode, .literal)

        backing.rules = [
            ReplacementRule(spoken: "worcester", typed: "Worcester", mode: .smart),
            ReplacementRule(spoken: "x y", typed: "xy", mode: .literal),
        ]
        XCTAssertEqual(manager.entries.count, 2)
        XCTAssertEqual(manager.entries[0].trigger, "worcester")
        XCTAssertTrue(manager.entries[0].caseInsensitive)
        XCTAssertFalse(manager.entries[1].caseInsensitive)
        XCTAssertTrue(manager.entries[1].userAdded)
        XCTAssertTrue(manager.entries[1].isEnabled)
    }

    func testRulesSetterTrimsAndCapsAt128Scalars() {
        let backing = makeBacking()
        let long = String(repeating: "a", count: 200) + "\nb"
        backing.rules = [ReplacementRule(spoken: long, typed: " t ", mode: .smart)]
        XCTAssertEqual(manager.entries[0].trigger.count, 128)
        XCTAssertFalse(manager.entries[0].trigger.contains("\n"))
        XCTAssertEqual(manager.entries[0].replacement, "t")
    }

    func testDisabledRulesReEnabledOnceWithMigrationFlag() {
        manager.entries = [
            DictionaryEntry(trigger: "foo", replacement: "bar", isEnabled: false, caseInsensitive: true, preserveCase: true, userAdded: true),
        ]
        let backing = makeBacking()
        XCTAssertEqual(backing.rules.count, 1)
        XCTAssertTrue(manager.entries[0].isEnabled, "disabled rules must be re-enabled once")
        XCTAssertTrue(suite.bool(forKey: DictionaryRuleMigration.flagKey))

        // Second backing: no-op (flag set).
        let second = LiveCompassBacking(manager: manager, defaults: suite)
        XCTAssertEqual(second.rules.count, 1)
        XCTAssertTrue(manager.entries[0].isEnabled)
    }

    func testLoadFailureNoticeIsForwarded() {
        manager.loadFailureNotice = "Kalam couldn't read your saved dictionary."
        XCTAssertEqual(makeBacking().dictionaryLoadFailureNotice, "Kalam couldn't read your saved dictionary.")
    }

    // MARK: - Microphones

    func testLastUsedIDMapsToSelectedInputUID() {
        let backing = makeBacking()
        XCTAssertNil(backing.lastUsedID)
        backing.lastUsedID = "builtin-mic-uid"
        XCTAssertEqual(suite.string(forKey: GeneralSettingsKeys.selectedInputUID), "builtin-mic-uid")
        XCTAssertEqual(makeBacking().lastUsedID, "builtin-mic-uid")
    }

    func testMoveMicrophonePersistsPriorityOrder() throws {
        let backing = makeBacking()
        let ids = backing.microphones.map(\.id)
        guard ids.count >= 2 else {
            throw XCTSkip("test host reports no input devices — nothing to reorder")
        }
        backing.moveMicrophone(from: IndexSet(integer: 0), to: ids.count)
        let persisted = MicrophonePriorityConfiguration.load(from: suite).priorityUIDs
        XCTAssertEqual(persisted.first, ids[1])
        XCTAssertEqual(backing.microphones.first?.id, ids[1])
    }

    // MARK: - Engine

    func testEngineMissingWhenLibraryNotConfigured() {
        XCTAssertEqual(makeBacking().engine, .missing)
    }

    func testEnginePresenceFromAvailability() throws {
        let lib = dictURL.deletingLastPathComponent().appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        var config = ModelsConfiguration.load(from: suite)
        try config.setModelLibraryURL(lib)
        config.asrVersion = .v2
        config.save(to: suite)

        // No parakeet folder → missing.
        XCTAssertEqual(makeBacking().engine, .missing)

        // Partial model folder → incomplete.
        let repo = lib.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(makeBacking().engine, .incomplete)
    }
}
