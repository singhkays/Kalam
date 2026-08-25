import SwiftUI

struct OnboardingDeckCards: View {
    let route: OnboardingDeckRoute
    @ObservedObject var controller: OnboardingFlowController
    let onAdvance: () -> Void
    let onBack: () -> Void
    let headingFocused: AccessibilityFocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// D1 welcome entrance: flips once per deck-window lifetime (onAppear).
    /// Route switches keep this view's identity, so Back → welcome returns to
    /// the settled plate — the staged entrance is the FIRST-impression moment,
    /// deliberately not a repeating flourish.
    @State private var welcomeEntered = false

    var body: some View {
        switch route {
        case .welcome:
            welcomeCard
        case .microphone:
            microphoneCard
        case .microphoneSelection:
            microphoneSelectionCard
        case .accessibility:
            accessibilityCard
        case .modelFolder, .modelAcquisition:
            modelCard
        case .hotkey:
            hotkeyCard
        case .ready:
            readyCard
        }
    }

    /// Editorial welcome: a CENTERED TITLE PLATE — the deck's one poster
    /// moment, staged like a film title card. Serif wordmark, mono eyebrow,
    /// display serif, privacy copy, and the single primary CTA form one
    /// centered block framed by intentional whitespace.
    ///
    /// 2026-08-22 S-tier pass (B1+B2+C2+D1+D2; E1 bloom held for phase 2):
    /// - Branding (adopted after two failures): A2 serif wordmark over the
    ///   kicker = stacked green lines ("overlay", rejected); A1 "KALAM ·
    ///   WELCOME" = mechanical mid-dot (rejected). Final form: K1 natural
    ///   greeting "WELCOME TO KALAM" — warm, brand still first thing read.
    /// - C2 lockup: eyebrow + headline read as one unit.
    /// - B1/B2: the CTA is "Begin" at hero scale — the rail names the four
    ///   steps, so the button carries the verb alone; the one decision on
    ///   the screen outweighs the type above it.
    /// - D1/D2: staggered fade-up entrance + spring press physics (both
    ///   transform/opacity only, reduce-motion aware).
    ///
    /// 2026-08-21 composition pass: the CTA used to float mid-left ("abandoned"
    /// — it anchored to nothing). Gate cards anchor their actions in the footer
    /// bar, but the welcome deliberately has no footer chrome, so the whole
    /// statement centers instead (Setup-Assistant grammar). Whitespace here is
    /// the frame, not emptiness — no filler content. Optically lifted ~2% off
    /// true center against the rail's visual mass below. Gate cards stay
    /// top-left working surfaces; the contrast is the hierarchy.
    private var welcomeCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                // K1 (2026-08-22): natural-language greeting beats the
                // mid-dot compound — see doc comment for the two rejected
                // predecessors.
                Text("Welcome to Kalam".uppercased())
                    .font(SettingsFont.mono(11, weight: 500))
                    .tracking(1.8)
                    .foregroundStyle(OnboardingDeckTokens.accent)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(WelcomeEntranceStage(stage: 0, entered: welcomeEntered, reduceMotion: reduceMotion))

                Text("Your words stay on your Mac.")
                    .font(SettingsFont.display(48))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(OnboardingDeckTokens.ink)
                    // Poster lockup spacing (2026-08-22, round 2 — QA showed
                    // 10/12 still read as separate blocks once the serif's
                    // internal leading is added): eyebrow and support sentence
                    // now truly hug the statement (6 above, 6 below — uniform
                    // micro-rhythm); only the CTA keeps air (36 below).
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused(headingFocused)
                    .modifier(WelcomeEntranceStage(stage: 1, entered: welcomeEntered, reduceMotion: reduceMotion))

                Text(kalamOnboardingWelcomeCopy)
                    .font(SettingsFont.body(15, weight: 400))
                    .foregroundStyle(OnboardingDeckTokens.ink2)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540)
                    .padding(.top, 6)
                    .modifier(WelcomeEntranceStage(stage: 2, entered: welcomeEntered, reduceMotion: reduceMotion))

                // B1+B2: the verb alone, at poster scale — the rail below
                // names the four steps, so the button carries the decision.
                Button("Begin", action: onAdvance)
                    .buttonStyle(OnboardingHeroButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 36)
                    .modifier(WelcomeEntranceStage(stage: 3, entered: welcomeEntered, reduceMotion: reduceMotion))
            }
            .padding(.horizontal, 56)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Optical lift: equal spacers + extra bottom inset place the block a
        // touch above true center, balancing the (hidden) rail's visual mass.
        .padding(.bottom, 26)
        // Welcome owns the full window silhouette: rounded bottom corners,
        // no junction seam (the rail slides away on this screen — Option A).
        .onboardingDeckCardChrome(bottomRadius: 13, showsJunctionHairline: false)
        .onAppear { welcomeEntered = true }
    }

    /// D1 (2026-08-22): one stage of the welcome title-plate entrance.
    /// Transform + opacity only (GPU-safe, matching the rail's motion
    /// contract), 80ms stagger per stage, resolved instantly under
    /// reduce-motion. Presentation-only — lives entirely in the deck layer.
    private struct WelcomeEntranceStage: ViewModifier {
        let stage: Int
        let entered: Bool
        let reduceMotion: Bool

        func body(content: Content) -> some View {
            content
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : 14)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.45).delay(Double(stage) * 0.08),
                    value: entered
                )
        }
    }

    /// Quiet `< Back` affordance for card footers (Task C). Hidden on the
    /// welcome card, which has no previous step. Driven by the deck's goBack().
    @ViewBuilder
    private var backButton: some View {
        if route != .welcome {
            Button {
                onBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Back")
                }
            }
            .buttonStyle(OnboardingActionButtonStyle(prominent: false))
        }
    }

    private var microphoneCard: some View {
        OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: stepKicker(for: .microphone),
            kickerColor: microphoneTone.foreground,
            title: microphoneTitle,
            message: microphoneMessage
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if case .denied = controller.snapshot.microphoneStatus {
                    OnboardingStatusCallout(
                        title: "Microphone access is off",
                        message: "Open System Settings, enable Kalam under Privacy & Security → Microphone, then come back and check again.",
                        tone: .error
                    )
                } else {
                    OnboardingStatusCallout(
                        title: "Kalam listens only while you dictate",
                        message: "Permission allows the app to hear input. Audio is not saved as a transcript or recording by this setup flow.",
                        tone: .neutral
                    )
                }
            }
        } footer: {
            HStack {
                Button("Check again", action: controller.recheck)
                    .buttonStyle(OnboardingActionButtonStyle(prominent: false))

                Spacer()

                if controller.snapshot.microphoneStatus.isReady {
                    Button("Choose microphone", action: onAdvance)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                } else if case .denied = controller.snapshot.microphoneStatus {
                    Button("Open System Settings", action: controller.openMicrophoneSettings)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                } else {
                    Button("Allow microphone", action: controller.requestMicrophoneAccess)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var microphoneSelectionCard: some View {
        OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: stepKicker(for: .microphoneSelection),
            title: "Which microphone should Kalam use?",
            message: "Choose the input you want Kalam to prioritize. The selected device can be changed later without resetting setup."
        ) {
            let devices = controller.availableMicrophones
            VStack(alignment: .leading, spacing: 8) {
                if devices.isEmpty {
                    OnboardingStatusCallout(
                        title: "No microphone found",
                        message: "Connect an input device, then check again. Kalam will not continue until macOS exposes a usable microphone.",
                        tone: .warning
                    )
                } else {
                    // Carried-over disclosure lives ON THE ROW (2026-08-22,
                    // user option A): the selected row's sublabel reads "Last
                    // used input", so the honesty sits where the state is
                    // declared. The old banner above the list double-declared
                    // the state (check icon + SELECTED INPUT already said it)
                    // in machine-voiced meta text.
                    ForEach(devices) { device in
                        micRow(device: device)
                    }
                    // "Unselect" destination: drop the override so Kalam
                    // follows the Mac's own default input (nil is a supported
                    // runtime mode — the recording path resolves it live).
                    defaultInputRow
                }
            }
        } footer: {
            HStack {
                backButton
                Button("Check again", action: controller.recheck)
                    .buttonStyle(OnboardingActionButtonStyle(prominent: false))
                Spacer()
                Button("Continue", action: onAdvance)
                    .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    // Armed whenever a usable state exists (a selection —
                    // carried-over or just chosen). The tap-gate version read
                    // as a dead button next to a valid, labeled selection.
                    .disabled(controller.availableMicrophones.isEmpty)
            }
        }
    }

    /// One selectable input row (device or default-input destination).
    /// Sublabels use the deck's mono meta voice (uppercase + tracking), like
    /// kickers and the rail counter — machine state, not body text.
    @ViewBuilder
    private func micRow(device: MicrophoneDeviceDescriptor) -> some View {
        let isSelected = device.name == controller.snapshot.selectedMicrophoneName
        Button {
            if !isSelected {
                controller.selectMicrophone(device)
            }
            // Tapping the already-selected row is a no-op; Continue is armed.
        } label: {
            selectionRowLabel(
                icon: isSelected ? "checkmark.circle.fill" : "mic",
                iconTint: isSelected ? OnboardingDeckTokens.accent : OnboardingDeckTokens.ink3,
                title: device.name,
                subtitle: isSelected ? "Last used input" : "Available input",
                isHighlighted: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(device.name)")
        .accessibilityValue(isSelected ? "Last used input" : "Available input")
    }

    @ViewBuilder
    private var defaultInputRow: some View {
        let isDefaultActive = controller.snapshot.selectedMicrophoneName == nil
        Button {
            controller.clearMicrophoneSelection()
        } label: {
            selectionRowLabel(
                icon: isDefaultActive ? "checkmark.circle.fill" : "waveform",
                iconTint: isDefaultActive ? OnboardingDeckTokens.accent : OnboardingDeckTokens.ink3,
                title: "Use Mac's default input",
                // State voice with a STABLE base phrase: the active variant
                // prefixes "Selected ·" rather than swapping synonyms (the
                // earlier "Following system selection" read as meaning drift).
                subtitle: isDefaultActive ? "Selected · follows the sound panel" : "Follows the sound panel",
                isHighlighted: isDefaultActive
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use Mac's default input")
        .accessibilityValue(isDefaultActive ? "Selected" : "Follows the sound panel")
    }

    private func selectionRowLabel(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsFont.body(12.5, weight: 400))
                    .foregroundStyle(OnboardingDeckTokens.ink)
                Text(subtitle.uppercased())
                    .font(SettingsFont.mono(9, weight: 500))
                    .tracking(0.8)
                    .foregroundStyle(isHighlighted ? OnboardingDeckTokens.accent : OnboardingDeckTokens.ink3)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? OnboardingDeckTokens.accentSoft : OnboardingDeckTokens.tile)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isHighlighted ? OnboardingDeckTokens.accent.opacity(0.35) : OnboardingDeckTokens.hair, lineWidth: 1)
        }
    }

    private var accessibilityCard: some View {
        let status = controller.snapshot.accessibilityStatus
        let displayStatus = accessibilityDisplayStatus
        return OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: stepKicker(for: .accessibility),
            kickerColor: accessibilityTone.foreground,
            title: accessibilityTitle(for: displayStatus),
            message: accessibilityMessage(for: displayStatus)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // The action IS the first read for add-states: draggable icon
                // first, explanation after.
                switch displayStatus {
                case .actionRequired, .notDetermined, .denied, .pendingExternal:
                    OnboardingDragTile()
                    // Supporting instructions at row-title size (12.5/400) —
                    // they are the primary steps of this card, not captions.
                    // Copy rules: stable phrases (no "the list" x3), state the
                    // outcome of a drop, no hedged relaunch warnings (the
                    // pendingRelaunch card owns that case), and the deck
                    // auto-checks on return — say so instead of "check again".
                    Text("Add it with the + button instead, then flip its switch.")
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(OnboardingDeckTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("When you come back, Kalam checks by itself and moves on. If the switch is on but typing still fails, quit and reopen the app.")
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(OnboardingDeckTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                case .pendingRelaunch:
                    OnboardingStatusCallout(
                        title: "What this permission does",
                        message: "\(appDisplayName) uses Accessibility access to type the finished dictation into the app you are using. It does not make it a screen reader.",
                        tone: .neutral
                    )
                    Text("After changing the switch in System Settings, return here and check again. macOS may require a relaunch before the permission becomes active.")
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(OnboardingDeckTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready, .invalid:
                    EmptyView()
                }
            }
        } footer: {
            HStack {
                backButton
                Button("Check again", action: controller.recheck)
                    .buttonStyle(OnboardingActionButtonStyle(prominent: false))

                Spacer()

                switch displayStatus {
                case .ready:
                    Button("Continue", action: onAdvance)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                case .pendingRelaunch:
                    Button("Open System Settings", action: controller.openAccessibilitySettings)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: false))

                    Button("Quit & reopen Kalam", action: controller.relaunchApp)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                default:
                    // ONE route for every add-state (2026-08-21): deep-link to
                    // the Accessibility pane; drag the tile or use the + button
                    // from there. The former "Grant access" fired Apple's AX
                    // prompt — a second, worse path that made the card's
                    // primary action flip mid-flow (user QA: two card variants).
                    Button("Open System Settings", action: controller.openAccessibilitySettings)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var modelCard: some View {
        let presentation = controller.modelSetupPresentationState
        return OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: stepKicker(for: .modelFolder),
            kickerColor: modelTone.foreground,
            title: modelTitle(for: presentation),
            message: controller.snapshot.modelStatus.message
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if case .partialDownload = presentation {
                    // S7-style recovery: manifest panel replaces the acquisition
                    // wizard while a half-finished download is the live state.
                    partialDownloadPanel
                } else {
                    ModelAcquisitionPanel(
                        folderURL: controller.snapshot.modelLibraryURL,
                        statusMessage: controller.snapshot.modelStatus.message,
                        wizardState: controller.modelSetupWizardState,
                        selectedVersion: $controller.selectedDownloadVersion,
                        downloadCommand: controller.downloadCommand,
                        downloadCommandCopied: controller.downloadCommandCopied,
                        installCommand: ModelSetupSupport.huggingFaceInstallCommand,
                        installCommandCopied: controller.installCommandCopied,
                        onChooseFolder: controller.chooseModelFolder,
                        onChangeFolder: controller.chooseModelFolder,
                        onOpenInFinder: controller.openModelFolderInFinder,
                        onClearFolder: controller.clearModelFolder,
                        selectedRepo: controller.selectedModelRepoFolderVersion,
                        onUseParentFolder: controller.useParentFolderForSelectedRepo,
                        onConfirmCLIInstalled: controller.confirmHFCLIInstalled,
                        onCopyDownloadCommand: controller.copyDownloadCommand,
                        onCopyInstallCommand: controller.copyInstallCommand
                    )
                }

                if case .ready = presentation {
                    OnboardingStatusCallout(
                        title: "Model ready",
                        message: "Kalam found a compatible local model. It remains on this Mac and can be changed later.",
                        tone: .success
                    )
                }
            }
        } footer: {
            HStack {
                backButton
                if case .partialDownload = presentation {
                    // Primary recovery action for a partial download.
                    Button("Copy the command again", action: controller.copyDownloadCommand)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                    Button("Reveal in Finder", action: controller.openModelFolderInFinder)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: false))
                    Button("Check again", action: controller.recheck)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: false))
                    Spacer()
                    Button("Continue when ready", action: onAdvance)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                        .disabled(true)
                } else {
                    Button("Check again", action: controller.recheck)
                        .buttonStyle(OnboardingActionButtonStyle(prominent: false))
                    Spacer()
                    // Continue IS the model-location confirmation for the
                    // first-run acknowledgment stop (2026-08-22): it persists
                    // internal.hasConfirmedModelLocation before advancing, so
                    // a carried-over model is asked about exactly once and
                    // never re-shown on later visits.
                    Button(
                        controller.snapshot.modelStatus.isReady ? "Continue" : "Continue when ready",
                        action: controller.confirmModelLocation
                    )
                    .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                    .disabled(!controller.snapshot.modelStatus.isReady)
                }
            }
        }
    }

    private var hotkeyCard: some View {
        HotkeyCardContent(controller: controller, onAdvance: onAdvance, onBack: onBack, headingFocused: headingFocused)
    }

    private var readyCard: some View {
        OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: "Ready",
            kickerColor: OnboardingDeckTokens.accent,
            title: "Everything is ready.",
            message: controller.snapshot.runtimePreparationMessage ?? "Your setup is complete. Kalam is ready to dictate into the app you are using."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Microphone", value: controller.snapshot.selectedMicrophoneName ?? "Default input")
                summaryRow("Hotkey", value: controller.snapshot.selectedHotkeyDisplay)
                summaryRow("AI model", value: controller.snapshot.selectedModelVersion.displayName)
            }
        } footer: {
            HStack {
                backButton
                Text("Everything here is available in Settings")
                    .font(SettingsFont.mono(9.5))
                    .foregroundStyle(OnboardingDeckTokens.ink3)
                Spacer()
                Button("Start dictating", action: controller.startDictating)
                    .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.snapshot.isStartDictatingDisabled)
            }
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(SettingsFont.body(12.5, weight: 400))
                .foregroundStyle(OnboardingDeckTokens.ink)
            Spacer()
            Text(value)
                .font(SettingsFont.mono(10))
                .foregroundStyle(OnboardingDeckTokens.ink3)
                .lineLimit(1)
        }
        .padding(11)
        .background(OnboardingDeckTokens.tile)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OnboardingDeckTokens.hair, lineWidth: 1)
        }
    }

    private var microphoneTitle: String {
        switch controller.snapshot.microphoneStatus {
        case .denied: "macOS is holding the microphone"
        case .ready: "Microphone access is ready"
        default: "May Kalam use your microphone?"
        }
    }

    private var microphoneMessage: String {
        switch controller.snapshot.microphoneStatus {
        case .denied: "macOS will not ask again from inside Kalam. Enable the switch in System Settings, then return here."
        case .ready: "Choose the input device Kalam should prioritize for dictation."
        default: "Kalam needs microphone access to hear the words you choose to dictate."
        }
    }

    private var accessibilityDisplayStatus: OnboardingRequirementStatus {
        if controller.snapshot.accessibilityStatus.isReady {
            return controller.snapshot.accessibilityStatus
        }
        switch controller.accessibilitySetupState {
        case .idle:
            return controller.snapshot.accessibilityStatus
        case .needsExternalEnable:
            return .pendingExternal(message: "Open System Settings and enable Kalam under Accessibility.")
        case .enabledPendingRelaunch:
            return .pendingRelaunch(message: "Kalam still cannot verify Accessibility access. Restart Kalam after enabling the switch.")
        }
    }

    private func accessibilityTitle(for status: OnboardingRequirementStatus) -> String {
        switch status {
        case .pendingExternal: "Enable Accessibility for \(appDisplayName)"
        case .pendingRelaunch: "The switch is on, but Kalam still cannot type"
        case .ready: "Accessibility access is ready"
        default: "May \(appDisplayName) type for you?"
        }
    }

    private func accessibilityMessage(for status: OnboardingRequirementStatus) -> String {
        switch status {
        case .pendingExternal: "macOS opened System Settings so you can enable \(appDisplayName). Return here after the switch changes."
        case .pendingRelaunch: "macOS may require a fresh Kalam process after granting Accessibility."
        default: "Kalam uses this permission only to type your finished dictation into the app you are using."
        }
    }

    private var microphoneTone: OnboardingStatusCallout.Tone {
        tone(for: controller.snapshot.microphoneStatus)
    }

    private var accessibilityTone: OnboardingStatusCallout.Tone {
        tone(for: accessibilityDisplayStatus)
    }

    /// The running build's display name ("Kalam" or "Kalam-test") — permission
    /// copy must match what System Settings actually lists.
    private var appDisplayName: String { KalamAppName.current }

    private var modelTone: OnboardingStatusCallout.Tone {
        tone(for: controller.snapshot.modelStatus)
    }

    private func tone(for status: OnboardingRequirementStatus) -> OnboardingStatusCallout.Tone {
        if status.isReady { return .success }
        switch status {
        case .denied, .invalid, .pendingRelaunch:
            return .error
        case .pendingExternal:
            return .warning
        default:
            return .neutral
        }
    }

    private func modelTitle(for presentation: ModelSetupPresentationState) -> String {
        switch presentation {
        case .needsFolder: "Choose where the model should live"
        case .repoFolderSelected: "Choose the model library, not the model folder"
        case .needsModel: "Get a local model onto your Mac"
        case .partialDownload(_, let missing, let total, _, _):
            "\(total - missing.count) of \(total) model files arrived"
        case .ready: "Your local speech model is ready"
        }
    }

    /// The S7-style manifest panel for a partial download (v3 adoption Task 6).
    /// Renders only what the runtime verified per file.
    @ViewBuilder
    private var partialDownloadPanel: some View {
        if case .partialDownload(let expectedPath, let missing, let total, _, _) = controller.modelSetupPresentationState {
            let folderName = (expectedPath as NSString).lastPathComponent
            OnboardingManifestPanel(
                title: "Folder found, \(total - missing.count) of \(total) files short",
                statusTag: "incomplete",
                tagTone: .warning,
                entries: ModelSetupSupport.requiredModelFiles(for: controller.snapshot.selectedModelVersion)
                    .map { name in
                        OnboardingManifestPanel.OnboardingManifestEntry(name: name, isPresent: !missing.contains(name))
                    }
            )
            Text("The download was interrupted. Run the command again; it skips files already on disk and fetches only the missing ones.")
                .font(SettingsFont.body(11.5, weight: 300))
                .foregroundStyle(OnboardingDeckTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Watching \(folderName)")
                .font(SettingsFont.mono(9.5))
                .foregroundStyle(OnboardingDeckTokens.ink3)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }
}

private struct HotkeyCardContent: View {
    @ObservedObject var controller: OnboardingFlowController
    let onAdvance: () -> Void
    let onBack: () -> Void
    let headingFocused: AccessibilityFocusState<Bool>.Binding

    init(controller: OnboardingFlowController, onAdvance: @escaping () -> Void, onBack: @escaping () -> Void, headingFocused: AccessibilityFocusState<Bool>.Binding) {
        self.controller = controller
        self.onAdvance = onAdvance
        self.onBack = onBack
        self.headingFocused = headingFocused
    }

    var body: some View {
        OnboardingCardContent(
            headingFocused: headingFocused,
            kicker: stepKicker(for: .hotkey),
            kickerColor: controller.snapshot.hotkeyStatus.isReady ? OnboardingDeckTokens.accent : OnboardingDeckTokens.ink3,
            title: "Choose the key that starts dictation.",
            // hotkey onboarding card UX Option A cleanup: once confirmed, the status message is the
            // same chord the chip already shows ("Shortcut: Right ⌥" twice on
            // one card). Disclosure lives ON the state — suppress the echo.
            message: hotkeyStatusEchoesChip ? nil : controller.snapshot.hotkeyStatus.message
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // hotkey onboarding card UX final composition: the key row mirrors the
                // activation-mode row below — label above its control, both
                // left-aligned — instead of a chip stranded at the far edge
                // of a wide quiet row. The menu keeps presets + divider +
                // "Record shortcut…" (round-1 requirement).
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation key")
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(OnboardingDeckTokens.ink)
                    Text("Pick a preset, or record your own.")
                        .font(SettingsFont.body(11.5, weight: 300))
                        .foregroundStyle(OnboardingDeckTokens.ink2)
                    // hotkey onboarding card UX follow-up: surface .deck re-skins this shared
                    // Settings control in OnboardingDeckTokens — imported
                    // light literals read as white foreign chrome here.
                    HotkeyControl(hotkey: hotkeyBinding, showsNoneOption: false, surface: .deck)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Activation mode")
                        .font(SettingsFont.body(12.5, weight: 400))
                        .foregroundStyle(OnboardingDeckTokens.ink)
                    OnboardingSegmentedControl(
                        selection: activationModeBinding,
                        options: PTTActivationMode.allCases.map { ($0, $0.displayName) }
                    )
                }
            }
        } footer: {
            HStack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("Back")
                    }
                }
                .buttonStyle(OnboardingActionButtonStyle(prominent: false))
                Spacer()
                // hotkey onboarding card UX follow-up: the label names the CURRENT state until the
                // user confirms it. "Use this shortcut" (unconfirmed) vs
                // "Continue" (confirmed, e.g. repair-mode revisit) — the
                // button press is the gate's explicit acknowledgment.
                Button(controller.snapshot.hotkeyStatus.isReady ? "Continue" : "Use this shortcut", action: {
                    controller.confirmHotkey()
                    onAdvance()
                })
                .buttonStyle(OnboardingActionButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// hotkey onboarding card UX Option A: the confirmed status message is "Shortcut: <chord>" —
    /// exactly what the chip already displays. While unconfirmed, the message
    /// is real guidance ("Choose a key combination…") and stays.
    private var hotkeyStatusEchoesChip: Bool {
        controller.snapshot.hotkeyStatus.isReady
            && controller.snapshot.hotkeyStatus.message.hasPrefix("Shortcut:")
    }

    private var activationModeBinding: Binding<PTTActivationMode> {
        Binding(
            get: { controller.hotkeyConfiguration.activationMode },
            set: { mode in
                var config = controller.hotkeyConfiguration
                config.activationMode = mode
                // hotkey onboarding card UX follow-up: markPicked: false — picking a mode must not
                // confirm the gate. The Continue press is the acknowledgment;
                // markPicked: true here is what made the card auto-advance.
                controller.updateHotkeyConfiguration(config, markPicked: false)
            }
        )
    }

    /// hotkey onboarding card UX: single chord binding for the capture-menu control. Preset chords
    /// route back through `HotkeyPreset.preset(matching:)` into the preset
    /// storage path (`keyCombination`, customChord cleared) — the same
    /// normalization Settings' LiveSettingsBacking applies, so onboarding and
    /// Settings stay interchangeable on one schema.
    private var hotkeyBinding: Binding<KeyChord?> {
        Binding(
            get: {
                let config = controller.hotkeyConfiguration.normalized()
                if let custom = config.customChord { return custom }
                guard config.keyCombination != .notSpecified,
                      let preset = HotkeyPreset.allCases.first(where: { $0.liveCombination == config.keyCombination })
                else { return nil }
                return preset.makeChord()
            },
            set: { chord in
                var config = controller.hotkeyConfiguration
                guard let chord else {
                    config.keyCombination = .notSpecified
                    config.customChord = nil
                    return
                }
                if let preset = HotkeyPreset.preset(matching: chord) {
                    config.apply(keyCombination: preset.liveCombination ?? .notSpecified)
                    config.customChord = nil
                } else {
                    config.keyCombination = .notSpecified
                    config.customChord = chord
                }
                // hotkey onboarding card UX follow-up: markPicked: false — selecting persists the
                // choice but does NOT confirm the gate (that made the card
                // auto-advance). Continue is the explicit acknowledgment.
                controller.updateHotkeyConfiguration(config, markPicked: false)
            }
        )
    }
}
