import Foundation

/// Preview / fixture store. Production binds the live app settings object instead.
/// Contract (mirrors LiveSettingsBacking): every mutation pings `onChange`.
@MainActor
final class InMemorySettingsStore: SettingsBacking {
    var launchAtLogin: Bool = true { didSet { ping() } }
    var showInDock: Bool = false { didSet { ping() } }
    var escapeCancels: Bool = true { didSet { ping() } }
    var muteOtherAudio: Bool = true { didSet { ping() } }
    var indicator: IndicatorPlacement = .topCenter { didSet { ping() } }
    var indicatorStyle: IndicatorStyle = .machined { didSet { ping() } }
    var appearance: AppearancePreference = .system { didSet { ping() } }

    var dictionaryLoadFailureNotice: String? { nil }

    var microphones: [Microphone] = [
        .init(id: "cam", name: "HD Pro Webcam C920", isConnected: true),
        .init(id: "mbp", name: "MacBook Pro Microphone", isConnected: true),
        .init(id: "usb", name: "USB audio CODEC", isConnected: false),
    ] { didSet { ping() } }
    var lastUsedID: String? = "mbp" { didSet { ping() } }
    var microphonePermission: MicrophonePermission = .granted { didSet { ping() } }

    var activation: ActivationMode = .holdOrToggle { didSet { ping() } }
    var hotkey: KeyChord? = KeyChord(
        keyCode: 54,
        modifiersRaw: 0,
        side: .right,
        displayVerbose: "Right Command",
        displayCompact: "Right ⌘"
    ) { didSet { ping() } }

    var cleanupEnabled: Bool = true { didSet { ping() } }
    var removeFillers: Bool = true { didSet { ping() } }
    var handleBacktracks: Bool = false { didSet { ping() } }
    var formatLists: Bool = true { didSet { ping() } }
    var normalizePunctuation: Bool = true { didSet { ping() } }
    var grammarPass: GrammarPass = .light { didSet { ping() } }

    var rules: [ReplacementRule] = [] { didSet { ping() } }
    var retentionEnabled: Bool = false { didSet { ping() } }

    // MARK: - Engine wizard (Option D Setup) mirrors

    var hasConfirmedHFCLIInstall: Bool = false { didSet { ping() } }
    var isModelLibraryConfigured: Bool = false { didSet { ping() } }
    var modelFolderExistsOnDisk: Bool = true { didSet { ping() } }
    var engineFolderFreeBytes: Int64? = nil { didSet { ping() } }

    private var _manifests: [ASRModelVersion: [ASRModelFileEntry]] = [:]

    func modelFileManifest(for version: ASRModelVersion) -> [ASRModelFileEntry] {
        _manifests[version] ?? []
    }

    /// Test setter: explicit per-file entries for a version.
    func testSetManifest(_ entries: [ASRModelFileEntry], for version: ASRModelVersion) {
        _manifests[version] = entries
        ping()
    }

    /// Test setter: builds entries from the same `requiredModelFiles` source
    /// the live manifest uses — first `presentCount` files present.
    func testSetManifest(presentCount: Int, totalFor version: ASRModelVersion) {
        let names = ModelSetupSupport.requiredModelFiles(for: version)
        testSetManifest(
            names.enumerated().map { ASRModelFileEntry(name: $0.element, isPresent: $0.offset < presentCount) },
            for: version
        )
    }

    /// Test setter: flip engine presence without touching the folder (mimics
    /// the live picker coupling, where writing `asrVersion` flips engine).
    func testSetEnginePresence(_ presence: EnginePresence) {
        engine = presence
        ping()
    }

    private var _installed: [ASRModelVersion] = []
    var installedModelVersions: [ASRModelVersion] { _installed }
    var activeModelVersion: ASRModelVersion = .v2 { didSet { ping() } }

    func testSetInstalledVersions(_ versions: [ASRModelVersion]) {
        _installed = versions
        activeModelVersion = versions.first ?? .v2
        ping()
    }

    private(set) var modelFolder: URL
    private(set) var engine: EnginePresence = .verified(
        ModelInfo(name: "Parakeet v3", detail: "25 European languages · on this Mac")
    )

    var releaseURL: URL = URL(string: "https://example.com/kalam/releases")!

    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    var onChange: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    init(folder: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Kalam/models")) {
        self.modelFolder = folder
    }

    func moveMicrophone(from source: IndexSet, to destination: Int) {
        microphones.move(fromOffsets: source, toOffset: destination)
        ping()
    }

    func refreshMicrophones() {
        // Live store would query AVCaptureDevice / Core Audio.
        ping()
    }

    func wakeMicrophone(uid: String) {
        // Preview fixture: simulate macOS engaging the HFP profile after a tap.
        microphones = microphones.map { mic in
            guard mic.id == uid, mic.isWakeable else { return mic }
            var woken = mic
            woken.isWakeable = false
            woken.isConnected = true
            return woken
        }
        ping()
    }

    func chooseModelFolder() async -> URL? {
        // Live: NSOpenPanel + security-scoped bookmark.
        nil
    }

    func rescanEngine() {
        // Live: ModelFolderScanner.scan(at: modelFolder)
        ping()
    }

    var installCommand: String {
        // Design override (2026-08-28): rebuilt EnginePane with 3-step wizard.
        // `brew install hf` is shown in wizard Step 2; `installCommand` preserved
        // for backward compatibility.
        ModelSetupSupport.huggingFaceInstallCommand
    }

    private var _selectedDownloadVersion: ASRModelVersion = .v2

    /// Full `hf download` command — rebuilt per user directive.
    /// InMemory preview uses the selected version so the picker → command binding is observable.
    var downloadCommand: String {
        let config = ModelsConfiguration.load(from: UserDefaults.standard)
        return ModelSetupSupport.downloadCommand(for: _selectedDownloadVersion, config: config)
    }

    var selectedDownloadVersion: ASRModelVersion {
        get { _selectedDownloadVersion }
        set {
            guard newValue != _selectedDownloadVersion else { return }
            _selectedDownloadVersion = newValue
            ping()
        }
    }

    var availableModelVersions: [ASRModelVersion] {
        ASRModelVersion.allCases
    }

    func isModelVersionInstalled(_ version: ASRModelVersion) -> Bool {
        _installed.contains(version)
    }

    // MARK: Fixtures

    static func fixtureDefaultEmptyDictionary() -> InMemorySettingsStore {
        let s = InMemorySettingsStore()
        s.rules = []
        return s
    }

    static func fixtureSettled() -> InMemorySettingsStore {
        let s = InMemorySettingsStore()
        s.rules = [
            .init(spoken: "siobhan", typed: "Siobhan", mode: .smart),
            .init(spoken: "worcester", typed: "Worcester", mode: .smart),
            .init(spoken: "one on one", typed: "1:1", mode: .literal),
        ]
        return s
    }

    static func fixtureEngineMissing() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.engine = .missing
        return s
    }

    static func fixtureEngineIncomplete() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.engine = .incomplete
        return s
    }

    static func fixtureEngineMultiple() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.engine = .verified(ModelInfo(name: "Parakeet v2", detail: "English-only \u{00B7} 5 of 5"))
        s.testSetInstalledVersions([.v2, .v3])
        return s
    }

    static func fixtureEngineMultipleIncomplete() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.engine = .incomplete
        s.testSetInstalledVersions([.v2, .v3])
        return s
    }

    static func fixtureNoDevices() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.microphones = []
        s.microphonePermission = .granted
        return s
    }

    static func fixturePermissionDenied() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.microphonePermission = .denied
        s.microphones = []
        return s
    }

    static func fixtureKeyUnset() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.hotkey = nil
        return s
    }

    static func fixtureCleanupOff() -> InMemorySettingsStore {
        let s = fixtureSettled()
        s.cleanupEnabled = false
        return s
    }

    private func ping() {
        for c in continuations.values { c.yield(()) }
    }

    /// Test helper: apply a chosen folder and mark presence.
    /// Choosing a folder stores the bookmark (configured) and the folder
    /// exists; it never touches the machine-wide tool attestation.
    func applyModelFolderForTesting(_ url: URL, presence: EnginePresence) {
        modelFolder = url
        engine = presence
        isModelLibraryConfigured = true
        modelFolderExistsOnDisk = true
        ping()
    }

    // MARK: - Option D wizard fixtures (7 D states)

    /// D-Missing: first run — no bookmark, tool unconfirmed.
    static func fixtureSetupMissingDefault() -> InMemorySettingsStore {
        let s = InMemorySettingsStore()
        s.testSetEnginePresence(.missing)
        return s
    }

    /// D-Step 2: folder chosen (complete) but tool not yet confirmed.
    static func fixtureSetupFolderChosen() -> InMemorySettingsStore {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Models"),
            presence: .missing
        )
        return s
    }

    /// D-Incomplete: folder complete + tool confirmed, partial download (3 of 5).
    static func fixtureSetupIncomplete() -> InMemorySettingsStore {
        let s = fixtureSetupFolderChosen()
        s.hasConfirmedHFCLIInstall = true
        s.testSetInstalledVersions([.v2])
        s.testSetEnginePresence(.incomplete)
        s.testSetManifest(presentCount: 3, totalFor: .v2)
        return s
    }

    /// D-Verified single: one model on disk, wizard collapses.
    static func fixtureSetupVerifiedSingle() -> InMemorySettingsStore {
        let s = fixtureSetupFolderChosen()
        s.hasConfirmedHFCLIInstall = true
        s.testSetInstalledVersions([.v2])
        s.testSetEnginePresence(.verified(ModelInfo(name: "Parakeet v2", detail: "English-only · 5 of 5")))
        s.testSetManifest(presentCount: 5, totalFor: .v2)
        return s
    }

    /// D-Verified multi: two models on disk, wizard collapses.
    static func fixtureSetupVerifiedMulti() -> InMemorySettingsStore {
        let s = fixtureSetupVerifiedSingle()
        s.testSetInstalledVersions([.v2, .v3])
        return s
    }

    /// D-Folder-deleted: bookmark stored but path gone; tool stays confirmed.
    static func fixtureSetupFolderDeleted() -> InMemorySettingsStore {
        let s = fixtureSetupFolderChosen()
        s.hasConfirmedHFCLIInstall = true
        s.modelFolderExistsOnDisk = false
        return s
    }

    /// D-Repo-guard: the repo folder itself was picked (not its parent).
    static func fixtureSetupRepoGuard() -> InMemorySettingsStore {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Models")
                .appendingPathComponent(ASRModelVersion.v2.repositoryFolderName),
            presence: .missing
        )
        return s
    }
}
