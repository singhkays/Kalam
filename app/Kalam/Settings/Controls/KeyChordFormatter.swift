import AppKit

/// Maps NSEvent → KeyChord (settings redesign: real formatter — the stub's placeholder tables are gone).
/// Accepts the registered bare modifiers and key chords over the live
/// allowlist. Letters, digits, and Space require a modifier.
/// Escape (53) is handled by the caller (cancel). Unstable keys return nil → reject flash.
enum KeyChordFormatter {
    static let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    /// The bare-modifier allowlist matches HotkeyListener's registration.
    static func bareModifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 60: return .shift
        default: return nil
        }
    }

    static func chord(from event: NSEvent) -> KeyChord? {
        let code = event.keyCode
        guard code != 53 else { return nil } // Escape — caller cancels capture
        let mods = event.modifierFlags.intersection(chordModifiers)

        if bareModifierFlag(for: code) != nil {
            return KeyChord(
                keyCode: code,
                modifiersRaw: mods.rawValue,
                side: side(for: code),
                displayVerbose: verboseName(for: code),
                displayCompact: compactName(for: code)
            )
        }

        guard let pttKey = PTTHotkeyKey.fromKeyCode(code) else { return nil }
        // Bare letters/digits/Space would swallow typing globally — require a modifier
        // unless the key is a function key (same rule as PTTHotkeyConfiguration.normalized()).
        guard !mods.isEmpty || pttKey.isFunctionKey else { return nil }

        let keyName: String
        if pttKey.isFunctionKey {
            keyName = pttKey.displayName
        } else if pttKey == .space {
            keyName = "Space"
        } else {
            keyName = event.charactersIgnoringModifiers?.uppercased() ?? pttKey.displayName
        }
        let symbolPrefix = symbolParts(mods).joined(separator: " + ")
        let wordPrefix = wordParts(mods).joined(separator: " + ")
        let compact = symbolPrefix.isEmpty ? keyName : "\(symbolPrefix) \(keyName)"
        let verbose = wordPrefix.isEmpty ? keyName : "\(wordPrefix) + \(keyName)"
        return KeyChord(
            keyCode: code,
            modifiersRaw: mods.rawValue,
            side: .either,
            displayVerbose: verbose,
            displayCompact: compact
        )
    }

    private static func side(for code: UInt16) -> KeySide {
        switch code {
        case 54, 61, 62, 60: return .right
        case 55, 58, 59, 56: return .left
        default: return .either
        }
    }

    private static func compactName(for code: UInt16) -> String {
        switch code {
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        default: return "Key \(code)"
        }
    }

    private static func verboseName(for code: UInt16) -> String {
        switch code {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 61: return "Right Option"
        case 58: return "Left Option"
        case 62: return "Right Control"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 56: return "Left Shift"
        default: return "Key \(code)"
        }
    }

    /// Modifier symbols in the mockup's catalogue order (⌃ ⌥ ⇧ ⌘).
    private static func symbolParts(_ mods: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        return parts
    }

    private static func wordParts(_ mods: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("Control") }
        if mods.contains(.option) { parts.append("Option") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.command) { parts.append("Command") }
        return parts
    }
}

/// Interprets the same event sequence for Settings and onboarding.
struct ShortcutCapture {
    enum Result: Equatable {
        case waiting
        case reject
        case cancel
        case commit(KeyChord)
    }

    static let eventMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]

    private var finished = false
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var pendingModifier: KeyChord?

    mutating func handle(_ event: NSEvent) -> Result {
        guard !finished else { return .waiting }
        if event.type == .flagsChanged { return handleModifierChange(event) }
        guard event.type == .keyDown else { return .waiting }
        pendingModifier = nil
        if event.keyCode == 53 {
            finished = true
            return .cancel
        }
        if let chord = KeyChordFormatter.chord(from: event) {
            finished = true
            return .commit(chord)
        }
        return .reject
    }

    private mutating func handleModifierChange(_ event: NSEvent) -> Result {
        let previous = heldModifiers
        heldModifiers = event.modifierFlags.intersection(KeyChordFormatter.chordModifiers)
        let candidate = pendingModifier
        pendingModifier = nil

        guard let flag = KeyChordFormatter.bareModifierFlag(for: event.keyCode) else {
            return .reject
        }
        if let candidate, candidate.keyCode == event.keyCode, heldModifiers.isEmpty {
            finished = true
            return .commit(candidate)
        }

        // Use the press event for the modifier mask and side. A keyDown or
        // another modifier change invalidates this lone-modifier candidate.
        if previous.isEmpty, heldModifiers == flag {
            pendingModifier = KeyChordFormatter.chord(from: event)
        }
        return .waiting
    }

}
