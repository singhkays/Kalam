import AppKit
import Foundation
import SwiftUI

// MARK: - Live store boundary
// The settings UI owns no UserDefaults keys. Conform the existing app settings object to this protocol
// (or wrap it). Rename adapter methods to match live symbols — do not duplicate persistence.

@MainActor
protocol SettingsBacking: AnyObject {
    // Behavior
    var launchAtLogin: Bool { get set }
    var showInDock: Bool { get set }
    var escapeCancels: Bool { get set }
    var muteOtherAudio: Bool { get set }
    var indicator: IndicatorPlacement { get set }
    var indicatorStyle: IndicatorStyle { get set }
    var appearance: AppearancePreference { get set }

    // Microphones — ordered priority; IN USE is first connected, not blindly index 0
    var microphones: [Microphone] { get }
    var lastUsedID: String? { get set }
    var microphonePermission: MicrophonePermission { get }
    func moveMicrophone(from: IndexSet, to: Int)
    func refreshMicrophones()
    /// Forces HFP/mic-stream activation for an idle Bluetooth headset that is
    /// physically connected but exposes no input stream yet (`isWakeable` rows).
    /// No-op for absent devices or stores without wake support.
    func wakeMicrophone(uid: String)

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
    /// dictionary data-loss edge cases corrupt-store notice (quiet ink-3 line in the dictionary pane). Nil = store healthy.
    var dictionaryLoadFailureNotice: String? { get }

    // Engine — scan via existing ModelFolderScanner; never list filenames in UI
    var modelFolder: URL { get }
    var engine: EnginePresence { get }
    func chooseModelFolder() async -> URL?
    func rescanEngine()
    var installCommand: String { get }
    var downloadCommand: String { get }
    var selectedDownloadVersion: ASRModelVersion { get set }
    var availableModelVersions: [ASRModelVersion] { get }
    func isModelVersionInstalled(_ version: ASRModelVersion) -> Bool
    var installedModelVersions: [ASRModelVersion] { get }
    var activeModelVersion: ASRModelVersion { get set }

    // Engine wizard (Option D Setup) — Step-2 tool-install attestation + routing primitives
    /// Persisted Step-2 attestation ("I've installed the tool"). Machine-wide:
    /// choosing a different model folder must not reset it.
    var hasConfirmedHFCLIInstall: Bool { get set }
    /// Whether a model-library bookmark is stored (resolves to a URL).
    /// False on first run and when a stale bookmark was unresolvable.
    var isModelLibraryConfigured: Bool { get }
    /// Whether `modelFolder` exists on disk right now (FileManager-backed live).
    var modelFolderExistsOnDisk: Bool { get }
    /// Per-file present/missing entries for a version (same source as the
    /// validator — never `requiredModelDirectoryNames`).
    func modelFileManifest(for version: ASRModelVersion) -> [ASRModelFileEntry]
    /// Free bytes on the model folder's volume, nil when unknown.
    var engineFolderFreeBytes: Int64? { get }

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
    case topCenter
    case bottomCenter

    var label: String {
        switch self {
        case .topCenter: "Top center"
        case .bottomCenter: "Bottom center"
        }
    }

    /// Migrate stored values: removed side placements → topCenter,
    /// legacy bottom presets → bottomCenter, anything else → topCenter.
    static func migrating(fromStored raw: String?) -> IndicatorPlacement {
        switch raw {
        case "bottomCenter", "Bottom Center", "bottom_center": return .bottomCenter
        case "topLeft", "Top Left", "top_left",
             "topRight", "Top Right", "top_right",
             "topCenter", "Top Center", "top_center": return .topCenter
        default: return .topCenter
        }
    }
}

enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static func migrating(fromStored raw: String?) -> AppearancePreference {
        switch raw {
        case "light": return .light
        case "dark": return .dark
        default: return .system
        }
    }

    /// Nil = no override, the OS appearance shows through.
    var overrideScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
        case .none, .record: return false
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
        }
    }

    /// Plain-word spelling shown beside glyph-only combo rows in the preset
    /// menu (hotkey onboarding card UX seventh round): first-run users may not read modifier
    /// glyphs yet, and onboarding is where they learn them. Single-key rows
    /// already say "Right …"; None/Record carry no glyphs.
    var plainNameHint: String? {
        switch self {
        case .optCmd: return "Option Command"
        case .ctrlCmd: return "Control Command"
        case .ctrlOpt: return "Control Option"
        case .shiftCmd: return "Shift Command"
        case .optShift: return "Option Shift"
        case .ctrlShift: return "Control Shift"
        default: return nil
        }
    }

    /// Live app catalogue mapping — the preset this row stores in `pttHotkey.keyCombination`.
    var liveCombination: KeyCombination? {
        switch self {
        case .none, .record: return nil
        case .rightCmd: return .rightCommand
        case .rightOpt: return .rightOption
        case .rightShift: return .rightShift
        case .rightCtrl: return .rightControl
        case .optCmd: return .optionCommand
        case .ctrlCmd: return .controlCommand
        case .ctrlOpt: return .controlOption
        case .shiftCmd: return .shiftCommand
        case .optShift: return .optionShift
        case .ctrlShift: return .controlShift
        }
    }

    /// Stored chord for fixed presets — real keyCode/modifiers via the live `KeyCombination`
    /// mapping (settings redesign: the original stub left keyCode/modifiers zeroed; that must never persist).
    func makeChord() -> KeyChord? {
        guard let combo = liveCombination else { return nil }
        let mapping = combo.keyMapping
        var flags: NSEvent.ModifierFlags = []
        if mapping.command { flags.insert(.command) }
        if mapping.shift { flags.insert(.shift) }
        if mapping.option { flags.insert(.option) }
        if mapping.control { flags.insert(.control) }
        let isRightSide = self == .rightCmd || self == .rightOpt || self == .rightShift || self == .rightCtrl
        return KeyChord(
            keyCode: mapping.key.keyCode,
            modifiersRaw: flags.rawValue,
            side: isRightSide ? .right : .either,
            displayVerbose: mapVerbose ?? menuLabel,
            displayCompact: menuLabel
        )
    }

    /// The preset whose stored chord equals `chord` (used by the adapter to route
    /// preset-equivalent chords back into the preset storage path).
    static func preset(matching chord: KeyChord) -> HotkeyPreset? {
        allCases.first { $0 != .none && $0 != .record && $0.makeChord() == chord }
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
    /// Hardware object is present but macOS hasn't opened its input stream yet
    /// (Bluetooth headset parked in A2DP). Rendered "TAP TO WAKE"; tapping asks
    /// the store to engage the mic-side (HFP) profile.
    var isWakeable: Bool = false
    /// Privacy-safe transport bucket ("builtin"/"usb"/"bluetooth"/"unknown") —
    /// surfaced in the support bundle without device names or UIDs.
    var transportTag: String = "unknown"
    /// Live input channel count (0 when offline). Count only, no identifiers.
    var inputChannels: UInt32 = 0
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
