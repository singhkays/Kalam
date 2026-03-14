import Foundation
import AppKit
import HotKey

// MARK: - Activation Mode

enum ActivationMode: String, CaseIterable, Identifiable {
    case holdOrToggle = "holdOrToggle"
    case toggle = "toggle"
    case hold = "hold"
    case doubleTap = "doubleTap"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .holdOrToggle: return "Hold or Toggle"
        case .toggle: return "Toggle"
        case .hold: return "Hold"
        case .doubleTap: return "Double Tap"
        }
    }
}

// MARK: - Key Combination

enum KeyCombination: String, CaseIterable, Identifiable {
    // Right modifiers (most common PTT keys)
    case rightCommand = "rightCommand"
    case rightOption = "rightOption"
    case rightShift = "rightShift"
    case rightControl = "rightControl"
    
    // Modifier combinations
    case optionCommand = "optionCommand"
    case controlCommand = "controlCommand"
    case controlOption = "controlOption"
    case shiftCommand = "shiftCommand"
    case optionShift = "optionShift"
    case controlShift = "controlShift"
    
    // Special
    case fn = "fn"
    case notSpecified = "notSpecified"
    
    var id: String { rawValue }

    var modifierOnlyFlags: NSEvent.ModifierFlags? {
        switch self {
        case .rightCommand:
            return [.command]
        case .rightOption:
            return [.option]
        case .rightShift:
            return [.shift]
        case .rightControl:
            return [.control]
        case .optionCommand:
            return [.option, .command]
        case .controlCommand:
            return [.control, .command]
        case .controlOption:
            return [.control, .option]
        case .shiftCommand:
            return [.shift, .command]
        case .optionShift:
            return [.option, .shift]
        case .controlShift:
            return [.control, .shift]
        case .fn:
            return [.function]
        case .notSpecified:
            return nil
        }
    }
    
    var displayName: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightShift: return "Right ⇧"
        case .rightControl: return "Right ⌃"
        case .optionCommand: return "⌥ + ⌘"
        case .controlCommand: return "⌃ + ⌘"
        case .controlOption: return "⌃ + ⌥"
        case .shiftCommand: return "⇧ + ⌘"
        case .optionShift: return "⌥ + ⇧"
        case .controlShift: return "⌃ + ⇧"
        case .fn: return "Fn"
        case .notSpecified: return "Not specified"
        }
    }
    
    /// Maps to the legacy PTTHotkeyKey and modifiers
    var keyMapping: (key: PTTHotkeyKey, command: Bool, shift: Bool, option: Bool, control: Bool) {
        switch self {
        case .rightCommand:
            return (.d, true, false, false, false)
        case .rightOption:
            return (.space, false, false, true, false)
        case .rightShift:
            return (.space, false, true, false, false)
        case .rightControl:
            return (.space, false, false, false, true)
        case .optionCommand:
            return (.d, true, false, true, false)
        case .controlCommand:
            return (.d, true, false, false, true)
        case .shiftCommand:
            return (.d, true, true, false, false)
        case .controlOption:
            return (.space, false, false, true, true)
        case .optionShift:
            return (.space, false, true, true, false)
        case .controlShift:
            return (.space, false, true, false, true)
        case .fn:
            return (.f12, false, false, false, false)
        case .notSpecified:
            return (.d, true, true, false, false)
        }
    }
    
    /// Creates a KeyCombination from legacy configuration
    static func from(key: PTTHotkeyKey, command: Bool, shift: Bool, option: Bool, control: Bool) -> KeyCombination {
        if key == .f12 && !command && !shift && !option && !control {
            return .fn
        }

        // Check for specific combinations
        if key == .space && control && option && !command && !shift {
            return .controlOption
        }
        if key == .space && control && shift && !command && !option {
            return .controlShift
        }
        if key == .space && option && shift && !command && !control {
            return .optionShift
        }
        if key == .d && shift && command && !option && !control {
            return .shiftCommand
        }
        if key == .d && control && command && !option && !shift {
            return .controlCommand
        }
        if key == .d && option && command && !shift && !control {
            return .optionCommand
        }
        
        // Check for right-side modifiers (we can't detect left vs right, so use heuristics)
        if key == .d && command && !shift && !option && !control {
            return .rightCommand
        }
        if key == .space && option && !command && !shift && !control {
            return .rightOption
        }
        if key == .space && shift && !command && !option && !control {
            return .rightShift
        }
        if key == .space && control && !command && !option && !shift {
            return .rightControl
        }
        
        return .notSpecified
    }
}

// MARK: - Legacy Key Enum (kept for backward compatibility)

enum PTTHotkeyKey: String, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero = "0"
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case five = "5"
    case six = "6"
    case seven = "7"
    case eight = "8"
    case nine = "9"
    case space
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .space:
            return "Space"
        default:
            return rawValue.uppercased()
        }
    }

    var hotKeyValue: Key {
        switch self {
        case .a: return .a
        case .b: return .b
        case .c: return .c
        case .d: return .d
        case .e: return .e
        case .f: return .f
        case .g: return .g
        case .h: return .h
        case .i: return .i
        case .j: return .j
        case .k: return .k
        case .l: return .l
        case .m: return .m
        case .n: return .n
        case .o: return .o
        case .p: return .p
        case .q: return .q
        case .r: return .r
        case .s: return .s
        case .t: return .t
        case .u: return .u
        case .v: return .v
        case .w: return .w
        case .x: return .x
        case .y: return .y
        case .z: return .z
        case .zero: return .zero
        case .one: return .one
        case .two: return .two
        case .three: return .three
        case .four: return .four
        case .five: return .five
        case .six: return .six
        case .seven: return .seven
        case .eight: return .eight
        case .nine: return .nine
        case .space: return .space
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .f6: return .f6
        case .f7: return .f7
        case .f8: return .f8
        case .f9: return .f9
        case .f10: return .f10
        case .f11: return .f11
        case .f12: return .f12
        }
    }

    var isFunctionKey: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return true
        default:
            return false
        }
    }

    static func fromKeyCode(_ keyCode: UInt16) -> PTTHotkeyKey? {
        switch keyCode {
        case 0: return .a
        case 11: return .b
        case 8: return .c
        case 2: return .d
        case 14: return .e
        case 3: return .f
        case 5: return .g
        case 4: return .h
        case 34: return .i
        case 38: return .j
        case 40: return .k
        case 37: return .l
        case 46: return .m
        case 45: return .n
        case 31: return .o
        case 35: return .p
        case 12: return .q
        case 15: return .r
        case 1: return .s
        case 17: return .t
        case 32: return .u
        case 9: return .v
        case 13: return .w
        case 7: return .x
        case 16: return .y
        case 6: return .z
        case 29: return .zero
        case 18: return .one
        case 19: return .two
        case 20: return .three
        case 21: return .four
        case 23: return .five
        case 22: return .six
        case 26: return .seven
        case 28: return .eight
        case 25: return .nine
        case 49: return .space
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        default: return nil
        }
    }
}

// MARK: - Configuration

struct PTTHotkeyConfiguration: Equatable {
    static let defaults = PTTHotkeyConfiguration(
        activationMode: .holdOrToggle,
        keyCombination: .shiftCommand,
        key: .d,
        command: true,
        shift: true,
        option: false,
        control: false
    )

    var activationMode: ActivationMode
    var keyCombination: KeyCombination
    
    // Legacy properties (kept for backward compatibility)
    var key: PTTHotkeyKey
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    private static let userDefaultsKeyKey = "pttHotkey.key"
    private static let userDefaultsModifiersKey = "pttHotkey.modifiers"
    private static let userDefaultsActivationModeKey = "pttHotkey.activationMode"
    private static let userDefaultsKeyCombinationKey = "pttHotkey.keyCombination"

    var hasAnyModifier: Bool {
        command || shift || option || control
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var resolvedHotkey: (key: PTTHotkeyKey, modifiers: NSEvent.ModifierFlags) {
        let safe = normalized()
        return (safe.key, safe.modifierFlags)
    }

    func normalized() -> PTTHotkeyConfiguration {
        var resolved = self

        if resolved.keyCombination != .notSpecified {
            let mapping = resolved.keyCombination.keyMapping
            resolved.key = mapping.key
            resolved.command = mapping.command
            resolved.shift = mapping.shift
            resolved.option = mapping.option
            resolved.control = mapping.control
        }

        // HotKey supports plain function keys. For non-function keys require at least one modifier.
        let allowsNoModifier = resolved.key.isFunctionKey
        guard resolved.hasAnyModifier || allowsNoModifier else {
            var fallback = resolved
            fallback.command = true
            return fallback
        }
        return resolved
    }

    mutating func apply(keyCombination: KeyCombination) {
        self.keyCombination = keyCombination
        if keyCombination != .notSpecified {
            let mapping = keyCombination.keyMapping
            key = mapping.key
            command = mapping.command
            shift = mapping.shift
            option = mapping.option
            control = mapping.control
        }
    }

    var displayString: String {
        if keyCombination != .notSpecified {
            return keyCombination.displayName
        }
        
        let c = normalized()
        var parts: [String] = []
        if c.control { parts.append("^") }
        if c.option { parts.append("⌥") }
        if c.shift { parts.append("⇧") }
        if c.command { parts.append("⌘") }
        parts.append(c.key.displayName)
        return parts.joined(separator: " ")
    }

    static func load(from defaults: UserDefaults = .standard) -> PTTHotkeyConfiguration {
        // Load activation mode
        let activationModeRaw = defaults.string(forKey: userDefaultsActivationModeKey)
        let activationMode = activationModeRaw.flatMap(ActivationMode.init(rawValue:)) ?? Self.defaults.activationMode
        
        // Load key combination
        let keyComboRaw = defaults.string(forKey: userDefaultsKeyCombinationKey)
        let keyCombo = keyComboRaw.flatMap(KeyCombination.init(rawValue:))
        
        // Load legacy key
        let keyRaw = defaults.string(forKey: userDefaultsKeyKey)
        let key = keyRaw.flatMap(PTTHotkeyKey.init(rawValue:)) ?? Self.defaults.key
        
        // Load legacy modifiers
        let mask: UInt
        if let storedMask = defaults.object(forKey: userDefaultsModifiersKey) as? NSNumber {
            mask = storedMask.uintValue
        } else {
            mask = Self.defaults.modifierFlags.rawValue
        }
        let flags = NSEvent.ModifierFlags(rawValue: mask)
        
        let inferredCombo = keyCombo ?? KeyCombination.from(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )

        let loaded = PTTHotkeyConfiguration(
            activationMode: activationMode,
            keyCombination: inferredCombo,
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
        return loaded.normalized()
    }

    func save(to defaults: UserDefaults = .standard) {
        let safe = normalized()
        defaults.set(safe.activationMode.rawValue, forKey: Self.userDefaultsActivationModeKey)
        defaults.set(safe.keyCombination.rawValue, forKey: Self.userDefaultsKeyCombinationKey)
        defaults.set(safe.key.rawValue, forKey: Self.userDefaultsKeyKey)
        defaults.set(safe.modifierFlags.rawValue, forKey: Self.userDefaultsModifiersKey)
    }
}

extension Notification.Name {
    static let pttHotkeyConfigurationDidChange = Notification.Name("pttHotkeyConfigurationDidChange")
}
