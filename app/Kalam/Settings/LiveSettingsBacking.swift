import AppKit
import AVFoundation
import Combine
import Foundation
import KalamTextEngine

// MARK: - Settings UI → live app adapter (settings redesign)
//
// The ONLY live-store access for the settings UI. Persistence goes through the existing
// config structs and their existing notification posts — no new UserDefaults schema.
// `onChange` yields on every change source so SettingsModel's revision mechanism refreshes
// SwiftUI views (plan §4.1).

@MainActor
final class LiveSettingsBacking: SettingsBacking {
    private let manager: CustomDictionaryManager
    private let defaults: UserDefaults
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var dictionarySink: AnyCancellable?
    private var cachedMics: [Microphone] = []
    private let wakeExecutor: @Sendable (_ uid: String) async -> Bool
    private var wakingUIDs: Set<String> = []
    private var audioRefreshTask: Task<Void, Never>?

    /// `wakeExecutor` injection seam: unit tests stub the HFP-forcing capture so
    /// no CoreAudio work happens off-main during test runs.
    init(
        manager: CustomDictionaryManager = .shared,
        defaults: UserDefaults = .standard,
        wakeExecutor: @escaping @Sendable (_ uid: String) async -> Bool = {
            await BluetoothMicWaker.openMicStream(forUID: $0)
        }
    ) {
        self.wakeExecutor = wakeExecutor
        self.manager = manager
        self.defaults = defaults
        // The old settings shell seeded the dictionary on appear; the new shell owns it here
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
                    self?.clearDerivedCaches()
                    self?.ping()
                }
            )
        }
        // Audio topology changes must RE-ENUMERATE, not just ping: `microphones`
        // serves a cached one-shot CoreAudio enumeration, so a device connecting
        // while settings is open would otherwise show OFFLINE until the window
        // was closed and reopened. Posted by KalamApp's AudioDeviceMonitor path.
        notificationObservers.append(
            center.addObserver(forName: Notification.Name.audioDevicesDidChange, object: nil, queue: .main) { [weak self] _ in
                // Topology storms (diagnostic log showed ~10 rapid re-enumeration
                // events per device swap): coalesce into one trailing refresh.
                self?.scheduleAudioRefresh()
            }
        )
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

    var indicatorStyle: IndicatorStyle {
        get { GeneralSettingsConfiguration.load(from: defaults).indicatorStyle }
        set { saveGeneral { $0.indicatorStyle = newValue } }
    }

    var appearance: AppearancePreference {
        get { GeneralSettingsConfiguration.load(from: defaults).appearanceMode }
        set { saveGeneral { $0.appearanceMode = newValue } }
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
            Microphone(id: $0.uid, name: $0.name, isConnected: $0.isAvailable, isWakeable: $0.isWakeable)
        }
        ping()
    }

    /// Trailing-edge coalescing for `.audioDevicesDidChange`: each event alone
    /// triggers a full CoreAudio enumeration, and swap storms fire several in a
    /// row — waiting a beat merges them into one refresh (250 ms imperceptible).
    private func scheduleAudioRefresh() {
        audioRefreshTask?.cancel()
        audioRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshMicrophones()
        }
    }

    /// TAP TO WAKE (follow-up to the A2DP-idle diagnosis): opening a brief
    /// capture stream bound to the headset engages HFP; CoreAudio then posts
    /// device-change(s) which coalesce into a re-enumeration flipping the row
    /// to READY. The explicit trailing refresh covers HAL-listener lag.
    func wakeMicrophone(uid: String) {
        guard !wakingUIDs.contains(uid) else { return } // swallow rapid double taps
        wakingUIDs.insert(uid)
        Task { @MainActor [weak self] in
            _ = await self?.wakeExecutor(uid)
            self?.wakingUIDs.remove(uid)
            self?.refreshMicrophones()
        }
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

    // MARK: - Engine disk-scan memo (tap-lag fix, 2026-09-03)
    //
    // One availability scan costs ~1-2ms but runs dozens of times per render
    // pass (every `engine` / `installedModelVersions` / manifest read re-scans
    // disk with security-scoped access), totaling ~200ms of MainActor work per
    // picker tap. Memoize per (library path, version); disk truth re-enters
    // only via rescanEngine() (the Check-again affordance), folder change, or
    // a config-change notification — never implicitly. External changes (e.g.
    // a download finishing mid-session) surface on the next explicit rescan,
    // which is exactly what the UI promises ("Check again").

    private var enginePresenceCache: (path: String?, version: ASRModelVersion, value: EnginePresence)?
    private var installedVersionsCache: (path: String?, value: [ASRModelVersion])?
    private var manifestCache: [String: [ASRModelFileEntry]] = [:]
    // The loaded config itself: resolving the security-scoped bookmark on
    // every getter cost ~1ms × dozens of reads per render. Cached alongside
    // the scan memos; every mutation path below clears it after saving.
    private var cachedConfig: ModelsConfiguration?

    private func loadedConfig() -> ModelsConfiguration {
        if let c = cachedConfig { return c }
        let c = ModelsConfiguration.load(from: defaults)
        cachedConfig = c
        return c
    }

    private func clearDerivedCaches() {
        cachedConfig = nil
        enginePresenceCache = nil
        installedVersionsCache = nil
        manifestCache = [:]
    }

    // MARK: - Engine

    var modelFolder: URL {
        loadedConfig().modelLibraryURL
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Kalam/models")
    }

    var engine: EnginePresence {
        let config = loadedConfig()
        let path = config.modelLibraryURL?.path
        if let c = enginePresenceCache, c.path == path, c.version == config.asrVersion {
            return c.value
        }
        let value: EnginePresence
        switch config.availability(for: config.asrVersion) {
        case .installed:
            value = .verified(ModelInfo(name: Self.shortName(for: config.asrVersion), detail: config.asrVersion.description))
        case .modelLibraryNotConfigured, .missingModelFolder:
            value = .missing
        case .invalidModelFolder, .partial:
            value = .incomplete
        }
        enginePresenceCache = (path, config.asrVersion, value)
        return value
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
        clearDerivedCaches()
        ping()
    }

    var installCommand: String {
        // Design override (2026-08-28): Engine pane rebuilt to match onboarding
        // 3-step wizard; `cp` replaced with full `hf download` command per user
        // directive, overriding K-30 spec line 27 (`cp`-only lock). See
        // 2026-08-28-engine-pane-redesign-override.md.
        ModelSetupSupport.huggingFaceInstallCommand
    }

    /// Design override (2026-08-28): full `hf download` command (replaces `cp`).
    /// Bound through `ModelsConfiguration.asrVersion` and `modelLibraryURL`.
    var downloadCommand: String {
        let config = loadedConfig()
        return ModelSetupSupport.downloadCommand(for: config.asrVersion, config: config)
    }

    /// Step 3 model picker source — all `ASRModelVersion` cases.
    var availableModelVersions: [ASRModelVersion] {
        ASRModelVersion.allCases
    }

    /// Whether a given version is installed (live state from folder scan).
    /// Same predicate as `installedVersions` (`availability.isInstalled`), so
    /// it reads the memoized set instead of rescanning per call.
    func isModelVersionInstalled(_ version: ASRModelVersion) -> Bool {
        installedModelVersions.contains(version)
    }

    var installedModelVersions: [ASRModelVersion] {
        let config = loadedConfig()
        let path = config.modelLibraryURL?.path
        if let c = installedVersionsCache, c.path == path {
            return c.value
        }
        let value = config.installedVersions
        installedVersionsCache = (path, value)
        return value
    }

    var activeModelVersion: ASRModelVersion {
        get { loadedConfig().asrVersion }
        set {
            var c = ModelsConfiguration.load(from: defaults); c.asrVersion = newValue; c.save(to: defaults)
            clearDerivedCaches()
            NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
        }
    }

    /// The selected/download version — mapped from settings backing.
    /// In full build this would use a `@Binding` through the wizard; for the
    /// rebuilt EnginePane, this returns the current configured `asrVersion`.
    var selectedDownloadVersion: ASRModelVersion {
        get { loadedConfig().asrVersion }
        set {
            var config = ModelsConfiguration.load(from: defaults)
            config.asrVersion = newValue
            config.save(to: defaults)
            clearDerivedCaches()
            // No explicit ping: the post below reaches this store's own
            // observer synchronously on the same thread, which pings once —
            // one revision (one render) per tap instead of two.
            NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
        }
    }

    // MARK: - Retention (Task 6)

    var retentionEnabled: Bool {
        get { defaults.bool(forKey: "retention.enabled") }
        set {
            defaults.set(newValue, forKey: "retention.enabled")
            // No notification needed beyond ping — UI reads revision.
            ping()
        }
    }

    // MARK: - Engine wizard (Option D Setup)

    /// Step-2 tool-install attestation. Same load/save/notify pattern as
    /// `retention.enabled`. Machine-wide on purpose: `chooseModelFolder`
    /// never touches this key, so Change-folder re-activates Step 3 directly.
    var hasConfirmedHFCLIInstall: Bool {
        get { defaults.bool(forKey: "engine.hfCLIConfirmed") }
        set {
            defaults.set(newValue, forKey: "engine.hfCLIConfirmed")
            ping()
        }
    }

    var isModelLibraryConfigured: Bool {
        loadedConfig().modelLibraryURL != nil
    }

    var modelFolderExistsOnDisk: Bool {
        FileManager.default.fileExists(atPath: modelFolder.path)
    }

    /// Sourced ONLY from `ModelSetupSupport.modelFileManifest` (same file
    /// source as `AsrModels.modelsExist`) — never `requiredModelDirectoryNames`.
    func modelFileManifest(for version: ASRModelVersion) -> [ASRModelFileEntry] {
        let config = loadedConfig()
        let key = "\(config.modelLibraryURL?.path ?? "-")#\(version.rawValue)"
        if let hit = manifestCache[key] {
            return hit
        }
        let out = ModelSetupSupport.modelFileManifest(for: version, libraryURL: config.modelLibraryURL)
        manifestCache[key] = out
        return out
    }

    var engineFolderFreeBytes: Int64? {
        guard let values = try? modelFolder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        ) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        if let available = values.volumeAvailableCapacity { return Int64(available) }
        return nil
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
    // Key name is historical (pre-rename codename). Do NOT rename: it is persisted
    // in user defaults and renaming would re-run the one-time dictionary migration.
    static let flagKey = "dictionary.migratedToCompassRules"

    /// The settings UI has no per-rule enable toggle; existing disabled rules are re-enabled once,
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
