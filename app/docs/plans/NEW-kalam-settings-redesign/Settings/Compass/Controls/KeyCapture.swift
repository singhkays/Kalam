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
                    .font(CompassFont.mono(12))
                    .foregroundStyle(keycapForeground)
                    .padding(CompassLayout.keycapPad)
                    .background(Color.kPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: CompassLayout.keycapRadius)
                            .stroke(
                                rejectFlash ? Color.kInk2 : Color.kHair,
                                style: StrokeStyle(lineWidth: 1, dash: rejectFlash ? [4, 3] : [])
                            )
                    )
                    .cornerRadius(CompassLayout.keycapRadius)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capturing ? "Waiting for a key. Escape cancels." : "Hotkey, \(hotkey?.displayVerbose ?? "not set")")

            if rejectFlash {
                Text("That key cannot be used.")
                    .font(CompassFont.mono(12))
                    .foregroundStyle(Color.kInk3)
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
            try? await Task.sleep(nanoseconds: CompassLayout.rejectFlashNanos)
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

/// Maps NSEvent → KeyChord. Prefer the live app's formatter if one exists.
enum KeyChordFormatter {
    static func chord(from event: NSEvent) -> KeyChord? {
        // Escape already handled. Reject power / caps-only if needed.
        let code = event.keyCode
        if code == 53 { return nil }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        // Bare modifier keys: treat keyCode of the modifier as the chord.
        let side: KeySide = {
            // Simplified: right-side key codes for cmd/opt/ctrl/shift on Apple keyboards.
            switch code {
            case 54, 61, 62, 60: return .right // right cmd/opt/ctrl/shift (approx)
            case 55, 58, 59, 56: return .left
            default: return mods.isEmpty ? .either : .either
            }
        }()

        let compact = displayCompact(keyCode: code, modifiers: mods, side: side)
        let verbose = displayVerbose(keyCode: code, modifiers: mods, side: side)
        guard !compact.isEmpty else { return nil }

        return KeyChord(
            keyCode: code,
            modifiersRaw: mods.rawValue,
            side: side,
            displayVerbose: verbose,
            displayCompact: compact
        )
    }

    // Placeholder displays — replace with live app mapping tables.
    private static func displayCompact(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, side: KeySide) -> String {
        if modifiers.isEmpty {
            switch keyCode {
            case 54: return "Right ⌘"
            case 55: return "Left ⌘"
            case 61: return "Right ⌥"
            case 58: return "Left ⌥"
            case 62: return "Right ⌃"
            case 59: return "Left ⌃"
            case 60: return "Right ⇧"
            case 56: return "Left ⇧"
            default: break
            }
        }
        return "Key \(keyCode)"
    }

    private static func displayVerbose(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, side: KeySide) -> String {
        if modifiers.isEmpty {
            switch keyCode {
            case 54: return "Right Command"
            case 55: return "Left Command"
            case 61: return "Right Option"
            case 58: return "Left Option"
            case 62: return "Right Control"
            case 59: return "Left Control"
            case 60: return "Right Shift"
            case 56: return "Left Shift"
            default: break
            }
        }
        return "Key \(keyCode)"
    }
}
