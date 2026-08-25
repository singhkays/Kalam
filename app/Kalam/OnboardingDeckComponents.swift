import SwiftUI

struct OnboardingCardContent<Content: View, Footer: View>: View {
    let headingFocused: AccessibilityFocusState<Bool>.Binding
    let kicker: String?
    let kickerColor: Color
    let title: String
    let message: String?
    let content: Content
    let footer: Footer
    let titleSize: CGFloat
    let showsFooter: Bool

    init(
        headingFocused: AccessibilityFocusState<Bool>.Binding,
        kicker: String? = nil,
        kickerColor: Color = OnboardingDeckTokens.accent,
        title: String,
        message: String? = nil,
        titleSize: CGFloat = 34,
        showsFooter: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.headingFocused = headingFocused
        self.kicker = kicker
        self.kickerColor = kickerColor
        self.title = title
        self.message = message
        self.titleSize = titleSize
        self.showsFooter = showsFooter
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let kicker {
                        Text(kicker.uppercased())
                            .font(SettingsFont.mono(11, weight: 500))
                            .tracking(1.8)
                            .foregroundStyle(kickerColor)
                            .accessibilityAddTraits(.isHeader)
                    }

                    Text(title)
                        .font(SettingsFont.display(titleSize))
                        .tracking(-0.36)
                        .foregroundStyle(OnboardingDeckTokens.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        // Statement-lockup rhythm (2026-08-22, unified with the
                        // welcome plate): eyebrow hugs the serif at 6 — the
                        // display face's own descent supplies extra air.
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused(headingFocused)

                    if let message {
                        Text(message)
                            .font(SettingsFont.body(15, weight: 400))
                            .foregroundStyle(OnboardingDeckTokens.ink2)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }

                    content
                        .padding(.top, 22)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
            }

            if showsFooter {
                Divider()
                    .overlay(OnboardingDeckTokens.hair2)

                footer
                    .padding(.horizontal, 24)
                    .frame(minHeight: 54)
                    .background(OnboardingDeckTokens.footer)
            }
        }
        // Fill the window width (Option B): the card is the window ground, so
        // it must stretch edge-to-edge like the rail. Without this the card
        // sizes to its content (~650pt) and gutters open beside it — the old
        // shell hid this because the card floated on the dark frame anyway.
        .onboardingDeckCardChrome()
    }
}

// MARK: - Card chrome (Option B)
/// The shared window-ground chrome for deck cards: stretch edge-to-edge,
/// cream/charcoal surface, top corners riding the window silhouette (13pt —
/// the system clips content to the rounded window), squared bottom meeting
/// the rail with the junction hairline (ink @ 8%). Extracted so the welcome
/// card (bespoke centered layout) and the shared container cannot drift.
/// Welcome variant: `bottomRadius: 13` (it owns the full window silhouette —
/// the rail is hidden there) and no junction hairline (no rail = no seam).
extension View {
    func onboardingDeckCardChrome(
        bottomRadius: CGFloat = 0,
        showsJunctionHairline: Bool = true
    ) -> some View {
        self
            .frame(maxWidth: .infinity)
            .background(OnboardingDeckTokens.card)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 13,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: 13,
                style: .continuous
            ))
            .overlay(alignment: .bottom) {
                if showsJunctionHairline {
                    Rectangle()
                        .fill(OnboardingDeckTokens.ink.opacity(0.08))
                        .frame(height: 1)
                }
            }
    }
}

struct OnboardingProgressRail: View {
    let snapshot: OnboardingStatusSnapshot
    let activeRoute: OnboardingDeckRoute

    var body: some View {
        // Pure pagination display (2026-08-22, user-approved Option 2): the
        // rail's true job is POSITION — "you are here" — not transport. The
        // forward chevron was removed with it (it called advanceRoute(), which
        // on any locked gate silently re-returned the same card — a no-op that
        // only "worked" where the footer's primary already worked). Motion
        // lives in the card footers: ‹ Back backward, the state-honest primary
        // button forward. macOS Setup Assistant grammar: progress in the
        // chrome, actions on the working surface.
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            // Milestone gap 10 → 6 (2026-08-22, user-directed): with the
            // counter gone the four labeled columns are the band's whole
            // content — tightened so they read as ONE instrument cluster
            // instead of four spread labels. 6 matches the deck's statement
            // lockup unit (kicker→headline→copy on the cards above).
            HStack(spacing: 6) {
                milestoneColumn(.microphone)
                milestoneColumn(.accessibility)
                milestoneColumn(.model)
                milestoneColumn(.key)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(OnboardingDeckTokens.shell2)
        // Option B: the rail is the window's bottom edge — its corners are
        // the window's corners (13pt). The mockup's machined hairline runs
        // along the TOP of the band (inset white @ 6%).
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 13,
            bottomTrailingRadius: 13,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .overlay(alignment: .top) {
            // Machined hairline along the band's top edge — straight full
            // width, matching the mockup's inset white @ 6%.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue("\(snapshot.completedRequirements) of 4 requirements complete")
    }

    // MARK: - Milestone columns (Task 2)

    private enum RailMilestoneState {
        case done
        case active(subtick: Int)
        case broken(OnboardingRequirementStatus)
        case pending
    }

    private func milestoneColumn(_ milestone: OnboardingDeckMilestone) -> some View {
        let state = milestoneState(milestone)
        return VStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(1...milestone.tickCount, id: \.self) { tick in
                    Capsule()
                        // 34pt (was 26): longer dashes read as segments of one
                        // line rather than isolated pills, closing the visual
                        // gap created by the 92pt label-width columns.
                        .frame(width: 34, height: 4)
                        .foregroundColor(tickColor(tick, state: state))
                }
            }
            Text(milestoneLabel(milestone))
                .font(SettingsFont.body(10, weight: labelWeight(state)))
                .foregroundStyle(labelColor(state))
        }
        .frame(width: 92)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(milestoneLabel(milestone)): \(columnStatusText(milestone))")
    }

    private func milestoneState(_ milestone: OnboardingDeckMilestone) -> RailMilestoneState {
        let mapped = railMilestone(for: activeRoute)
        let status = snapshotStatus(milestone)

        // Honest-progress rule: only milestones BEFORE the current one may show
        // completion. A later requirement that is already satisfied (e.g. the
        // model survived a reset) stays muted — the rail reads as a journey, and
        // pre-lit future steps imply "skip ahead", which the deck doesn't do.
        if mapped.milestone == milestone {
            return .active(subtick: mapped.subtick)
        }
        if milestone.rawValue < mapped.milestone.rawValue {
            if isBroken(status) { return .broken(status) }
            if status.isReady { return .done }
            return .broken(status) // passed but not satisfied = needs revisiting
        }

        // Future milestones: always quiet, regardless of underlying state.
        return .pending
    }

    private func tickColor(_ tick: Int, state: RailMilestoneState) -> Color {
        let muted = Color.white.opacity(0.14)
        switch state {
        case .done:
            return OnboardingDeckTokens.accentOnShell
        case .active(let subtick):
            if tick < subtick { return OnboardingDeckTokens.accentOnShell }
            if tick == subtick { return OnboardingDeckTokens.shellInk }
            return muted
        case .broken(let status):
            return breakTint(status)
        case .pending:
            return muted
        }
    }

    private func labelWeight(_ state: RailMilestoneState) -> CGFloat {
        if case .active = state { return 600 }
        return 500
    }

    private func labelColor(_ state: RailMilestoneState) -> Color {
        switch state {
        case .done: return OnboardingDeckTokens.accentOnShell
        case .active: return OnboardingDeckTokens.shellInk
        case .broken(let status): return breakTint(status)
        case .pending: return OnboardingDeckTokens.shellInk3
        }
    }

    private func breakTint(_ status: OnboardingRequirementStatus) -> Color {
        switch status {
        case .pendingExternal: return OnboardingDeckTokens.railWarn
        default: return OnboardingDeckTokens.railBad
        }
    }

    private func isBroken(_ status: OnboardingRequirementStatus) -> Bool {
        switch status {
        case .denied, .invalid, .pendingRelaunch, .pendingExternal: return true
        default: return false
        }
    }

    private func milestoneLabel(_ milestone: OnboardingDeckMilestone) -> String {
        switch milestone {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .model: return "Speech model"
        case .key: return "Dictation key"
        }
    }

    private func snapshotStatus(_ milestone: OnboardingDeckMilestone) -> OnboardingRequirementStatus {
        switch milestone {
        case .microphone: return snapshot.microphoneStatus
        case .accessibility: return snapshot.accessibilityStatus
        case .model: return snapshot.modelStatus
        case .key: return snapshot.hotkeyStatus
        }
    }

    private func columnStatusText(_ milestone: OnboardingDeckMilestone) -> String {
        let mapped = railMilestone(for: activeRoute)
        if mapped.milestone == milestone && !snapshotStatus(milestone).isReady {
            return "current step"
        }
        return statusText(snapshotStatus(milestone))
    }

    private func statusText(_ status: OnboardingRequirementStatus) -> String {
        switch status {
        case .ready: "complete"
        case .denied: "denied"
        case .invalid: "invalid"
        case .pendingRelaunch: "needs relaunch"
        case .pendingExternal: "needs enabling"
        case .actionRequired: "action needed"
        case .notDetermined: "not set"
        }
    }
}

// MARK: - Manifest panel (v3 adoption, Task 3 — v1.2 layout grammar)

/// A titled panel with a right-aligned status tag and compact inline chips,
/// per the v1.2 S7 grammar: full-width, left-aligned, ~22px chips with ✓/×
/// prefixes tinted by state. Renders ONLY data the runtime actually knows.
struct OnboardingManifestPanel: View {
    let title: String
    let statusTag: String?
    let tagTone: OnboardingStatusCallout.Tone
    let entries: [OnboardingManifestEntry]

    struct OnboardingManifestEntry: Identifiable, Equatable {
        let name: String
        let isPresent: Bool
        var id: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(SettingsFont.body(12.5, weight: 600))
                    .foregroundStyle(OnboardingDeckTokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let statusTag {
                    Text(statusTag)
                        .font(SettingsFont.mono(9.5))
                        .tracking(0.8)
                        .textCase(.lowercase)
                        .foregroundStyle(tagTone.foreground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tagTone.background)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            FlowChips(entries: entries)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnboardingDeckTokens.tile)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(OnboardingDeckTokens.hair, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Simple wrapping chip row (no iOS16+ Layout dependency).
    private struct FlowChips: View {
        let entries: [OnboardingManifestEntry]

        var body: some View {
            // Fixed-width cards hold at most two ~150pt chips per row at the
            // deck's content width; wrap deterministically in pairs.
            let rows = stride(from: 0, to: entries.count, by: 2).map {
                Array(entries[$0..<min($0 + 2, entries.count)])
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 6) {
                        ForEach(rows[rowIndex]) { entry in
                            chip(entry)
                        }
                        if rows[rowIndex].count == 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }

        private func chip(_ entry: OnboardingManifestEntry) -> some View {
            HStack(spacing: 5) {
                Image(systemName: entry.isPresent ? "checkmark" : "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                Text(entry.name)
                    .font(SettingsFont.mono(10))
                    .lineLimit(1)
            }
            .foregroundStyle(entry.isPresent ? OnboardingDeckTokens.accent : OnboardingDeckTokens.bad)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(entry.isPresent ? OnboardingDeckTokens.accentSoft : OnboardingDeckTokens.badSoft)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("\(entry.name): \(entry.isPresent ? "present" : "missing")")
        }
    }
}

// MARK: - Drag-to-Settings tile (v3 adoption, Task 7)

/// A draggable copy of Kalam's app icon. The Accessibility (and Microphone)
/// lists in System Settings are standard drop targets that accept a drag whose
/// payload is a file URL to an `.app` bundle — dropping it adds the entry with
/// the toggle ON, replacing the whole `+` → Finder-picker dance (the pattern
/// Cursor/ChatGPT/Codex use in their onboarding).
///
/// Pointer-only affordance: this tile is an *enhancement* on top of the
/// existing "Open System Settings" path, never a replacement — VoiceOver and
/// keyboard users keep the buttons.
struct OnboardingDragTile: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .onDrag {
                    // Payload = THIS build's bundle (Kalam-test.app in Debug),
                    // so System Settings registers the running flavor, not a
                    // differently-named production install.
                    let provider = NSItemProvider(contentsOf: Bundle.main.bundleURL)
                        ?? NSItemProvider()
                    provider.suggestedName = KalamAppName.current
                    return provider
                } preview: {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                }

            Text("Drag \(KalamAppName.current) into the list")
                .font(SettingsFont.body(12.5, weight: 500))
                .foregroundStyle(OnboardingDeckTokens.ink2)

            Text("Dropping adds it with the switch on.")
                .font(SettingsFont.body(11.5, weight: 300))
                .foregroundStyle(OnboardingDeckTokens.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OnboardingDeckTokens.tile)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    OnboardingDeckTokens.hair,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Draggable \(KalamAppName.current) icon. Alternative: use Open System Settings and the add button.")
    }
}

struct OnboardingStatusCallout: View {
    let title: String
    let message: String
    let tone: Tone

    enum Tone {
        case neutral
        case warning
        case error
        case success
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SettingsFont.body(12.5, weight: 400))
                    .foregroundStyle(OnboardingDeckTokens.ink)
                Text(message)
                    .font(SettingsFont.body(11.5, weight: 300))
                    .foregroundStyle(OnboardingDeckTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension OnboardingStatusCallout.Tone {
    var icon: String {
        switch self {
        case .neutral: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .success: "checkmark.circle"
        }
    }

    var foreground: Color {
        switch self {
        case .neutral: OnboardingDeckTokens.ink3
        case .warning: OnboardingDeckTokens.warn
        case .error: OnboardingDeckTokens.bad
        case .success: OnboardingDeckTokens.accent
        }
    }

    var background: Color {
        switch self {
        case .neutral: OnboardingDeckTokens.well
        case .warning: OnboardingDeckTokens.warnSoft
        case .error: OnboardingDeckTokens.badSoft
        case .success: OnboardingDeckTokens.accentSoft
        }
    }
}

struct OnboardingActionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsFont.body(12.5, weight: 400))
            .foregroundStyle(prominent ? OnboardingDeckTokens.card : OnboardingDeckTokens.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(prominent ? OnboardingDeckTokens.accent : OnboardingDeckTokens.tile)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(OnboardingDeckTokens.hair, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Welcome-card hero CTA (2026-08-22): the poster's single decision.
/// FINAL form (round 3) is the editorial bar: 34pt tall, 130pt min-width,
/// (min-width driven), 14pt regular label, spring press physics. History:
/// 52pt/16 semibold read BIGGER than the serif headline; 44pt equaled its
/// cap height; the 40pt pill still read chunky — wide + thin + quiet won.
/// Corners stay on the settings v1.2 visual alignment control radius (8) so the
/// hero still reads as family to the footer actions. WELCOME ONLY — gate
/// footers keep OnboardingActionButtonStyle; the size delta between working
/// controls and the one big decision IS the hierarchy.
struct OnboardingHeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsFont.body(14, weight: 400))
            .foregroundStyle(OnboardingDeckTokens.card)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .frame(minWidth: 130, minHeight: 34)
            .background(OnboardingDeckTokens.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct OnboardingKeyboardToken: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsFont.mono(12.5, weight: 400))
            .foregroundStyle(OnboardingDeckTokens.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(OnboardingDeckTokens.tile)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(OnboardingDeckTokens.hair, lineWidth: 1)
            }
            .accessibilityLabel("Shortcut \(text)")
    }
}

/// Deck-surface segmented control (hotkey onboarding card UX follow-up): the activation-mode picker.
/// Four modes are a comparison the user should see side by side — buttons beat
/// a menu — and the old mono-caps micro-label fought the card's sentence-case
/// row-label voice. Token translation of Settings' PaperSegment (whose
/// kWell/kPanel are static LIGHT literals that read as white chrome here):
/// selected = tile fill + accent stroke + ink label; rest = ink3 on clear.
struct OnboardingSegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    var options: [(T, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = selection == value
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = value
                    }
                } label: {
                    Text(title)
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(on ? OnboardingDeckTokens.ink : OnboardingDeckTokens.ink3)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 72, minHeight: 30)
                        .background(on ? OnboardingDeckTokens.tile : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(OnboardingDeckTokens.accent, lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(OnboardingDeckTokens.well)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(OnboardingDeckTokens.hair, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
