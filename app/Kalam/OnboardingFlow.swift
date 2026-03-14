import SwiftUI
import AVFoundation
import AppKit



struct OnboardingConfiguration: Equatable {
    static let defaults = OnboardingConfiguration(
        hasCompletedRequiredSetup: false,
        hasAttemptedAccessibilitySetup: false,
        hasPickedHotkey: false
    )

    var hasCompletedRequiredSetup: Bool
    var hasAttemptedAccessibilitySetup: Bool
    var hasPickedHotkey: Bool

    private static let hasCompletedRequiredSetupKey = "internal.hasCompletedRequiredSetup"
    private static let hasAttemptedAccessibilitySetupKey = "internal.hasAttemptedAccessibilitySetup"
    private static let hasPickedHotkeyKey = "internal.hasPickedHotkey"

    static func load(from defaults: UserDefaults = .standard) -> OnboardingConfiguration {
        OnboardingConfiguration(
            hasCompletedRequiredSetup: bool(
                forKey: hasCompletedRequiredSetupKey,
                defaults: defaults,
                fallback: Self.defaults.hasCompletedRequiredSetup
            ),
            hasAttemptedAccessibilitySetup: bool(
                forKey: hasAttemptedAccessibilitySetupKey,
                defaults: defaults,
                fallback: Self.defaults.hasAttemptedAccessibilitySetup
            ),
            hasPickedHotkey: bool(
                forKey: hasPickedHotkeyKey,
                defaults: defaults,
                fallback: false
            )
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(hasCompletedRequiredSetup, forKey: Self.hasCompletedRequiredSetupKey)
        defaults.set(hasAttemptedAccessibilitySetup, forKey: Self.hasAttemptedAccessibilitySetupKey)
        defaults.set(hasPickedHotkey, forKey: Self.hasPickedHotkeyKey)
    }

    static func reset(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hasCompletedRequiredSetupKey)
        defaults.removeObject(forKey: hasAttemptedAccessibilitySetupKey)
        defaults.removeObject(forKey: hasPickedHotkeyKey)
        
        // Thorough reset: also clear model and audio persistence
        defaults.removeObject(forKey: "audio.selectedInputDeviceUID")
        defaults.removeObject(forKey: "models.modelLibraryBookmark")
        defaults.removeObject(forKey: "models.asrVersion")
        defaults.removeObject(forKey: "internal.hasPickedHotkey") // Double check the key
    }

    private static func bool(forKey key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

enum OnboardingMode: Equatable {
    case firstRun
    case repair

    var windowTitle: String {
        switch self {
        case .firstRun:
            return "Welcome to Kalam"
        case .repair:
            return "Kalam Needs Attention"
        }
    }
}

enum OnboardingRequirement: CaseIterable, Equatable {
    case microphone
    case accessibility
    case hotkey
    case model
}

enum OnboardingRequirementStatus: Equatable {
    case notDetermined(message: String)
    case actionRequired(message: String)
    case pendingExternal(message: String)
    case pendingRelaunch(message: String)
    case denied(message: String)
    case invalid(message: String)
    case ready(message: String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var isNotDetermined: Bool {
        if case .notDetermined = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .notDetermined(let message),
             .actionRequired(let message),
             .pendingExternal(let message),
             .pendingRelaunch(let message),
             .denied(let message),
             .invalid(let message),
             .ready(let message):
            return message
        }
    }
}

enum AccessibilitySetupState: Equatable {
    case idle
    case needsExternalEnable
    case enabledPendingRelaunch
}

struct OnboardingStatusSnapshot: Equatable {
    let mode: OnboardingMode
    let microphoneStatus: OnboardingRequirementStatus
    let accessibilityStatus: OnboardingRequirementStatus
    let hotkeyStatus: OnboardingRequirementStatus
    let storageFolderStatus: OnboardingRequirementStatus
    let modelStatus: OnboardingRequirementStatus
    
    let selectedMicrophoneName: String?
    let selectedHotkeyDisplay: String
    let selectedModelVersion: ASRModelVersion
    let installedModelVersions: [ASRModelVersion]
    let modelAvailability: ASRModelAvailability
    let modelLibraryURL: URL?
    let isAudioReady: Bool
    let isASRReady: Bool

    var completedRequirements: Int {
        [microphoneStatus, accessibilityStatus, hotkeyStatus, modelStatus].filter(\.isReady).count
    }

    var hasIncompleteRequirements: Bool {
        completedRequirements < 4
    }

    var canStartDictating: Bool {
        completedRequirements == 4 && isAudioReady && isASRReady
    }

    var runtimePreparationMessage: String? {
        guard completedRequirements == 4 else { return nil }
        if !isAudioReady {
            return "Preparing microphone…"
        }
        if !isASRReady {
            return "Preparing dictation engine…"
        }
        return nil
    }

    var brokenRequirements: Set<OnboardingRequirement> {
        var broken: Set<OnboardingRequirement> = []
        if !microphoneStatus.isReady {
            broken.insert(.microphone)
        }
        if !accessibilityStatus.isReady {
            broken.insert(.accessibility)
        }
        if !hotkeyStatus.isReady {
            broken.insert(.hotkey)
        }
        if !modelStatus.isReady {
            broken.insert(.model)
        }
        return broken
    }

    static func evaluate(
        microphoneAuthorization: AVAuthorizationStatus,
        selectedMicrophoneName: String?,
        accessibilityTrusted: Bool,
        hasAttemptedAccessibilitySetup: Bool,
        hotkeyConfig: PTTHotkeyConfiguration,
        hasPickedHotkey: Bool,
        selectedModelVersion: ASRModelVersion,
        modelLibraryURL: URL?,
        selectedModelAvailability: ASRModelAvailability,
        installedModelVersions: [ASRModelVersion],
        hasCompletedRequiredSetup: Bool,
        isAudioReady: Bool,
        isASRReady: Bool
    ) -> OnboardingStatusSnapshot {
        let microphoneStatus: OnboardingRequirementStatus
        switch microphoneAuthorization {
        case .authorized:
            microphoneStatus = .ready(message: "Allowed")
        case .notDetermined:
            microphoneStatus = .actionRequired(message: "Needs access to hear your voice.")
        case .denied, .restricted:
            microphoneStatus = .denied(message: "Access denied. Please enable in System Settings.")
        @unknown default:
            microphoneStatus = .denied(message: "Access denied. Please enable in System Settings.")
        }

        let accessibilityStatus: OnboardingRequirementStatus =
            accessibilityTrusted
            ? .ready(message: "Granted")
            : (
                hasAttemptedAccessibilitySetup
                ? .pendingExternal(message: "Kalam still can't verify Accessibility access. Confirm the switch is on in System Settings. If it is already on, restart Kalam and return here.")
                : .actionRequired(message: "Required to type text into other applications.")
            )

        let hotkeyStatus: OnboardingRequirementStatus =
            hasPickedHotkey
            ? .ready(message: "Shortcut: \(hotkeyConfig.displayString)")
            : .actionRequired(message: "Choose a key combination to trigger dictation.")

        let storageFolderStatus: OnboardingRequirementStatus
        if let modelLibraryURL = modelLibraryURL {
            storageFolderStatus = .ready(message: modelLibraryURL.path)
        } else {
            storageFolderStatus = .actionRequired(message: "Kalam runs securely on-device. Choose a folder to store your dictation models.")
        }

        let modelStatus: OnboardingRequirementStatus
        switch selectedModelAvailability {
        case .installed:
            modelStatus = .ready(message: "Downloaded and ready")
        case .modelLibraryNotConfigured:
            modelStatus = .actionRequired(message: "Set up your local speech model for on-device dictation.")
        case .missingModelFolder, .invalidModelFolder:
            modelStatus = .notDetermined(message: "Finish setting up your local speech model.")
        }

        let mode: OnboardingMode = hasCompletedRequiredSetup ? .repair : .firstRun

        return OnboardingStatusSnapshot(
            mode: mode,
            microphoneStatus: microphoneStatus,
            accessibilityStatus: accessibilityStatus,
            hotkeyStatus: hotkeyStatus,
            storageFolderStatus: storageFolderStatus,
            modelStatus: modelStatus,
            selectedMicrophoneName: selectedMicrophoneName,
            selectedHotkeyDisplay: hotkeyConfig.displayString,
            selectedModelVersion: selectedModelVersion,
            installedModelVersions: installedModelVersions,
            modelAvailability: selectedModelAvailability,
            modelLibraryURL: modelLibraryURL,
            isAudioReady: isAudioReady,
            isASRReady: isASRReady
        )
    }

}

@MainActor
final class OnboardingFlowController: ObservableObject {
    @Published private(set) var snapshot: OnboardingStatusSnapshot
    @Published var selectedDownloadVersion: ASRModelVersion
    @Published private(set) var accessibilitySetupState: AccessibilitySetupState = .idle
    @Published private(set) var installCommandCopied = false
    @Published private(set) var downloadCommandCopied = false

    private let requestMicrophoneAccessAction: () -> Void
    private let refreshAction: () -> Void
    private let openSettingsAction: () -> Void
    private let requestAccessibilityAccessAction: () -> Void
    private let openAccessibilitySettingsAction: () -> Void
    private let accessibilityTrustCheck: () -> Bool
    private let relaunchAppAction: () -> Void
    private let startDictationAction: () -> Void
    private let saveOnboardingConfiguration: (OnboardingConfiguration) -> Void

    init(
        snapshot: OnboardingStatusSnapshot,
        requestMicrophoneAccessAction: @escaping () -> Void,
        refreshAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void,
        requestAccessibilityAccessAction: @escaping () -> Void = {
            _ = AccessibilityHelper.ensureTrusted(prompt: true)
        },
        openAccessibilitySettingsAction: @escaping () -> Void = {
            SystemSettingsNavigator.open(.accessibility)
        },
        accessibilityTrustCheck: @escaping () -> Bool = {
            AccessibilityHelper.isTrusted
        },
        relaunchAppAction: @escaping () -> Void,
        saveOnboardingConfiguration: @escaping (OnboardingConfiguration) -> Void = { config in
            config.save()
        },
        startDictationAction: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.selectedDownloadVersion = snapshot.selectedModelVersion
        self.requestMicrophoneAccessAction = requestMicrophoneAccessAction
        self.refreshAction = refreshAction
        self.openSettingsAction = openSettingsAction
        self.requestAccessibilityAccessAction = requestAccessibilityAccessAction
        self.openAccessibilitySettingsAction = openAccessibilitySettingsAction
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.relaunchAppAction = relaunchAppAction
        self.saveOnboardingConfiguration = saveOnboardingConfiguration
        self.startDictationAction = startDictationAction
    }

    func apply(snapshot: OnboardingStatusSnapshot) {
        self.snapshot = snapshot
        if !snapshot.installedModelVersions.contains(selectedDownloadVersion) && snapshot.modelLibraryURL == nil {
            selectedDownloadVersion = snapshot.selectedModelVersion
        }
        if snapshot.accessibilityStatus.isReady {
            accessibilitySetupState = .idle
        }
    }

    func requestMicrophoneAccess() {
        requestMicrophoneAccessAction()
    }

    func requestAccessibilityAccess() {
        accessibilitySetupState = .needsExternalEnable
        var config = OnboardingConfiguration.load()
        config.hasAttemptedAccessibilitySetup = true
        saveOnboardingConfiguration(config)
        requestAccessibilityAccessAction()
        refreshAction()
    }

    func openMicrophoneSettings() {
        SystemSettingsNavigator.open(.microphone)
    }

    func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }

    func confirmAccessibilityEnabled() {
        if accessibilityTrustCheck() {
            accessibilitySetupState = .idle
            refreshAction()
            return
        }
        accessibilitySetupState = .enabledPendingRelaunch
    }

    func relaunchApp() {
        relaunchAppAction()
    }

    func chooseModelFolder() {
        let currentURL = ModelsConfiguration.load().modelLibraryURL
        ModelSetupSupport.chooseModelLibraryFolder(currentURL: currentURL) { [weak self] url in
            guard let self, let url else { return }
            self.applyModelLibraryFolder(url)
        }
    }

    func clearModelFolder() {
        applyModelLibraryFolder(nil)
    }

    func useParentFolderForSelectedRepo() {
        guard let currentURL = snapshot.modelLibraryURL?.standardizedFileURL else { return }
        applyModelLibraryFolder(currentURL.deletingLastPathComponent())
    }

    func openModelFolderInFinder() {
        guard let url = snapshot.modelLibraryURL else { return }
        _ = ModelSetupSupport.openModelLibraryFolder(url)
    }

    func recheck() {
        refreshAction()
    }

    func copyInstallCommand() {
        copyToPasteboard(ModelSetupSupport.huggingFaceInstallCommand)
        installCommandCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.installCommandCopied = false
        }
    }

    func copyDownloadCommand() {
        copyToPasteboard(downloadCommand)
        downloadCommandCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.downloadCommandCopied = false
        }
    }

    func openSettings() {
        openSettingsAction()
    }

    func startDictating() {
        startDictationAction()
    }

    func confirmHotkey() {
        var config = OnboardingConfiguration.load()
        config.hasPickedHotkey = true
        saveOnboardingConfiguration(config)
        refreshAction()
    }

    func selectMicrophone(_ descriptor: MicrophoneDeviceDescriptor) {
        UserDefaults.standard.set(descriptor.uid, forKey: GeneralSettingsKeys.selectedInputUID)
        NotificationCenter.default.post(name: .microphonePriorityDidChange, object: nil)
        refreshAction()
    }

    #if DEBUG
    func resetAllOnboardingState() {
        print("\n[DEBUG] RESETTING ONBOARDING STATE")
        OnboardingConfiguration.reset()
        
        // Provide TCC instructions
        let bundleID = Bundle.main.bundleIdentifier ?? "singhkays.Kalam"
        print("""
        ------------------------------------------------------------
        To fully reset system permissions, run these in Terminal:
        
        tccutil reset Microphone \(bundleID)
        tccutil reset Accessibility \(bundleID)
        ------------------------------------------------------------
        """)
        
        refreshAction()
    }
    #endif

    var downloadCommand: String {
        ModelSetupSupport.downloadCommand(for: selectedDownloadVersion, config: ModelsConfiguration.load())
    }

    var selectedModelRepoFolderVersion: ASRModelVersion? {
        ModelSetupSupport.selectedModelRepoFolderVersion(for: snapshot.modelLibraryURL)
    }

    private func applyModelLibraryFolder(_ folderURL: URL?) {
        do {
            let config = try ModelSetupSupport.applyingModelLibraryFolder(folderURL, to: ModelsConfiguration.load())
            config.save()
            NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
            refreshAction()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to Use Folder"
            alert.runModal()
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: OnboardingFlowController
    let onClose: () -> Void

    #if DEBUG
    @State private var isOptionKeyPressed = false
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    #endif
    
    @State private var isMicrophoneListExpanded: Bool = true
    @State private var isModelCardExpanded: Bool = false

    var body: some View {
        ZStack {
            // Modern Background with Translucency and Noise
            Rectangle()
                .fill(.thickMaterial)
            
            NoiseView()
                .blendMode(.overlay)

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                
                setupWell
                    .padding(.vertical, 8)
                
                footer
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 32) // Reduced since traffic lights are hidden
        }
        .frame(width: 600, height: 800)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var setupWell: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                checklist
                    .padding(.vertical, 20)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
            )

            // Internal Top Shadow
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.18), Color.clear]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .allowsHitTesting(false)

            // Internal Bottom Shadow
            VStack {
                Spacer()
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.18)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 14)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            Text(controller.snapshot.mode.windowTitle)
                .font(.title2.weight(.semibold))

            Text("Kalam runs entirely on your Mac. No audio or text ever leaves this device, ensuring total privacy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            requirementRow(
                icon: "mic.fill",
                title: "Microphone",
                requirement: .microphone,
                status: microphoneDisplayStatus,
                primary: microphonePrimaryAction,
                secondary: controller.snapshot.microphoneStatus.isReady && !isMicrophoneListExpanded ? .init(title: "Change", style: .premium, action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { isMicrophoneListExpanded = true } }) : nil,
                trailingSuccessLabel: !isMicrophoneListExpanded ? controller.snapshot.selectedMicrophoneName : nil
            ) {
                if isMicrophoneListExpanded {
                    microphoneSelectionSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .onAppear {
                // Initial state
                if controller.snapshot.microphoneStatus.isReady {
                    isMicrophoneListExpanded = false
                }
            }
            // Removed automatic onChange collapse - now handled by manual "Confirm"

            requirementRow(
                icon: "hand.raised.fill",
                title: "Accessibility",
                requirement: .accessibility,
                status: accessibilityDisplayStatus,
                primary: accessibilityPrimaryAction,
                secondary: accessibilitySecondaryAction
            )

            requirementRow(
                icon: "keyboard",
                title: "Hotkey",
                requirement: .hotkey,
                status: controller.snapshot.hotkeyStatus,
                primary: hotkeyPrimaryAction,
                secondary: controller.snapshot.hotkeyStatus.isReady ? .init(title: "Change", style: .premium, action: {
                    let defaults = UserDefaults.standard
                    defaults.set(false, forKey: "internal.hasPickedHotkey")
                    controller.recheck()
                }) : nil
            ) {
                if !controller.snapshot.hotkeyStatus.isReady {
                    hotkeySetupSection
                }
            }
            .disabled(!controller.snapshot.accessibilityStatus.isReady)
            .opacity(controller.snapshot.accessibilityStatus.isReady ? 1.0 : 0.5)

            requirementRow(
                icon: "cpu",
                title: "AI Model",
                requirement: .model,
                status: controller.snapshot.modelStatus,
                primary: modelPrimaryAction,
                secondary: modelSecondaryAction,
                trailingSuccessLabel: modelSuccessLabel
            ) {
                if shouldShowModelCard {
                    modelSetupCard
                }
            }
            .disabled(!controller.snapshot.hotkeyStatus.isReady)
            .opacity(controller.snapshot.hotkeyStatus.isReady ? 1.0 : 0.5)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footer: some View {
        VStack(alignment: .center, spacing: 10) {
            if let runtimeMessage = controller.snapshot.runtimePreparationMessage {
                Text(runtimeMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Start Dictating") {
                controller.startDictating()
            }
            .buttonStyle(OnboardingPremiumButtonStyle())
            .disabled(controller.snapshot.completedRequirements < 4)
            .keyboardShortcut(.defaultAction)

            ZStack {
                Text("\(controller.snapshot.completedRequirements) of 4 complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                #if DEBUG
                HStack {
                    Spacer()
                    debugResetButton
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity)
        #if DEBUG
        .onReceive(timer) { _ in
            let isPressed = NSEvent.modifierFlags.contains(.option)
            if isPressed != isOptionKeyPressed {
                isOptionKeyPressed = isPressed
            }
        }
        #endif
    }

    #if DEBUG
    private var debugResetButton: some View {
        Button {
            controller.resetAllOnboardingState()
        } label: {
            Text("Reset (Option+Click)")
                .font(.caption)
                .underline()
        }
        .buttonStyle(.plain)
        .opacity(isOptionKeyPressed ? 0.6 : 0)
        .animation(.easeInOut, value: isOptionKeyPressed)
    }
    #endif

    private var microphoneDisplayStatus: OnboardingRequirementStatus {
        controller.snapshot.microphoneStatus
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
            return .pendingRelaunch(message: "Kalam still can't verify Accessibility access. If the switch is already on, restart Kalam. Otherwise, enable Kalam in System Settings.")
        }
    }

    private var shouldShowModelCard: Bool {
        controller.snapshot.hotkeyStatus.isReady && (!controller.snapshot.modelStatus.isReady || isModelCardExpanded)
    }

    private var modelSuccessLabel: String? {
        guard controller.snapshot.modelStatus.isReady else { return nil }
        return controller.snapshot.selectedModelVersion.displayName
    }

    private var microphonePrimaryAction: OnboardingAction {
        switch controller.snapshot.microphoneStatus {
        case .notDetermined, .actionRequired:
            return .init(title: "Allow", style: .prominent, action: controller.requestMicrophoneAccess)
        case .denied:
            return .init(title: "Open Settings", style: .prominent, action: controller.openMicrophoneSettings)
        case .ready:
            return .init(title: "Allowed", style: .prominent, action: nil)
        case .pendingExternal, .pendingRelaunch, .invalid:
            return .init(title: "Recheck", style: .bordered, action: controller.recheck)
        }
    }

    private var microphoneSecondaryAction: OnboardingAction? {
        switch controller.snapshot.microphoneStatus {
        case .denied:
            return .init(title: "Recheck", style: .bordered, action: controller.recheck)
        default:
            return nil
        }
    }

    private var accessibilityPrimaryAction: OnboardingAction {
        switch accessibilityDisplayStatus {
        case .ready:
            return .init(title: "Granted", style: .prominent, action: nil)
        case .pendingExternal:
            return .init(title: "Open System Settings", style: .prominent, action: controller.openAccessibilitySettings)
        case .pendingRelaunch:
            return .init(title: "Quit & Reopen Kalam", style: .prominent, action: controller.relaunchApp)
        case .denied:
            return .init(title: "Open Settings", style: .prominent, action: controller.openAccessibilitySettings)
        case .notDetermined, .actionRequired, .invalid:
            return .init(title: "Grant Access", style: .prominent, action: controller.requestAccessibilityAccess)
        }
    }

    private var accessibilitySecondaryAction: OnboardingAction? {
        switch accessibilityDisplayStatus {
        case .pendingRelaunch:
            return .init(title: "Open System Settings", style: .bordered, action: controller.openAccessibilitySettings)
        case .denied:
            return .init(title: "Open System Settings", style: .bordered, action: controller.openAccessibilitySettings)
        default:
            return nil
        }
    }

    private var modelPrimaryAction: OnboardingAction {
        if shouldShowModelCard {
            return .init(title: "", style: .prominent, action: nil)
        }
        if controller.snapshot.modelStatus.isReady {
            return .init(title: "Ready", style: .prominent, action: nil)
        }
        return .init(title: "Recheck", style: .bordered, action: controller.recheck)
    }

    private var modelSecondaryAction: OnboardingAction? {
        if controller.snapshot.modelStatus.isReady {
            return .init(title: "Change", style: .premium, action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isModelCardExpanded.toggle()
                }
            })
        }
        return nil
    }

    private var hotkeyPrimaryAction: OnboardingAction {
        if controller.snapshot.hotkeyStatus.isReady {
            return .init(title: "Ready", style: .prominent, action: nil)
        }
        return .init(title: "Confirm", style: .prominent, action: controller.confirmHotkey)
    }

    private var hotkeySecondaryAction: OnboardingAction? {
        if controller.snapshot.hotkeyStatus.isReady {
            return .init(title: "Change", style: .premium, action: {
                // To reset and show the picker again
                var config = OnboardingConfiguration.load()
                config.hasPickedHotkey = false
                controller.confirmHotkey() 
                // Wait, I should probably have a separate method or just update the flag
                // Let's just update the flag and let refresh handle it
                let defaults = UserDefaults.standard
                defaults.set(false, forKey: "internal.hasPickedHotkey")
                controller.recheck()
            })
        }
        return nil
    }

    private var microphoneSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.top, 4)

            if controller.snapshot.microphoneStatus.isReady {
                Text("Select Microphone")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 2)

                VStack(spacing: 6) {
                    ForEach(MicrophoneDeviceService.availableInputDevices()) { device in
                        let isSelected = device.name == controller.snapshot.selectedMicrophoneName

                        Button {
                            controller.selectMicrophone(device)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(isSelected ? Color.green.opacity(0.15) : Color.primary.opacity(0.05))
                                        .frame(width: 28, height: 28)

                                    Image(systemName: isSelected ? "mic.fill" : "mic")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(isSelected ? .green : .secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .primary : .secondary)

                                    if isSelected {
                                        Text("Active Input")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.green)
                                            .textCase(.uppercase)
                                    }
                                }

                                Spacer()

                                if isSelected {
                                    Button {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                            isMicrophoneListExpanded = false
                                        }
                                    } label: {
                                        Text("Confirm")
                                    }
                                    .buttonStyle(OnboardingPremiumButtonStyle(isCompact: true))
                                    .transition(.scale.combined(with: .opacity))
                                } else {
                                    Image(systemName: "circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.quaternary))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(isSelected ? 1.02 : 1.0)
                        .animation(.spring(response: 0.3), value: isSelected)
                    }
                }
            } else {
                Label("You’ll choose a microphone after access is granted.", systemImage: "mic.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 4)
    }

    private var hotkeySetupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activation Mode")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    SetupDropdownField(
                        selection: Binding(
                            get: { PTTHotkeyConfiguration.load().activationMode },
                            set: { mode in
                                var config = PTTHotkeyConfiguration.load()
                                config.activationMode = mode
                                config.save()
                                controller.recheck()
                            }
                        ),
                        options: ActivationMode.allCases,
                        label: { $0.displayName }
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Key Combination")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    SetupDropdownField(
                        selection: Binding(
                            get: { PTTHotkeyConfiguration.load().keyCombination },
                            set: { combo in
                                var config = PTTHotkeyConfiguration.load()
                                config.apply(keyCombination: combo)
                                config.save()
                                controller.recheck()
                            }
                        ),
                        options: KeyCombination.allCases,
                        label: { $0.displayName }
                    )
                }
                .frame(maxWidth: .infinity)
            }
            
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                Text(PTTHotkeyConfiguration.load().displayString)
                    .font(.system(.subheadline, design: .default, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                
                Text("This shortcut triggers dictation while Kalam is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var modelSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.modelSetupPresentationState {
            case .needsFolder:
                ModelAcquisitionPanel(
                    folderURL: controller.snapshot.modelLibraryURL,
                    statusMessage: "Choose where Kalam should store your local speech models.",
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
                    onRecheckCLI: controller.recheck,
                    onCopyDownloadCommand: controller.copyDownloadCommand,
                    onCopyInstallCommand: controller.copyInstallCommand
                )
            case .needsModel:
                ModelAcquisitionPanel(
                    folderURL: controller.snapshot.modelLibraryURL,
                    statusMessage: "No compatible model found in this folder.",
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
                    onRecheckCLI: controller.recheck,
                    onCopyDownloadCommand: controller.copyDownloadCommand,
                    onCopyInstallCommand: controller.copyInstallCommand
                )
            case .repoFolderSelected(_, let selectedRepo, _, _):
                ModelAcquisitionPanel(
                    folderURL: controller.snapshot.modelLibraryURL,
                    statusMessage: "No compatible model found in this folder.",
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
                    selectedRepo: selectedRepo,
                    onUseParentFolder: controller.useParentFolderForSelectedRepo,
                    onRecheckCLI: controller.recheck,
                    onCopyDownloadCommand: controller.copyDownloadCommand,
                    onCopyInstallCommand: controller.copyInstallCommand
                )
            case .ready:
                EmptyView()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func requirementRow<ExtraContent: View>(
        icon: String,
        title: String,
        requirement: OnboardingRequirement,
        status: OnboardingRequirementStatus,
        primary: OnboardingAction,
        secondary: OnboardingAction?,
        trailingSuccessLabel: String? = nil,
        @ViewBuilder extraContent: () -> ExtraContent = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName(for: requirement, status: status))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor(for: requirement, status: status))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(status.message)
                        .font(.subheadline)
                        .foregroundStyle(status.isNotDetermined ? .tertiary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if status.isReady {
                    HStack(spacing: 12) {
                        if let secondary {
                            actionButton(secondary)
                        }

                        if let trailingSuccessLabel {
                            Label(trailingSuccessLabel, systemImage: "checkmark.circle.fill")
                                .font(.footnote.bold())
                                .foregroundStyle(.green)
                        }
                    }
                } else if !primary.title.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        actionButton(primary)

                        if let secondary {
                            actionButton(secondary)
                        }
                    }
                }
            }

            extraContent()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            VStack {
                Divider()
                    .opacity(0.2)
                Spacer()
                Divider()
                    .opacity(0.2)
            }
            .foregroundStyle(borderColor(for: requirement, status: status))
        )
    }

    @ViewBuilder
    private func actionButton(_ action: OnboardingAction) -> some View {
        switch action.style {
        case .prominent:
            Button(action.title) {
                action.action?()
            }
            .buttonStyle(OnboardingPremiumButtonStyle(isCompact: true))
            .disabled(action.action == nil)
        case .bordered:
            Button(action.title) {
                action.action?()
            }
            .buttonStyle(OnboardingGlassButtonStyle())
            .disabled(action.action == nil)
        case .link:
            Button(action.title) {
                action.action?()
            }
            .buttonStyle(.link)
            .disabled(action.action == nil)
        case .premium:
            Button(action.title) {
                action.action?()
            }
            .buttonStyle(OnboardingGlassButtonStyle())
            .disabled(action.action == nil)
        }
    }

    private func iconName(for requirement: OnboardingRequirement, status: OnboardingRequirementStatus) -> String {
        if status.isReady {
            return "checkmark.circle.fill"
        }
        if requirement == .accessibility, case .pendingRelaunch = status {
            return "exclamationmark.triangle.fill"
        }
        if controller.snapshot.mode == .repair && controller.snapshot.brokenRequirements.contains(requirement) {
            return "exclamationmark.triangle.fill"
        }
        switch status {
        case .denied, .invalid:
            return "exclamationmark.triangle.fill"
        case .notDetermined(_):
            switch requirement {
            case .microphone: return "mic.fill"
            case .accessibility: return "hand.raised.fill"
            case .hotkey: return "keyboard"
            case .model: return "cpu"
            }
        default:
            switch requirement {
            case .microphone:
                return "mic.fill"
            case .accessibility:
                return "hand.raised.fill"
            case .hotkey:
                return "keyboard"
            case .model:
                return "cpu"
            }
        }
    }

    private func iconColor(for requirement: OnboardingRequirement, status: OnboardingRequirementStatus) -> Color {
        if status.isReady {
            return .green
        }
        if requirement == .accessibility, case .pendingRelaunch = status {
            return .orange
        }
        if controller.snapshot.mode == .repair && controller.snapshot.brokenRequirements.contains(requirement) {
            return .orange
        }
        switch status {
        case .denied, .invalid:
            return .orange
        case .notDetermined(_):
            return .secondary
        default:
            return .accentColor
        }
    }

    private func borderColor(for requirement: OnboardingRequirement, status: OnboardingRequirementStatus) -> Color {
        if requirement == .accessibility, case .pendingRelaunch = status {
            return Color.orange.opacity(0.35)
        }
        if controller.snapshot.mode == .repair && controller.snapshot.brokenRequirements.contains(requirement) {
            return Color.orange.opacity(0.45)
        }
        switch status {
        case .ready:
            return Color.green.opacity(0.25)
        case .denied, .invalid:
            return Color.orange.opacity(0.35)
        default:
            return Color(nsColor: .separatorColor).opacity(0.45)
        }
    }
}

enum OnboardingActionStyle {
    case prominent
    case bordered
    case link
    case premium
}

struct OnboardingAction {
    let title: String
    let style: OnboardingActionStyle
    let action: (() -> Void)?
}
