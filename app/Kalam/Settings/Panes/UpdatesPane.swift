import AppKit
import SwiftUI

struct UpdatesPane: View {
    @Bindable var model: SettingsModel
    @State private var isCopyingDiagnostics = false
    @State private var diagnosticsCopied = false
    @State private var diagnosticsFailed = false
    @State private var diagnosticsCopyGeneration = 0

    var body: some View {
            VStack(alignment: .leading, spacing: 0) {
            Text("Maintenance")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(model.versionString)
                    .font(SettingsType.styleUpdatesFigure).compassTracking(SettingsType.trackUpdatesFigure)
                    .foregroundStyle(Color.kInk)
                Text("Universal build for Apple silicon and Intel.")
                    .font(SettingsFont.body(13))
                    .foregroundStyle(Color.kInk2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .padding(.top, 12)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for a newer release")
                        .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                    Text("Opens the release page in your browser without sending anything from this Mac.")
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                }
                Spacer()
                Button("View latest release") {
                    NSWorkspace.shared.open(model.releaseURL)
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
            }
            .padding(SettingsLayout.diveRowPad)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 16)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy diagnostics for support")
                        .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                    Text("Replaces your clipboard with a privacy-safe bundle (versions, settings, counts, recent log lines). Nothing leaves this Mac until you paste it.")
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .fixedSize(horizontal: false, vertical: true)
                    if diagnosticsCopied {
                        Text("Copied to the clipboard.")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kGreen)
                    }
                    if diagnosticsFailed {
                        Text("Couldn't gather diagnostics — try again.")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kBad)
                    }
                }
                Spacer()
                Button(isCopyingDiagnostics ? "Copying…" : (diagnosticsCopied ? "Copied" : "Copy diagnostics")) {
                    copyDiagnostics()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(isCopyingDiagnostics)
            }
            .padding(SettingsLayout.diveRowPad)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Why there is no auto update")
                        .font(SettingsType.styleCardHeaderLabel)
                        .compassTracking(SettingsType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(SettingsLayout.diveCardHeaderPad)
                // Header casts its own shadow into its bottom padding
                // (v1.3.8): matches the Setup / Active model / Key headers.
                .overlay(alignment: .bottom) {
                    HeaderWash()
                }

                Text("Kalam makes no outbound requests for telemetry, crash reports, license checks, or update pings. Audio and transcripts stay on this Mac, which is simpler to guarantee with no network code in the app. Release notes open in the browser so you can read what changed before you replace the build.")
                    .font(SettingsFont.body(12.5))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)
        }
    }

    // MARK: - Diagnostics export

    @MainActor
    private func copyDiagnostics() {
        guard !isCopyingDiagnostics else { return }
        isCopyingDiagnostics = true
        diagnosticsCopied = false
        diagnosticsFailed = false
        diagnosticsCopyGeneration += 1
        let generation = diagnosticsCopyGeneration
        // Actor-inherited task (same posture as the transcription task, never
        // detached): input gathering stays on the main actor, the store read
        // hops to the reader actor, then we resume here for the pasteboard
        // write and confirmation.
        Task {
            var inputs = gatherDiagnosticsInputs(model: model)
            let reader: any DiagnosticsLogReader = OSLogStoreDiagnosticsReader()
            inputs.logExcerpt = await reader.fetchExcerpt(
                subsystem: DiagnosticsLogSubsystem.name,
                maxLines: DiagnosticsSnapshotLimits.maxExcerptLines,
                maxCharacters: DiagnosticsSnapshotLimits.maxExcerptCharacters
            )
            let bundle = DiagnosticsSnapshot.makeBundle(from: inputs)
            // Intentional destructive clipboard write (unlike paste injection,
            // which restores): the row copy above says so explicitly. Never log
            // bundle content (SECURITY.md privacy policy).
            NSPasteboard.general.clearContents()
            let ok = NSPasteboard.general.setString(bundle, forType: .string)
            isCopyingDiagnostics = false
            if ok {
                diagnosticsCopied = true
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if generation == diagnosticsCopyGeneration {
                    diagnosticsCopied = false
                }
            } else {
                diagnosticsFailed = true
            }
        }
    }
}

// MARK: - Diagnostics input gathering (main actor)

/// Fills the snapshot inputs from live state. Counts/flags/versions only —
/// never triggers, replacements, device names, UIDs, paths, or chord text.
@MainActor
private func gatherDiagnosticsInputs(model: SettingsModel) -> DiagnosticsSnapshotInputs {
    let defaults = UserDefaults.standard
    let entries = CustomDictionaryManager.shared.entries
    let manifest = model.modelFileManifest(for: model.activeSelection)
    let engineState: DiagnosticsEngineState = {
        switch model.engine {
        case .verified: return .verified
        case .missing: return .missing
        case .incomplete: return .incomplete
        }
    }()
    let micPermission: DiagnosticsMicPermission = {
        switch model.microphonePermission {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }()
    let connected = model.connectedMicrophone
    let caps = RuntimeCapabilities.current()
    // Last-failure summaries plus last-dictation numbers have no live store
    // yet: the fields ship in the bundle (allowlisted) and render "none" /
    // "not-recorded" until a last-error ring buffer wires them. Recent
    // failures remain visible via the log excerpt window.
    return DiagnosticsSnapshotInputs(
        appName: KalamAppName.current,
        appVersion: model.versionString,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        modelVersion: model.activeSelection.rawValue,
        verboseAudio: defaults.bool(forKey: KalamDiagnosticFlags.verboseAudioKey),
        // Keys mirror AppDelegate.LatencyTuningOptions (private): keep in sync.
        stageTimingEnabled: defaults.bool(forKey: "internal.latency.enableStageTiming"),
        startStageTimingEnabled: defaults.bool(forKey: "internal.latency.startStageTiming"),
        duckEnabled: defaults.bool(forKey: "duckEnabled"),
        muteOtherAudio: model.muteOtherAudio,
        cleanupEnabled: model.cleanupEnabled,
        dictionaryTotal: entries.count,
        dictionaryEnabled: entries.filter(\.isEnabled).count,
        engineState: engineState,
        manifestPresent: manifest.filter(\.isPresent).count,
        manifestTotal: manifest.count,
        lastASRInitError: nil,
        lastAudioError: nil,
        lastPasteError: nil,
        micPermission: micPermission,
        usableInputCount: model.microphones.filter(\.isConnected).count,
        connectedTransport: connected.map(\.transportTag),
        connectedChannels: connected.map { Int($0.inputChannels) },
        removeFillers: model.removeFillers,
        handleBacktracks: model.handleBacktracks,
        formatLists: model.formatLists,
        normalizePunctuation: model.normalizePunctuation,
        grammarPass: model.grammarPass.rawValue,
        itnEnabled: model.cleanupEnabled,
        itnAvailable: NemoTextProcessing.isAvailable,
        itnVersion: NemoTextProcessing.version,
        activationMode: model.activation.rawValue,
        hotkeySet: model.hotkey != nil,
        lastTrimmedMs: nil,
        lastAsrMs: nil,
        lastReplacements: nil,
        gateFallback: nil,
        gateReason: nil,
        axTrusted: AccessibilityHelper.isTrusted,
        sandbox: caps.appSandbox,
        audioInput: caps.audioInput,
        accessibilityEntitlement: caps.accessibility,
        outgoingNetwork: caps.outgoingNetworkClient,
        logExcerpt: .lines([])
    )
}
