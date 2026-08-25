import Foundation
import Observation

/// Status tone for map cards — mirrors onboarding status colors (F-07).
enum MapStateTone: Equatable {
    case ok, neutral, warn, bad
}

/// Façade over `SettingsBacking`. Map/dive read derived attention from here only.
@Observable
@MainActor
final class SettingsModel {
    private let store: any SettingsBacking

    /// Store-change revision counter (settings redesign reactivity fix, plan §4.1).
    /// Every computed property reads `revision`, so an external store change
    /// (notification, dictionary edit, mic hot-plug) invalidates SwiftUI views.
    /// Without this, @Observable never re-renders computed-only façades.
    private(set) var revision = 0

    @ObservationIgnored private var onChangeTask: Task<Void, Never>?

    init(store: any SettingsBacking) {
        self.store = store
        onChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in store.onChange {
                self.revision += 1
            }
        }
    }

    deinit {
        onChangeTask?.cancel()
    }

    // MARK: - Forwarded settings

    var launchAtLogin: Bool {
        get { _ = revision; return store.launchAtLogin }
        set { store.launchAtLogin = newValue }
    }

    var showInDock: Bool {
        get { _ = revision; return store.showInDock }
        set { store.showInDock = newValue }
    }

    var escapeCancels: Bool {
        get { _ = revision; return store.escapeCancels }
        set { store.escapeCancels = newValue }
    }

    var muteOtherAudio: Bool {
        get { _ = revision; return store.muteOtherAudio }
        set { store.muteOtherAudio = newValue }
    }

    var indicator: IndicatorPlacement {
        get { _ = revision; return store.indicator }
        set { store.indicator = newValue }
    }

    var indicatorStyle: IndicatorStyle {
        get { _ = revision; return store.indicatorStyle }
        set { store.indicatorStyle = newValue }
    }

    var microphones: [Microphone] { _ = revision; return store.microphones }

    var lastUsedID: String? {
        get { _ = revision; return store.lastUsedID }
        set { store.lastUsedID = newValue }
    }

    var microphonePermission: MicrophonePermission { _ = revision; return store.microphonePermission }

    var activation: ActivationMode {
        get { _ = revision; return store.activation }
        set { store.activation = newValue }
    }

    var hotkey: KeyChord? {
        get { _ = revision; return store.hotkey }
        set { store.hotkey = newValue }
    }

    var cleanupEnabled: Bool {
        get { _ = revision; return store.cleanupEnabled }
        set { store.cleanupEnabled = newValue }
    }

    var removeFillers: Bool {
        get { _ = revision; return store.removeFillers }
        set { store.removeFillers = newValue }
    }

    var handleBacktracks: Bool {
        get { _ = revision; return store.handleBacktracks }
        set { store.handleBacktracks = newValue }
    }

    var formatLists: Bool {
        get { _ = revision; return store.formatLists }
        set { store.formatLists = newValue }
    }

    var normalizePunctuation: Bool {
        get { _ = revision; return store.normalizePunctuation }
        set { store.normalizePunctuation = newValue }
    }

    var grammarPass: GrammarPass {
        get { _ = revision; return store.grammarPass }
        set { store.grammarPass = newValue }
    }

    var rules: [ReplacementRule] {
        get { _ = revision; return store.rules }
        set { store.rules = newValue }
    }

    var dictionaryLoadFailureNotice: String? { _ = revision; return store.dictionaryLoadFailureNotice }

    var modelFolder: URL { _ = revision; return store.modelFolder }
    var engine: EnginePresence { _ = revision; return store.engine }
    var installCommand: String { _ = revision; return store.installCommand }
    var releaseURL: URL { _ = revision; return store.releaseURL }

    var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    // MARK: - Derived mic

    /// First connected device in user order. Nil if permission denied or none connected.
    var connectedMicrophone: Microphone? {
        guard microphonePermission != .denied else { return nil }
        return microphones.first(where: \.isConnected)
    }

    func microphoneStatus(for mic: Microphone) -> String {
        if microphonePermission == .denied || !mic.isConnected {
            return "OFFLINE"
        }
        if let connected = connectedMicrophone, connected.id == mic.id {
            return "IN USE"
        }
        if lastUsedID == mic.id {
            return "LAST USED"
        }
        return "OFFLINE"
    }

    func moveMicrophone(from source: IndexSet, to destination: Int) {
        store.moveMicrophone(from: source, to: destination)
    }

    /// Step priority without drag previews (preferred UX — D.1 rank + up/down).
    func moveMicrophoneUp(id: String) {
        guard let i = microphones.firstIndex(where: { $0.id == id }), i > 0 else { return }
        store.moveMicrophone(from: IndexSet(integer: i), to: i - 1)
    }

    func moveMicrophoneDown(id: String) {
        guard let i = microphones.firstIndex(where: { $0.id == id }), i < microphones.count - 1 else { return }
        store.moveMicrophone(from: IndexSet(integer: i), to: i + 2)
    }

    func refreshMicrophones() { store.refreshMicrophones() }

    func chooseModelFolder() async {
        if let url = await store.chooseModelFolder() {
            _ = url
            store.rescanEngine()
        }
        // Cancel → silent (D.5d)
    }

    func rescanEngine() { store.rescanEngine() }

    // MARK: - Cleanup counts

    var cleanupRulesOnCount: Int {
        [removeFillers, handleBacktracks, formatLists, normalizePunctuation]
            .filter(\.self).count
    }

    var cleanupMapTitle: String {
        guard cleanupEnabled else { return "Off" }
        let g: String = {
            switch grammarPass {
            case .off: return "off"
            case .light: return "light"
            case .full: return "full"
            }
        }()
        if grammarPass == .off && cleanupRulesOnCount == 0 { return "Off" }
        return "\(cleanupRulesOnCount) rules, \(g)"
    }

    // MARK: - Map derivation (keep here, not in MapView)

    /// Single attention winner. Empty dictionary is span-attention only when nothing higher.
    var attention: Destination? {
        switch engine {
        case .verified: break
        case .missing, .incomplete: return .engine
        }
        if connectedMicrophone == nil { return .beingHeard }
        if hotkey == nil { return .trigger }
        if rules.isEmpty { return .dictionary }
        return nil
    }

    /// Always one span-2 card. Fill is not attention styling.
    var spanning: Destination { attention ?? .engine }

    var hero: MapHero {
        switch engine {
        case .verified: break
        case .missing, .incomplete: return .engineMissing
        }
        if connectedMicrophone == nil { return .noMicrophone }
        if hotkey == nil { return .keyUnset }
        return .ready
    }

    var mapNeedCTA: String? {
        guard let attention, attention != .dictionary else { return nil }
        return attention.needCTA
    }

    // MARK: - Map card strings (derive; never hardcode device names in views)

    func mapCardTitle(for dest: Destination) -> String {
        switch dest {
        case .beingHeard:
            return connectedMicrophone?.name ?? "No microphone"
        case .trigger:
            return hotkey?.displayVerbose ?? "No key"
        case .cleanup:
            return cleanupMapTitle
        case .dictionary:
            if rules.isEmpty { return "No rules yet" }
            return rules.count == 1 ? "1 rule" : "\(rules.count) rules"
        case .engine:
            switch engine {
            case .verified(let info): return info.name
            case .missing: return "No model found"
            case .incomplete: return "Incomplete"
            }
        case .updates:
            return "Updates"
        }
    }

    func mapCardState(for dest: Destination) -> (text: String, tone: MapStateTone) {
        switch dest {
        case .beingHeard:
            if microphonePermission == .denied { return ("Blocked", .bad) }
            return connectedMicrophone == nil ? ("Offline", .warn) : ("Ready", .ok)
        case .trigger:
            return hotkey == nil ? ("Unset", .warn) : ("Set", .ok)
        case .cleanup:
            return cleanupEnabled ? ("On", .ok) : ("Off", .neutral)
        case .dictionary:
            return rules.isEmpty ? ("Empty", .neutral) : ("Ready", .ok)
        case .engine:
            switch engine {
            case .verified: return ("Verified", .ok)
            case .missing: return ("Missing", .bad)
            case .incomplete: return ("Incomplete", .warn)
            }
        case .updates:
            return ("v\(versionString)", .ok)
        }
    }

    func mapCardDescription(for dest: Destination) -> String {
        let isLargeAttention = attention == dest
        let isWideFill = attention == nil && dest == .engine

        switch dest {
        case .beingHeard:
            if connectedMicrophone == nil {
                return "Nothing on the priority list is connected. Plug a mic in or Kalam cannot hear you."
            }
            return "Mic priority and behavior."
        case .trigger:
            if hotkey == nil {
                return "Choose a hotkey before Kalam can hold or tap to record."
            }
            return activation.mapDescription
        case .cleanup:
            return cleanupEnabled ? "Fillers, lists, and punctuation." : "Types the transcript as recognized."
        case .dictionary:
            if rules.isEmpty && isLargeAttention {
                return "Without rules, Kalam types exactly what it heard. Add replacements when you want spoken phrases rewritten."
            }
            if rules.isEmpty {
                return "Spoken phrases rewritten as you prefer."
            }
            return "Spoken phrases rewritten as you prefer."
        case .engine:
            switch engine {
            case .verified:
                return isWideFill
                    ? "Recognition runs on this Mac."
                    : "Runs on this Mac."
            case .missing:
                return isLargeAttention
                    ? "Put the five Parakeet files in ~/Kalam/models/ and Kalam will load them from disk."
                    : "No model found."
            case .incomplete:
                return isLargeAttention
                    ? "This folder has part of a model; add the rest of the Parakeet files so Kalam can load it from disk."
                    : "Incomplete."
            }
        case .updates:
            return "v\(versionString) · No auto-check"
        }
    }

    func contentsState(for dest: Destination) -> String {
        switch dest {
        case .beingHeard:
            return connectedMicrophone == nil ? "Offline" : "Ready"
        case .trigger:
            // Prefer a plain "Cmd" label in the narrow sidebar if ⌘ is awkward in mono;
            // keycaps still use displayCompact from the chord (⌘ on real macOS fonts).
            guard let hotkey else { return "Unset" }
            return hotkey.displayCompact
                .replacingOccurrences(of: "⌘", with: "Cmd")
                .replacingOccurrences(of: "⌥", with: "Opt")
                .replacingOccurrences(of: "⌃", with: "Ctrl")
                .replacingOccurrences(of: "⇧", with: "Shift")
        case .cleanup:
            return cleanupEnabled ? "\(cleanupRulesOnCount)/4" : "Off"
        case .dictionary:
            if rules.isEmpty { return "Empty" }
            return rules.count == 1 ? "1 rule" : "\(rules.count) rules"
        case .engine:
            switch engine {
            case .verified(let info):
                // Prefer short tail like "v3" when present.
                if let v = info.name.split(separator: " ").last { return String(v) }
                return info.name
            case .missing: return "Missing"
            case .incomplete: return "Incomplete"
            }
        case .updates:
            return "v\(versionString)"
        }
    }
}
