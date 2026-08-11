import AppKit
import SwiftUI

struct ShortcutSettingsTab: View {
    @Binding var hotkeyDraft: PTTHotkeyConfiguration
    @State private var showingShortcutRecorder = false

    var body: some View {
        keyboardControlsContent
            .sheet(isPresented: $showingShortcutRecorder) {
                ShortcutRecorderSheet(
                    initialDisplay: hotkeyDraft.displayString,
                    onCancel: {
                        showingShortcutRecorder = false
                    },
                    onCapture: { key, modifiers in
                        applyRecordedShortcut(key: key, modifiers: modifiers)
                        showingShortcutRecorder = false
                    }
                )
            }
    }

    var selectedShortcutLabel: String {
        if hotkeyDraft.keyCombination == .notSpecified {
            return "Custom (\(hotkeyDraft.displayString))"
        }
        return hotkeyDraft.keyCombination.displayName
    }
    private var keyboardControlsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcut")
                        .font(KalamTheme.pageTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)
                    Text("Set a key to start and stop recording.")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    // Activation mode + key combination selectors, inline
                    HStack(spacing: 8) {
                        Text("Activation")
                            .font(KalamTheme.calloutFont)
                            .foregroundColor(KalamTheme.textSecondary)

                        // Activation Mode
                        Menu {
                            ForEach(ActivationMode.allCases) { mode in
                                Button {
                                    hotkeyDraft.activationMode = mode
                                } label: {
                                    HStack {
                                        Text(mode.displayName)
                                        if hotkeyDraft.activationMode == mode {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(hotkeyDraft.activationMode.displayName)
                                    .font(KalamTheme.bodyStrongFont)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(KalamTheme.captionFont)
                                    .accessibilityHidden(true)
                            }
                            .foregroundColor(KalamTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(KalamTheme.controlTint)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                            )
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)

                        Spacer()

                        Text("Hotkey")
                            .font(KalamTheme.calloutFont)
                            .foregroundColor(KalamTheme.textSecondary)

                        // Key Combination
                        Menu {
                            Button {
                                hotkeyDraft.keyCombination = .notSpecified
                            } label: {
                                HStack {
                                    Text(KeyCombination.notSpecified.displayName)
                                    if hotkeyDraft.keyCombination == .notSpecified {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            ForEach(KeyCombination.allCases.filter { $0 != .notSpecified }) {
                                combo in
                                Button {
                                    hotkeyDraft.apply(keyCombination: combo)
                                } label: {
                                    HStack {
                                        Text(combo.displayName)
                                        if hotkeyDraft.keyCombination == combo {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Record shortcut...") {
                                showingShortcutRecorder = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedShortcutLabel)
                                    .font(KalamTheme.bodyStrongFont)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(KalamTheme.captionFont)
                                    .accessibilityHidden(true)
                            }
                            .foregroundColor(KalamTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(KalamTheme.controlTint)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                            )
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .settingsCardSurface()

                Rectangle()
                    .fill(KalamTheme.strokeSubtle)
                    .frame(height: 1)
                    .padding(.top, 12)

                // Behavior guide — redesigned as a native footer list
                VStack(alignment: .leading, spacing: 14) {
                    Text("Activation Modes")
                        .font(KalamTheme.bodyStrongFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        instructionRow(
                            icon: "arrow.triangle.2.circlepath", title: "Hold or Toggle",
                            desc: "Intelligently auto-detects behavior")
                        instructionRow(
                            icon: "hand.tap", title: "Toggle",
                            desc: "Tap to start, tap again to stop")
                        instructionRow(
                            icon: "hand.raised.fill", title: "Hold",
                            desc: "Record only while key is pressed")
                        instructionRow(
                            icon: "square.2.layers.3d", title: "Double Tap",
                            desc: "Start recording by tapping twice quickly")

                        Text("Right-side presets (Right ⌘/⌥/⇧/⌃) require the right physical key.")
                            .font(KalamTheme.footnoteFont)
                            .foregroundColor(KalamTheme.textTertiary)
                            .padding(.top, 4)
                            .padding(.leading, 32)
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 4)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    @ViewBuilder
    private func instructionRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(KalamTheme.accent)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(KalamTheme.bodyStrongFont)
                    .foregroundColor(KalamTheme.textPrimary)
                Text(desc)
                    .font(KalamTheme.footnoteFont)
                    .foregroundColor(KalamTheme.textSecondary)
            }
        }
    }
    private func applyRecordedShortcut(key: PTTHotkeyKey, modifiers: NSEvent.ModifierFlags) {
        let relevantModifiers = modifiers.intersection([.command, .shift, .option, .control])
        var updated = hotkeyDraft
        updated.keyCombination = .notSpecified
        updated.key = key
        updated.command = relevantModifiers.contains(.command)
        updated.shift = relevantModifiers.contains(.shift)
        updated.option = relevantModifiers.contains(.option)
        updated.control = relevantModifiers.contains(.control)
        hotkeyDraft = updated
    }
}

private struct ShortcutRecorderSheet: View {
    let initialDisplay: String
    let onCancel: () -> Void
    let onCapture: (PTTHotkeyKey, NSEvent.ModifierFlags) -> Void

    @State private var keyDownMonitor: Any?
    @State private var flagsChangedMonitor: Any?
    @State private var statusText: String = "Recording..."
    @State private var statusColor: Color = .green
    @State private var captured = false

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Record Shortcut")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(KalamTheme.textPrimary)

                Text("Press a combination including ⌘, ⌥, ⌃, or ⇧.")
                    .font(KalamTheme.calloutFont)
                    .foregroundColor(KalamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 12)

            VStack(spacing: 12) {
                Text(statusText)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(statusColor)
                    .scaleEffect(pulseScale)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        KalamTheme.controlTint,
                                        KalamTheme.controlTint.opacity(0.7),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(statusColor.opacity(0.3), lineWidth: 1.5)
                    )
                    .shadow(color: statusColor.opacity(0.1), radius: 12)
            }
            .padding(.horizontal, 40)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.03
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 4)
            .onTapGesture {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }

            VStack(spacing: 8) {
                if !initialDisplay.isEmpty {
                    Text("Current: \(initialDisplay)")
                        .font(KalamTheme.bodyFont)
                        .foregroundColor(KalamTheme.textTertiary)
                }

                Button("Cancel") {
                    cancel()
                }
                .buttonStyle(.plain)
                .font(KalamTheme.bodyFont)
                .foregroundColor(KalamTheme.textSecondary)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(KalamTheme.panelTint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                )
            }
            .padding(.top, 10)
        }
        .padding(24)
        .frame(width: 520, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            beginCapture()
        }
        .onDisappear {
            stopCapture()
        }
    }

    private func beginCapture() {
        statusText = "Recording..."
        statusColor = .green
        captured = false

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
        }
    }

    private func stopCapture() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
            self.flagsChangedMonitor = nil
        }
    }

    private func cancel() {
        stopCapture()
        onCancel()
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard !captured else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty {
            statusText = "Recording..."
            statusColor = .green
            return nil
        }
        statusText = modifiersString(modifiers)
        statusColor = .green
        return nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !captured else { return nil }

        if event.keyCode == 53 {  // ESC
            cancel()
            return nil
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])

        guard let key = PTTHotkeyKey.fromKeyCode(event.keyCode) else {
            showInvalid("Unsupported key")
            return nil
        }

        if !key.isFunctionKey && modifiers.isEmpty {
            showInvalid("Add a modifier key")
            return nil
        }

        captured = true
        statusText = shortcutString(key: key, modifiers: modifiers)
        statusColor = .green
        stopCapture()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onCapture(key, modifiers)
        }

        return nil
    }

    private func showInvalid(_ message: String) {
        statusText = message
        statusColor = .red
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard !captured else { return }
            statusText = "Recording..."
            statusColor = .green
        }
    }

    private func modifiersString(_ modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func shortcutString(key: PTTHotkeyKey, modifiers: NSEvent.ModifierFlags) -> String {
        let modifierText = modifiersString(modifiers)
        return modifierText + key.displayName
    }
}

