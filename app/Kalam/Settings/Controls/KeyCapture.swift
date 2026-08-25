import AppKit
import SwiftUI

/// Keycap control. Local NSEvent monitor only while `capturing`.
struct KeyCapture: View {
    @Binding var hotkey: KeyChord?
    @State private var capturing = false
    @State private var rejectFlash = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                if capturing {
                    stopCapture(commit: nil)
                } else {
                    startCapture()
                }
            } label: {
                Text(keycapLabel)
                    .font(SettingsFont.mono(12))
                    .foregroundStyle(keycapForeground)
                    .padding(SettingsLayout.keycapPad)
                    .background(Color.kPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayout.keycapRadius)
                            .stroke(
                                rejectFlash ? Color.kInk2 : Color.kHair,
                                style: StrokeStyle(lineWidth: 1, dash: rejectFlash ? [4, 3] : [])
                            )
                    )
                    .cornerRadius(SettingsLayout.keycapRadius)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capturing ? "Waiting for a key. Escape cancels." : "Hotkey, \(hotkey?.displayVerbose ?? "not set")")

            if rejectFlash {
                Text("That key cannot be used.")
                    .font(SettingsFont.mono(12))
                    .foregroundStyle(Color.kBad) // shared bad-state vocabulary (F-07)
            }
        }
        .onDisappear { stopCapture(commit: nil) }
    }

    private var keycapLabel: String {
        if capturing { return rejectFlash ? "…" : "…" }
        return hotkey?.displayCompact ?? "Press a key"
    }

    private var keycapForeground: Color {
        if hotkey == nil && !capturing { return Color.kInk3 }
        return Color.kInk
    }

    private func startCapture() {
        capturing = true
        rejectFlash = false
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in stopCapture(commit: nil) }
                return nil
            }
            if let chord = KeyChordFormatter.chord(from: event) {
                Task { @MainActor in stopCapture(commit: chord) }
                return nil
            }
            Task { @MainActor in flashReject() }
            return nil
        }
    }

    private func stopCapture(commit: KeyChord?) {
        removeMonitor()
        capturing = false
        rejectFlash = false
        if let commit {
            hotkey = commit
        }
    }

    private func flashReject() {
        rejectFlash = true
        Task {
            try? await Task.sleep(nanoseconds: SettingsLayout.rejectFlashNanos)
            await MainActor.run {
                rejectFlash = false
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Maps NSEvent → KeyChord (settings redesign: real formatter — the stub's placeholder tables are gone).
/// Accepts: bare modifiers (right/left cmd/opt/ctrl/shift — fn is preset-only, its flagsChanged
/// is unreliable), and key+modifier chords over the live allowlist (letters/digits/Space/F1–F12)
/// where a modifier is required unless the key is a function key (mirrors normalized()).
/// Escape (53) is handled by the caller (cancel). Unstable keys return nil → reject flash.
enum KeyChordFormatter {
    /// Bare modifiers users may capture (fn excluded — preset-only).
    static let capturableModifierKeyCodes: Set<UInt16> = [54, 55, 58, 59, 60, 61, 62]

    static func chord(from event: NSEvent) -> KeyChord? {
        let code = event.keyCode
        guard code != 53 else { return nil } // Escape — caller cancels capture
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

        if capturableModifierKeyCodes.contains(code) {
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
