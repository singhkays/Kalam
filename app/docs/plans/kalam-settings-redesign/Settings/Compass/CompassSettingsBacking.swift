import Foundation

// MARK: - Live store boundary
// Compass owns no UserDefaults keys. Conform the existing app settings object to this protocol
// (or wrap it). Rename adapter methods to match live symbols — do not duplicate persistence.

@MainActor
protocol CompassSettingsBacking: AnyObject {
    // Behavior
    var launchAtLogin: Bool { get set }
    var showInDock: Bool { get set }
    var escapeCancels: Bool { get set }
    var muteOtherAudio: Bool { get set }
    var indicator: IndicatorPlacement { get set }

    // Microphones — ordered priority; IN USE is first connected, not blindly index 0
    var microphones: [Microphone] { get }
    var lastUsedID: String? { get set }
    var microphonePermission: MicrophonePermission { get }
    func moveMicrophone(from: IndexSet, to: Int)
    func refreshMicrophones()

    // Trigger
    var activation: ActivationMode { get set }
    var hotkey: KeyChord? { get set }

    // Cleanup (American: normalizePunctuation)
    var cleanupEnabled: Bool { get set }
    var removeFillers: Bool { get set }
    var handleBacktracks: Bool { get set }
    var formatLists: Bool { get set }
    var normalizePunctuation: Bool { get set }
    var grammarPass: GrammarPass { get set }

    // Dictionary — same store the recognizer reads
    var rules: [ReplacementRule] { get set }

    // Engine — scan via existing ModelFolderScanner; never list filenames in UI
    var modelFolder: URL { get }
    var engine: EnginePresence { get }
    func chooseModelFolder() async -> URL?
    func rescanEngine()
    var installCommand: String { get }

    // Meta
    var releaseURL: URL { get }
    var onChange: AsyncStream<Void> { get }
}

enum MicrophonePermission: Equatable {
    case granted
    case denied
    case notDetermined
}

enum IndicatorPlacement: String, CaseIterable, Codable, Sendable {
    case topLeft
    case topCenter
    case topRight

    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        }
    }

    /// Migrate legacy live-app values (bottoms / off) → topCenter.
    static func migrating(fromStored raw: String?) -> IndicatorPlacement {
        switch raw {
        case "topLeft", "Top Left", "top_left": return .topLeft
        case "topRight", "Top Right", "top_right": return .topRight
        case "topCenter", "Top Center", "top_center": return .topCenter
        default: return .topCenter
        }
    }
}

enum ActivationMode: String, CaseIterable, Codable, Sendable {
    case holdOrToggle
    case toggle
    case hold
    case doubleTap

    var title: String {
        switch self {
        case .holdOrToggle: "Hold or toggle"
        case .toggle: "Toggle"
        case .hold: "Hold"
        case .doubleTap: "Double tap"
        }
    }

    var detail: String {
        switch self {
        case .holdOrToggle: "Hold to talk and release to type, or tap once for a longer take."
        case .toggle: "Tap once to start, tap again to stop."
        case .hold: "Records only while the key is held down."
        case .doubleTap: "Double-tap to start, double-tap again to stop."
        }
    }

    var mapDescription: String {
        switch self {
        case .holdOrToggle: "Hold or toggle."
        case .toggle: "Toggle."
        case .hold: "Hold."
        case .doubleTap: "Double tap."
        }
    }
}

enum GrammarPass: String, CaseIterable, Codable, Sendable {
    case off, light, full

    var label: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .full: "Full"
        }
    }
}

enum MatchMode: String, Codable, Sendable {
    case smart
    case literal
}

enum KeySide: String, Codable, Sendable {
    case left, right, either
}


// MARK: - Hotkey presets (live app catalogue)

enum HotkeyPreset: String, CaseIterable, Identifiable, Sendable {
    case none
    case rightCmd, rightOpt, rightShift, rightCtrl
    case optCmd, ctrlCmd, ctrlOpt, shiftCmd, optShift, ctrlShift
    case fn
    /// Not a stored value — menu action that starts capture.
    case record

    var id: String { rawValue }

    var isMenuSeparatorBefore: Bool { self == .record }

    /// Items shown in the menu (includes record).
    static var menuItems: [HotkeyPreset] {
        allCases
    }

    var usesMonoLabel: Bool {
        switch self {
        case .none, .record, .fn: return false
        default: return true
        }
    }

    var menuLabel: String {
        switch self {
        case .none: return "Not specified"
        case .rightCmd: return "Right ⌘"
        case .rightOpt: return "Right ⌥"
        case .rightShift: return "Right ⇧"
        case .rightCtrl: return "Right ⌃"
        case .optCmd: return "⌥ + ⌘"
        case .ctrlCmd: return "⌃ + ⌘"
        case .ctrlOpt: return "⌃ + ⌥"
        case .shiftCmd: return "⇧ + ⌘"
        case .optShift: return "⌥ + ⇧"
        case .ctrlShift: return "⌃ + ⇧"
        case .fn: return "Fn"
        case .record: return "Record shortcut…"
        }
    }

    var mapVerbose: String? {
        switch self {
        case .none, .record: return nil
        case .rightCmd: return "Right Command"
        case .rightOpt: return "Right Option"
        case .rightShift: return "Right Shift"
        case .rightCtrl: return "Right Control"
        case .optCmd: return "Option + Command"
        case .ctrlCmd: return "Control + Command"
        case .ctrlOpt: return "Control + Option"
        case .shiftCmd: return "Shift + Command"
        case .optShift: return "Option + Shift"
        case .ctrlShift: return "Control + Shift"
        case .fn: return "Fn"
        }
    }

    /// Stored chord for fixed presets. nil for none/record.
    func makeChord() -> KeyChord? {
        guard let verbose = mapVerbose else { return nil }
        // keyCode/modifiers filled by live registrar when binding — display strings required now.
        return KeyChord(
            keyCode: 0,
            modifiersRaw: 0,
            side: (self == .rightCmd || self == .rightOpt || self == .rightShift || self == .rightCtrl) ? .right : .either,
            displayVerbose: verbose,
            displayCompact: menuLabel
        )
    }
}

struct KeyChord: Hashable, Codable, Sendable {
    var keyCode: UInt16
    var modifiersRaw: UInt
    var side: KeySide
    /// Map card title — e.g. "Right Command"
    var displayVerbose: String
    /// Keycap + contents — e.g. "Right ⌘"
    var displayCompact: String
}

struct Microphone: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isConnected: Bool
}

struct ReplacementRule: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var spoken: String
    var typed: String
    var mode: MatchMode

    init(id: UUID = UUID(), spoken: String, typed: String, mode: MatchMode = .smart) {
        self.id = id
        self.spoken = spoken
        self.typed = typed
        self.mode = mode
    }
}

struct ModelInfo: Hashable, Sendable {
    var name: String
    var detail: String
}

enum EnginePresence: Equatable, Sendable {
    case verified(ModelInfo)
    case missing
    case incomplete
}

enum DictionaryEditorPhase: Equatable {
    case browsing
    case adding
    case editing(UUID)
    case confirmingDelete(UUID)
}
