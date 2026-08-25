import AppKit
import SwiftUI

/// Preset menu (live catalogue) + Record shortcut… capture.
///
/// `showsNoneOption` (hotkey onboarding card UX): onboarding hides "Not specified" — the deck's
/// router requires a key before advancing, so a no-key choice there is a
/// dead end. Settings keeps it.
struct HotkeyControl: View {
    @Binding var hotkey: KeyChord?
    var showsNoneOption = true
    /// Rendering surface (hotkey onboarding card UX follow-up): `.compass` keeps the Settings
    /// tokens; `.deck` renders in OnboardingDeckTokens so the control belongs
    /// to the onboarding card's material language (Settings' kPanel/kHair are
    /// static LIGHT literals — imported onto the charcoal deck they read as
    /// white foreign chrome).
    var surface: Surface = .compass

    enum Surface { case compass, deck }

    private var chipBackground: Color {
        switch surface {
        case .compass: Color.kPanel
        // Eighth QA round (hotkey onboarding card UX): the resting plate joins the footer
        // buttons' grammar — RAISED, not recessed. Seven rounds proved a
        // plate sunk into the card reads as a disabled field no matter how
        // loud the edge gets; a dropdown is a press target (fourth-round
        // ruling), and raised-in-dark / white-on-cream + hard edge + shadow
        // is exactly how Back/Continue two inches below announce themselves.
        case .deck: OnboardingDeckTokens.tile
        }
    }

    /// State split for depth: resting/hover = raised press target (above);
    /// capture = the recessed well, because a recording target is a thing
    /// you put input INTO (fourth-round law). Silhouette never changes.
    private var plateBackground: Color {
        guard surface == .deck, capturing else { return chipBackground }
        return OnboardingDeckTokens.well
    }

    private var chipEdge: Color {
        switch surface {
        case .compass: Color.kHair
        case .deck: OnboardingDeckTokens.controlEdge
        }
    }

    /// Rest-state chrome responds to hover (seventh QA round): the edge
    /// darkens toward ink and the rest shadow deepens a step — a real lift,
    /// not another whisper (fifth-round law: separation from tokens with
    /// per-appearance contrast, never layered same-tone whispers).
    private var restingStroke: Color {
        hovering ? chipInk.opacity(0.35) : chipEdge
    }

    private var restingShadow: Color {
        switch surface {
        case .compass: Color.black.opacity(hovering ? 0.09 : 0)
        case .deck: Color.black.opacity(hovering ? 0.09 : 0.05)
        }
    }

    /// Inset lit edge along the top of the boxed control (Double-Bezel law:
    /// a control never sits flatly on its ground).
    private var chipTopHighlight: some View {
        Rectangle()
            .fill(OnboardingDeckTokens.controlTopHighlight)
            .frame(height: 1)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    private var chipInk: Color {
        switch surface {
        case .compass: Color.kInk
        case .deck: OnboardingDeckTokens.ink
        }
    }

    private var chipMutedInk: Color {
        switch surface {
        case .compass: Color.kInk3
        case .deck: OnboardingDeckTokens.ink3
        }
    }

    /// Eighth round: the resting chevron steps up from ink3 to ink2 — the
    /// affordance must be legible AT REST, not only once the pointer lands.
    private var chipMutedInk2: Color {
        switch surface {
        case .compass: Color.kInk2
        case .deck: OnboardingDeckTokens.ink2
        }
    }

    private var chipRadius: CGFloat {
        switch surface {
        case .compass: SettingsLayout.radiusButton
        case .deck: 7 // OnboardingActionButtonStyle / KeyboardToken radius
        }
    }

    private var captureStroke: Color {
        switch surface {
        case .compass: rejectFlash ? Color.kInk2 : Color.kGreen.opacity(0.45)
        case .deck: rejectFlash ? OnboardingDeckTokens.ink2 : OnboardingDeckTokens.accent.opacity(0.5)
        }
    }

    private var captureShadow: Color {
        switch surface {
        case .compass: Color.kGreen.opacity(0.10)
        case .deck: OnboardingDeckTokens.accent.opacity(0.12)
        }
    }

    @State private var capturing = false
    @State private var rejectFlash = false
    @State private var monitor: Any?
    /// Seventh QA round (2026-08-22): the closed chip read as a value badge,
    /// not a press target — hover raise gives the plate a living affordance.
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedPreset: HotkeyPreset {
        guard let hotkey else { return .none }
        // Best-effort match on compact label; live app may store preset id separately.
        return HotkeyPreset.allCases.first {
            $0 != .record && $0 != .none && $0.menuLabel == hotkey.displayCompact
        } ?? .none
    }

    var body: some View {
        // hotkey onboarding card UX final composition: ONE trigger template serves rest + capture.
        // The keycap-sized chip failed five paint rounds because a ~30pt
        // control at a row's far edge never reads as a control; the fix is
        // compositional — a proper plate with real fill separation, defined
        // edge, lit top, shadow — not another color.
        Group {
            if capturing {
                triggerBody(
                    content: {
                        Text("···")
                            .font(SettingsFont.mono(13))
                            .foregroundStyle(chipInk)
                    },
                    stroke: captureStroke,
                    shadow: captureShadow
                )
                if rejectFlash {
                    Text("That key cannot be used.")
                        .font(SettingsFont.mono(12))
                        .foregroundStyle(surface == .deck ? OnboardingDeckTokens.bad : Color.kBad)
                }
            } else {
                Menu {
                    ForEach(HotkeyPreset.menuItems.filter { $0 != .record && (showsNoneOption || $0 != .none) }) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            HStack(spacing: 6) {
                                Text(preset.menuLabel)
                                    .font(preset.usesMonoLabel
                                          ? SettingsFont.mono(12.5)
                                          : SettingsFont.body(13))
                                // Seventh QA round: first-run users meet these
                                // glyphs HERE, on the teaching screen — spell
                                // the two-modifier combos out beside them.
                                if let hint = preset.plainNameHint {
                                    Text(hint)
                                        .font(SettingsFont.body(11.5))
                                        .foregroundStyle(.secondary)
                                }
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
                    triggerBody(
                        content: {
                            Text(chipLabel)
                                .font(hotkey == nil
                                      ? SettingsFont.body(12.5).weight(.medium)
                                      : SettingsFont.mono(13))
                                .foregroundStyle(hotkey == nil ? chipMutedInk : chipInk)
                        },
                        stroke: restingStroke,
                        shadow: restingShadow
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("Dictation key, \(chipLabel)"))
                .accessibilityHint("Opens a menu of presets, or records a custom shortcut.")
            }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : SettingsLayout.hoverAnim, value: hovering)
        .onDisappear { stopCapture(commit: nil) }
    }

    /// Shared boxed-keycap plate: well core (separates from the card in both
    /// appearances) + defined edge + inset lit top + shadow. Content and edge
    /// vary by state (resting vs capturing); the silhouette never changes.
    private func triggerBody<Content: View>(
        @ViewBuilder content: () -> Content,
        stroke: Color,
        shadow: Color
    ) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 8)
            // Seventh QA round: the paired up/down chevrons read as sort
            // order; a single down chevron pinned to the plate's trailing
            // edge is the platform's "this opens a menu" shape.
            // Eighth round: 10→11pt and ink3→ink2 at rest so the cue clears
            // caption scale against the serif headline.
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? chipInk : chipMutedInk2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minWidth: 72, minHeight: 32)
        .background(plateBackground)
        .overlay(RoundedRectangle(cornerRadius: chipRadius).stroke(stroke))
        .background(chipTopHighlight, alignment: .top)
        .cornerRadius(chipRadius)
        .shadow(color: shadow, radius: hovering ? 3 : 2, y: hovering ? 2 : 1)
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
            try? await Task.sleep(nanoseconds: SettingsLayout.rejectFlashNanos)
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
