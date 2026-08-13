import AppKit
import SwiftUI

/// Preset menu (live catalogue) + Record shortcut… capture.
struct HotkeyControl: View {
    @Binding var hotkey: KeyChord?
    @State private var capturing = false
    @State private var rejectFlash = false
    @State private var monitor: Any?

    private var selectedPreset: HotkeyPreset {
        guard let hotkey else { return .none }
        // Best-effort match on compact label; live app may store preset id separately.
        return HotkeyPreset.allCases.first {
            $0 != .record && $0 != .none && $0.menuLabel == hotkey.displayCompact
        } ?? .none
    }

    var body: some View {
        HStack(spacing: 10) {
            if capturing {
                Text(rejectFlash ? "···" : "···")
                    .font(CompassFont.mono(12))
                    .foregroundStyle(Color.kInk)
                    .padding(CompassLayout.keycapPad)
                    .frame(minWidth: 52)
                    .background(Color.kPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: CompassLayout.keycapRadius)
                            .stroke(
                                rejectFlash ? Color.kInk2 : Color.kGreen.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: rejectFlash ? [4, 3] : [])
                            )
                    )
                    .shadow(color: Color.kGreen.opacity(0.10), radius: 3)
                if rejectFlash {
                    Text("That key cannot be used.")
                        .font(CompassFont.mono(12))
                        .foregroundStyle(Color.kInk3)
                }
            } else {
                Menu {
                    ForEach(HotkeyPreset.menuItems.filter { $0 != .record }) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            HStack {
                                Text(preset.menuLabel)
                                    .font(preset.usesMonoLabel
                                          ? CompassFont.mono(12.5)
                                          : CompassFont.body(13))
                                if matches(preset) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Record shortcut…") {
                        startCapture()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(chipLabel)
                            .font(hotkey == nil
                                  ? CompassFont.body(12.5).weight(.medium)
                                  : CompassFont.mono(12.5))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.kInk3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.kPanel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kHair))
                    .cornerRadius(8)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .onDisappear { stopCapture(commit: nil) }
    }

    private var chipLabel: String {
        hotkey?.displayCompact ?? "Not specified"
    }

    private func matches(_ preset: HotkeyPreset) -> Bool {
        if preset == .none { return hotkey == nil }
        guard let hotkey else { return false }
        return hotkey.displayCompact == preset.menuLabel
    }

    private func apply(_ preset: HotkeyPreset) {
        if preset == .record {
            startCapture()
            return
        }
        if preset == .none {
            hotkey = nil
            return
        }
        hotkey = preset.makeChord()
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
            await MainActor.run { rejectFlash = false }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
