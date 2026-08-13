import AppKit
import AVFoundation
import Combine
import Foundation
import KalamTextEngine

// MARK: - K-30 Compass → live app adapter
//
// The ONLY live-store access for the Compass UI. Persistence goes through the existing
// config structs and their existing notification posts — no new UserDefaults schema.
// `onChange` yields on every change source so SettingsModel's revision mechanism refreshes
// SwiftUI views (plan §4.1).

@MainActor
final class LiveCompassBacking: CompassSettingsBacking {
    private let manager: CustomDictionaryManager
    private let defaults: UserDefaults
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var dictionarySink: AnyCancellable?
    private var cachedMics: [Microphone] = []

    init(manager: CustomDictionaryManager = .shared, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        // The old settings shell seeded the dictionary on appear; Compass owns it here
        // (runs once per backing — the isFirstLaunch guard makes repeats no-ops).
        if manager.isFirstLaunch {
            manager.entries.removeAll { !$0.userAdded }
            manager.saveImmediately()
        }
        refreshMicrophones()
        dictionarySink = manager.$entries.sink { [weak self] _ in
            self?.ping()
        }
        let center = NotificationCenter.default
        for name in [
            Notification.Name.generalSettingsConfigurationDidChange,
            Notification.Name.pttHotkeyConfigurationDidChange,
            Notification.Name.modelsConfigurationDidChange,
            Notification.Name.microphonePriorityDidChange,
        ] {
            notificationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.ping()
                }
            )
        }
    }

    // No deinit: observers and the $entries sink capture `self` weakly, so a released
    // backing is harmless (pings no-op). A deinit cannot touch these MainActor-isolated,
    // non-Sendable properties under Swift 6.

    // MARK: - onChange

    var onChange: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    private func ping() {
        for c in continuations.values { c.yield(()) }
    }

    // MARK: - Behavior

    var launchAtLogin: Bool {
        get { GeneralSettingsConfiguration.load(from: defaults).launchAtLogin }
        set { saveGeneral { $0.launchAtLogin = newValue } }
    }

    var showInDock: Bool {
        get { GeneralSettingsConfiguration.load(from: defaults).showInDock }
        set { saveGeneral { $0.showInDock = newValue } }
    }

    var escapeCancels: Bool {
        get { GeneralSettingsConfiguration.load(from: defaults).escapeCancelsRecording }
        set { saveGeneral { $0.escapeCancelsRecording = newValue } }
    }

    var muteOtherAudio: Bool {
        get { GeneralSettingsConfiguration.load(from: defaults).muteWhileRecording }
        set { saveGeneral { $0.muteWhileRecording = newValue } }
    }

    var indicator: IndicatorPlacement {
        get { GeneralSettingsConfiguration.load(from: defaults).indicatorPlacement }
        set { saveGeneral { $0.indicatorPlacement = newValue } }
    }

    private func saveGeneral(_ mutate: (inout GeneralSettingsConfiguration) -> Void) {
        var config = GeneralSettingsConfiguration.load(from: defaults)
        mutate(&config)
        config.save(to: defaults)
        NotificationCenter.default.post(name: .generalSettingsConfigurationDidChange, object: nil)
        ping()
    }

    // MARK: - Microphones

    var microphones: [Microphone] { cachedMics }

    var lastUsedID: String? {
        get { defaults.string(forKey: GeneralSettingsKeys.selectedInputUID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: GeneralSettingsKeys.selectedInputUID)
            } else {
                defaults.removeObject(forKey: GeneralSettingsKeys.selectedInputUID)
            }
            ping()
        }
    }

    var microphonePermission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func moveMicrophone(from source: IndexSet, to destination: Int) {
        var mics = cachedMics
        mics.move(fromOffsets: source, toOffset: destination)
        let config = MicrophonePriorityConfiguration.load(from: defaults)
        var names = config.knownDeviceNames
        for mic in mics {
            names[mic.id] = mic.name
        }
        let updated = MicrophonePriorityConfiguration(priorityUIDs: mics.map(\.id), knownDeviceNames: names)
        updated.save(to: defaults)
        NotificationCenter.default.post(name: .microphonePriorityDidChange, object: nil)
        cachedMics = mics
        ping()
    }

    func refreshMicrophones() {
        let config = MicrophonePriorityConfiguration.load(from: defaults)
        let merged = MicrophoneDeviceService.mergedPriorityList(config: config)
        cachedMics = merged.map {
            Microphone(id: $0.uid, name: $0.name, isConnected: $0.isAvailable)
        }
        ping()
    }

    // MARK: - Trigger

    var activation: ActivationMode {
        get {
            switch PTTHotkeyConfiguration.load(from: defaults).activationMode {
            case .holdOrToggle: return .holdOrToggle
            case .toggle: return .toggle
            case .hold: return .hold
            case .doubleTap: return .doubleTap
            }
        }
        set {
            var config = PTTHotkeyConfiguration.load(from: defaults)
            let mode: PTTActivationMode
            switch newValue {
            case .holdOrToggle: mode = .holdOrToggle
            case .toggle: mode = .toggle
            case .hold: mode = .hold
            case .doubleTap: mode = .doubleTap
            }
            config.activationMode = mode
            config.save(to: defaults)
            NotificationCenter.default.post(name: .pttHotkeyConfigurationDidChange, object: nil)
            ping()
        }
    }

    var hotkey: KeyChord? {
        get {
            let config = PTTHotkeyConfiguration.load(from: defaults)
            if let custom = config.customChord { return custom }
            guard config.keyCombination != .notSpecified else { return nil }
            guard let preset = HotkeyPreset.allCases.first(where: { $0.liveCombination == config.keyCombination }) else {
                return nil
            }
            return preset.makeChord()
        }
        set {
            var config = PTTHotkeyConfiguration.load(from: defaults)
            defer {
                config.save(to: defaults)
                NotificationCenter.default.post(name: .pttHotkeyConfigurationDidChange, object: nil)
                ping()
            }
            guard let chord = newValue else {
                config.keyCombination = .notSpecified
                config.customChord = nil
                return
            }
            if let preset = HotkeyPreset.preset(matching: chord) {
                config.keyCombination = preset.liveCombination ?? .notSpecified
                config.customChord = nil
            } else {
                config.keyCombination = .notSpecified
                config.customChord = chord
            }
        }
    }

    // MARK: - Cleanup (maps onto ModelsConfiguration.textCleanup)

    private var cleanup: TextCleanupConfiguration {
        ModelsConfiguration.load(from: defaults).textCleanup
    }

    var cleanupEnabled: Bool {
        get { cleanup.enabled }
        set { saveCleanup { $0.enabled = newValue } }
    }

    var removeFillers: Bool {
        get { cleanup.removeFillers }
        set { saveCleanup { $0.removeFillers = newValue } }
    }

    var handleBacktracks: Bool {
        get { cleanup.backtrack }
        set { saveCleanup { $0.backtrack = newValue } }
    }

    var formatLists: Bool {
        get { cleanup.listFormatting }
        set { saveCleanup { $0.listFormatting = newValue } }
    }

    var normalizePunctuation: Bool {
        get { cleanup.punctuation }
        set { saveCleanup { $0.punctuation = newValue } }
    }

    var grammarPass: GrammarPass {
        get {
            switch cleanup.grammarMode {
            case .off: return .off
            case .light: return .light
            case .full: return .full
            }
        }
        set {
            saveCleanup {
                switch newValue {
                case .off: $0.grammarMode = .off
                case .light: $0.grammarMode = .light
                case .full: $0.grammarMode = .full
                }
            }
        }
    }

    private func saveCleanup(_ mutate: (inout TextCleanupConfiguration) -> Void) {
        var config = ModelsConfiguration.load(from: defaults)
        mutate(&config.textCleanup)
        config.save(to: defaults)
        NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
        ping()
    }

    // MARK: - Dictionary

    var rules: [ReplacementRule] {
        get {
            DictionaryRuleMigration.runIfNeeded(manager: manager, defaults: defaults)
            return manager.entries.map { entry in
                ReplacementRule(
                    id: entry.id,
                    spoken: entry.trigger,
                    typed: entry.replacement,
                    mode: (entry.caseInsensitive || entry.preserveCase) ? .smart : .literal
                )
            }
        }
        set {
            manager.entries = newValue.map { rule in
                DictionaryEntry(
                    id: rule.id,
                    trigger: Self.normalizedRuleText(rule.spoken),
                    replacement: Self.normalizedRuleText(rule.typed),
                    isEnabled: true,
                    caseInsensitive: rule.mode == .smart,
                    preserveCase: rule.mode == .smart,
                    userAdded: true
                )
            }
            manager.entriesDidChange()
            ping()
        }
    }

    var dictionaryLoadFailureNotice: String? { manager.loadFailureNotice }

    /// Trim on save; max 128 scalars/side; strip newlines (impl contract).
    private static func normalizedRuleText(_ text: String) -> String {
        String(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(128)
        )
        .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Engine

    var modelFolder: URL {
        ModelsConfiguration.load(from: defaults).modelLibraryURL
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Kalam/models")
    }

    var engine: EnginePresence {
        let config = ModelsConfiguration.load(from: defaults)
        switch config.availability(for: config.asrVersion) {
        case .installed:
            return .verified(ModelInfo(name: Self.shortName(for: config.asrVersion), detail: config.asrVersion.description))
        case .modelLibraryNotConfigured, .missingModelFolder:
            return .missing
        case .invalidModelFolder:
            return .incomplete
        }
    }

    func chooseModelFolder() async -> URL? {
        let config = ModelsConfiguration.load(from: defaults)
        let url = await withCheckedContinuation { continuation in
            ModelSetupSupport.chooseModelLibraryFolder(currentURL: config.modelLibraryURL) { picked in
                continuation.resume(returning: picked)
            }
        }
        guard let url else { return nil } // cancel → silent (D.5d)
        do {
            let updated = try ModelSetupSupport.applyingModelLibraryFolder(url, to: config)
            updated.save(to: defaults)
            NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
            ping()
        } catch {
            // Keep silent UI-wise (same posture as the old Models tab); state stays as-is.
        }
        return url
    }

    func rescanEngine() {
        ping()
    }

    var installCommand: String {
        "cp ~/Downloads/Parakeet* \(modelFolder.path)/"
    }

    /// Short map title ("Parakeet v3") — the live displayName is too long for the card.
    private static func shortName(for version: ASRModelVersion) -> String {
        switch version {
        case .v2: return "Parakeet v2"
        case .v3: return "Parakeet v3"
        case .tdtCtc110m: return "Parakeet 110m"
        }
    }

    // MARK: - Meta

    var releaseURL: URL { KalamExternalLinks.latestReleaseURL }
}

// MARK: - One-time dictionary migration (user decision 2026-08-13)

enum DictionaryRuleMigration {
    static let flagKey = "dictionary.migratedToCompassRules"

    /// Compass has no per-rule enable toggle; existing disabled rules are re-enabled once,
    /// gated by a persisted flag (set even when nothing was disabled).
    @MainActor
    static func runIfNeeded(manager: CustomDictionaryManager, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        var changed = false
        manager.entries = manager.entries.map { entry in
            guard !entry.isEnabled else { return entry }
            changed = true
            var enabled = entry
            enabled.isEnabled = true
            return enabled
        }
        if changed {
            manager.saveImmediately()
        }
        defaults.set(true, forKey: flagKey)
    }
}
