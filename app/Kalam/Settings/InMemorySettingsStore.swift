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
        ModelInfo(name: "Parakeet v3", detail: "25+ languages · on this Mac")
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

    /// Full `hf download` command — rebuilt per user directive.
    var downloadCommand: String {
        let config = ModelsConfiguration.load(from: UserDefaults.standard)
        // Use stored bookmark to resolve library URL, falling back to folder path
        let libURL = config.modelLibraryURL ?? modelFolder
        var updatedConfig = config
        // If we have a folder selected, use it; otherwise use current modelFolder
        if modelFolder != libURL && libURL == nil {
            // No bookmark resolved; create a temporary bookmark for the folder path
            // (production: this uses security-scoped bookmark; preview uses path directly)
        }
        return ModelSetupSupport.downloadCommand(for: .v2, config: config)
    }

    var selectedDownloadVersion: ASRModelVersion {
        get { .v2 }
        set { }
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
    func applyModelFolderForTesting(_ url: URL, presence: EnginePresence) {
        modelFolder = url
        engine = presence
        ping()
    }
}
