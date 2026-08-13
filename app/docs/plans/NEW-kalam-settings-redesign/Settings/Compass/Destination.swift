import Foundation

enum Destination: String, CaseIterable, Hashable, Identifiable {
    case beingHeard
    case trigger
    case cleanup
    case dictionary
    case engine
    case updates

    var id: String { rawValue }

    var isMaintenance: Bool { self == .updates }

    /// Journey destinations only (not Updates).
    static var journey: [Destination] {
        [.beingHeard, .trigger, .cleanup, .dictionary, .engine]
    }

    var number: String? {
        switch self {
        case .beingHeard: "01"
        case .trigger: "02"
        case .cleanup: "03"
        case .dictionary: "04"
        case .engine: "05"
        case .updates: nil
        }
    }

    /// Maintenance marker in contents.
    var contentsIndex: String {
        number ?? "¶"
    }

    var title: String {
        switch self {
        case .beingHeard: "Being heard"
        case .trigger: "The trigger"
        case .cleanup: "Cleanup"
        case .dictionary: "The dictionary"
        case .engine: "The engine"
        case .updates: "Updates"
        }
    }

    var subtitle: String {
        switch self {
        case .beingHeard: "Microphone · behavior"
        case .trigger: "Hotkey · modes"
        case .cleanup: "Filler · lists · grammar"
        case .dictionary: "Replacement rules"
        case .engine: "Recognition model"
        case .updates: "Version · release"
        }
    }

    /// Green map CTA when this destination is hero-attention. Nil for empty dictionary.
    var needCTA: String? {
        switch self {
        case .engine: "Open the engine →"
        case .beingHeard: "Open being heard →"
        case .trigger: "Open the trigger →"
        default: nil
        }
    }
}

enum MapHero: Equatable {
    case ready
    case engineMissing
    case noMicrophone
    case keyUnset

    /// Full display string (serif).
    var text: String {
        switch self {
        case .ready: "Everything is ready."
        case .engineMissing: "The engine needs a model."
        case .noMicrophone: "Nothing is listening."
        case .keyUnset: "No key is set."
        }
    }

    /// Substring rendered in italic (trailing emphasis).
    var italicSuffix: String {
        switch self {
        case .ready: "ready."
        case .engineMissing: "model."
        case .noMicrophone: "listening."
        case .keyUnset: "set."
        }
    }
}

enum PrivacyLine: String, CaseIterable, Sendable {
    case onDevice = "On-device"
    case wordsStayHome = "Your words stay home"
    case nothingLeaves = "Nothing leaves"
    case offTheGrid = "Off the grid"
    case noSignal = "No signal, no sweat"
    case yourPen = "Your pen, your page"
}
