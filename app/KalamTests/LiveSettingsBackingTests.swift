import XCTest
import KalamTextEngine
@testable import Kalam_test

/// settings redesign (settings UI): the LiveSettingsBacking adapter maps the settings UI protocol onto the live
/// stores without a second UserDefaults schema. Isolated defaults + temp dictionary files.
@MainActor
final class LiveSettingsBackingTests: XCTestCase {

    private var suite: UserDefaults!
    private var manager: CustomDictionaryManager!
    private var dictURL: URL!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "LiveSettingsBackingTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dictURL = dir.appendingPathComponent("user_dictionary.json")
        manager = CustomDictionaryManager(storeURL: dictURL)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dictURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeBacking() -> LiveSettingsBacking {
        LiveSettingsBacking(manager: manager, defaults: suite)
    }

    // MARK: - Indicator migration

    func testIndicatorCoercesLegacyBottomCenterToBottomCenter() {
        suite.set("bottomCenter", forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        XCTAssertEqual(makeBacking().indicator, .bottomCenter)
    }

    func testIndicatorCoercesRemovedSidePlacementsToTopCenter() {
        for legacy in ["topLeft", "topRight"] {
            suite.set(legacy, forKey: GeneralSettingsKeys.indicatorPlacementPreset)
            XCTAssertEqual(makeBacking().indicator, .topCenter)
        }
    }

    func testIndicatorCoercesUnknownToTopCenter() {
        suite.set("Off", forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        XCTAssertEqual(makeBacking().indicator, .topCenter)
    }

    func testIndicatorWriteThroughPersistsNewRawValue() {
        let backing = makeBacking()
        backing.indicator = .bottomCenter
        XCTAssertEqual(suite.string(forKey: GeneralSettingsKeys.indicatorPlacementPreset), "bottomCenter")
        XCTAssertEqual(makeBacking().indicator, .bottomCenter)
    }

    // MARK: - Indicator style

    func testIndicatorStyleRoundTrip() {
        let backing = makeBacking()
        backing.indicatorStyle = .whisper
        XCTAssertEqual(suite.string(forKey: GeneralSettingsKeys.indicatorStylePreset), "whisper")
        XCTAssertEqual(makeBacking().indicatorStyle, .whisper)
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
        let second = LiveSettingsBacking(manager: manager, defaults: suite)
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

    /// Being-heard mic list live refresh: a CoreAudio topology change posted by
    /// KalamApp's AudioDeviceMonitor path must re-enumerate the cached list (and
    /// yield onChange) while the settings window is open — otherwise a device
    /// connecting mid-session shows OFFLINE until the window is reopened.
    func testAudioDevicesDidChangeRefreshesMicrophonesAndPings() async {
        let backing = makeBacking()
        var iterator = backing.onChange.makeAsyncIterator()
        await Task.yield() // let the subscription settle before posting
        NotificationCenter.default.post(name: .audioDevicesDidChange, object: nil)
        let yielded = await iterator.next()
        XCTAssertNotNil(yielded, "device-change notification must refresh the mic list")
        // The refreshed cache must equal a fresh enumeration over the same defaults.
        let fresh = MicrophoneDeviceService
            .mergedPriorityList(config: MicrophonePriorityConfiguration.load(from: suite))
        XCTAssertEqual(backing.microphones.map(\.id), fresh.map(\.uid))
        XCTAssertEqual(backing.microphones.map(\.isConnected), fresh.map(\.isAvailable))
    }

    // MARK: - A2DP-idle wakeability

    private final class WakeCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func record(_ uid: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(uid)
        }
        func recordedCalls() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private func fallbackConfig(priorities: [(uid: String, name: String)]) -> MicrophonePriorityConfiguration {
        MicrophonePriorityConfiguration(
            priorityUIDs: priorities.map(\.uid),
            knownDeviceNames: Dictionary(uniqueKeysWithValues: priorities.map { ($0.uid, $0.name) })
        )
    }

    /// Log-diagnosis regression: AirPods stay enumerated as hardware objects
    /// while parked in A2DP (zero input channels). The merged list must surface
    /// them wakeable rather than indistinguishable from unplugged devices.
    func testMergedPriorityListMarksPresentIdleBluetoothAsWakeable() throws {
        let merged = MicrophoneDeviceService.mergedPriorityList(
            config: fallbackConfig(priorities: [("airpods", "k’s AirPods Pro")]),
            liveTransportTagsByUID: ["airpods": "bluetooth"]
        )
        let row = try XCTUnwrap(merged.first)
        XCTAssertEqual(row.uid, "airpods")
        XCTAssertFalse(row.isAvailable, "idle headset is still not usable for capture")
        XCTAssertTrue(row.isWakeable, "present BT without input stream must be wakeable")
        XCTAssertEqual(row.transportTag, "bluetooth")
    }

    func testMergedPriorityListKeepsGoneDevicePlainOffline() throws {
        let merged = MicrophoneDeviceService.mergedPriorityList(
            config: fallbackConfig(priorities: [("usb-codec", "USB audio CODEC")]),
            liveTransportTagsByUID: [:]
        )
        let row = try XCTUnwrap(merged.first)
        XCTAssertFalse(row.isAvailable)
        XCTAssertFalse(row.isWakeable, "no hardware object ⇒ genuinely gone, not wakeable")
        XCTAssertEqual(row.transportTag, "unknown")
    }

    func testMergedPriorityListDoesNotWakeNonBluetoothDrops() throws {
        let merged = MicrophoneDeviceService.mergedPriorityList(
            config: fallbackConfig(priorities: [("webcam", "HD Webcam C920")]),
            liveTransportTagsByUID: ["webcam": "usb"]
        )
        let row = try XCTUnwrap(merged.first)
        XCTAssertFalse(row.isAvailable)
        XCTAssertFalse(row.isWakeable)
    }

    /// 2026-08-27 live regression: the stored priority UID is the HFP-live
    /// form "<base>:input", but the parked A2DP object enumerates under the
    /// bare base UID — the exact-key presence lookup missed it, so the row
    /// stayed dead OFFLINE and TAP TO WAKE never appeared.
    func testMergedPriorityListMarksIdleBluetoothUnderSiblingUIDWakeable() throws {
        let merged = MicrophoneDeviceService.mergedPriorityList(
            config: fallbackConfig(priorities: [("3C-4D-BE-8E-5D-7A:input", "k’s AirPods Pro")]),
            liveTransportTagsByUID: ["3C-4D-BE-8E-5D-7A": "bluetooth"]
        )
        let row = try XCTUnwrap(merged.first)
        XCTAssertFalse(row.isAvailable)
        XCTAssertTrue(row.isWakeable, "presence under a sibling UID must still offer wake")
        XCTAssertEqual(row.transportTag, "bluetooth")
    }

    /// A non-bluetooth object under the sibling UID is a different device, not
    /// a parked mic — never offer wake for it.
    func testSiblingUIDPresenceOnlyWakesBluetoothTransport() throws {
        let merged = MicrophoneDeviceService.mergedPriorityList(
            config: fallbackConfig(priorities: [("3C-4D-BE-8E-5D-7A:input", "k’s AirPods Pro")]),
            liveTransportTagsByUID: ["3C-4D-BE-8E-5D-7A": "usb"]
        )
        let row = try XCTUnwrap(merged.first)
        XCTAssertFalse(row.isWakeable)
    }

    /// Drift detector for the sibling-UID heuristic itself.
    func testCandidateUIDsCoverBaseAndOutputSiblingsExactFirst() {
        XCTAssertEqual(
            AudioDeviceDebug.candidateUIDs(forStoredUID: "3C-4D-BE-8E-5D-7A:input"),
            ["3C-4D-BE-8E-5D-7A:input", "3C-4D-BE-8E-5D-7A", "3C-4D-BE-8E-5D-7A:output"]
        )
        // USB-style UIDs (final segment not an input/output side) stay single-candidate.
        XCTAssertEqual(
            AudioDeviceDebug.candidateUIDs(forStoredUID: "AppleUSBAudioEngine:HD Pro Webcam C920:35C379AF:3"),
            ["AppleUSBAudioEngine:HD Pro Webcam C920:35C379AF:3"]
        )
    }

    /// TAP TO WAKE end-to-end over the store contract: delegate to the injected
    /// waker exactly once per tap, then refresh (+ping onChange).
    func testWakeMicrophoneDelegatesAndRefreshesWithPing() async throws {
        let recorder = WakeCallRecorder()
        let backing = LiveSettingsBacking(manager: manager, defaults: suite) { uid in
            recorder.record(uid)
            return true
        }
        var iterator = backing.onChange.makeAsyncIterator()
        await Task.yield() // let the subscription settle before invoking
        backing.wakeMicrophone(uid: "airpods")
        let yielded = await iterator.next()
        XCTAssertNotNil(yielded, "wake completion must refresh the mic list")
        XCTAssertEqual(recorder.recordedCalls(), ["airpods"])
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

    // MARK: - Engine wizard confirm flag (Option D Step 2)

    func testHFCLIConfirmedDefaultsFalse() {
        XCTAssertFalse(makeBacking().hasConfirmedHFCLIInstall)
        XCTAssertFalse(suite.bool(forKey: "engine.hfCLIConfirmed"))
    }

    func testHFCLIConfirmedRoundTrip() {
        let backing = makeBacking()
        backing.hasConfirmedHFCLIInstall = true
        XCTAssertTrue(suite.bool(forKey: "engine.hfCLIConfirmed"))
        XCTAssertTrue(makeBacking().hasConfirmedHFCLIInstall)
        backing.hasConfirmedHFCLIInstall = false
        XCTAssertFalse(suite.bool(forKey: "engine.hfCLIConfirmed"))
        XCTAssertFalse(makeBacking().hasConfirmedHFCLIInstall)
    }

    func testHFCLIConfirmedSurvivesFolderChange() throws {
        let backing = makeBacking()
        backing.hasConfirmedHFCLIInstall = true
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamHFCLIKeep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = ModelsConfiguration.load(from: suite)
        try config.setModelLibraryURL(dir)
        config.save(to: suite)

        XCTAssertTrue(suite.bool(forKey: "engine.hfCLIConfirmed"), "choosing a folder must not reset the machine-wide attestation")
        XCTAssertTrue(makeBacking().hasConfirmedHFCLIInstall)
    }

    // MARK: - Engine wizard manifest + disk space (Option D Step 3 / S6)

    func testModelFileManifestMatchesRequiredModelFiles() throws {
        XCTAssertFalse(makeBacking().isModelLibraryConfigured)
        XCTAssertTrue(makeBacking().modelFileManifest(for: .v2).isEmpty)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var config = ModelsConfiguration.load(from: suite)
        try config.setModelLibraryURL(library)
        config.save(to: suite)

        let backing = makeBacking()
        XCTAssertTrue(backing.isModelLibraryConfigured)
        let manifest = backing.modelFileManifest(for: .v2)
        // Same file source as the validator — including the vocab file, which
        // `requiredModelDirectoryNames` never contains.
        XCTAssertEqual(manifest.map(\.name), ModelSetupSupport.requiredModelFiles(for: .v2))
        XCTAssertTrue(manifest.allSatisfy { !$0.isPresent })
        XCTAssertTrue(manifest.contains { $0.name.localizedCaseInsensitiveContains("vocab") })
    }

    func testEngineFolderFreeBytesForExistingFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamFreeBytesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = ModelsConfiguration.load(from: suite)
        try config.setModelLibraryURL(dir)
        config.save(to: suite)

        let backing = makeBacking()
        XCTAssertTrue(backing.modelFolderExistsOnDisk)
        let free = backing.engineFolderFreeBytes
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
    }

    // MARK: - Preset menu plain-name hints (hotkey onboarding card UX seventh round)

    func testTwoGlyphCombosSpellTheirModifiersInWords() {
        XCTAssertEqual(HotkeyPreset.optCmd.plainNameHint, "Option Command")
        XCTAssertEqual(HotkeyPreset.ctrlCmd.plainNameHint, "Control Command")
        XCTAssertEqual(HotkeyPreset.ctrlOpt.plainNameHint, "Control Option")
        XCTAssertEqual(HotkeyPreset.shiftCmd.plainNameHint, "Shift Command")
        XCTAssertEqual(HotkeyPreset.optShift.plainNameHint, "Option Shift")
        XCTAssertEqual(HotkeyPreset.ctrlShift.plainNameHint, "Control Shift")
    }

    func testSingleKeyAndSpecialRowsNeedNoSpelledName() {
        XCTAssertNil(HotkeyPreset.none.plainNameHint)
        XCTAssertNil(HotkeyPreset.record.plainNameHint)
        XCTAssertNil(HotkeyPreset.fn.plainNameHint)
        for side in [HotkeyPreset.rightCmd, .rightOpt, .rightShift, .rightCtrl] {
            XCTAssertNil(side.plainNameHint, "\(side) already says Right in words")
        }
    }

    /// Drift detector: every spelled hint must agree with the stored chord's
    /// verbose naming (minus the " + " joiner), and vice versa for combos.
    func testPlainNameHintsTrackMapVerbose() {
        for preset in HotkeyPreset.allCases {
            guard let hint = preset.plainNameHint else { continue }
            XCTAssertEqual(hint, preset.mapVerbose?.replacingOccurrences(of: " + ", with: " "))
        }
    }

    // MARK: - Engine scan memo (tap-lag fix)

    /// Disk truth re-enters only via rescan/folder-change/notification: an
    /// external change with no rescan stays stale by design (the UI promises
    /// "Check again"), and `rescanEngine()` picks it up.
    func testEngineMemoHoldsUntilRescan() throws {
        let backing = makeBacking()
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamEngineMemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        var config = ModelsConfiguration.load(from: suite)
        try config.setModelLibraryURL(library)
        config.save(to: suite)

        XCTAssertEqual(backing.engine, .missing)
        // External change, no rescan: memo holds.
        let version = ModelsConfiguration.load(from: suite).asrVersion
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(version.repositoryFolderName, isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertEqual(backing.engine, .missing)
        // Explicit rescan re-reads disk: an empty repo dir is invalid, not missing.
        backing.rescanEngine()
        XCTAssertEqual(backing.engine, .incomplete)
    }

    // MARK: - Appearance preference

    func testAppearanceDefaultsToSystem() {
        XCTAssertEqual(makeBacking().appearance, .system)
    }

    func testAppearanceCoercesUnknownToSystem() {
        suite.set("neon", forKey: GeneralSettingsKeys.appearanceMode)
        XCTAssertEqual(makeBacking().appearance, .system)
    }

    func testAppearanceWriteThroughPersistsRawValue() {
        makeBacking().appearance = .dark
        XCTAssertEqual(suite.string(forKey: GeneralSettingsKeys.appearanceMode), "dark")
        XCTAssertEqual(GeneralSettingsConfiguration.load(from: suite).appearanceMode, .dark)
    }
}
