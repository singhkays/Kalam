import AppKit
import SwiftUI

// MARK: - Environment signal for GetTheModel dimming (F8 repo guard)

struct IsRepoGuardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isRepoGuard: Bool {
        get { self[IsRepoGuardKey.self] }
        set { self[IsRepoGuardKey.self] = newValue }
    }
}

// MARK: - EngineGetTheModelCard — Option D Setup wizard (Task 2)
//
// One Setup card, three stepped rows. All routing derives from
// `SettingsModel.setupStep` (Task 1); this view adds no state machine.
// Visual truth: kalam-compass-engine-options.html section `#optD`
// (7 D figures: Missing, Step 2, Step 3 live picker, Verified multi,
// Incomplete, Change-folder, Folder-deleted).
//
// Layout (per spec):
//   Header "Setup" trailing `setupStep.headerTrailing`
//     ("N of 3 · ~SIZE" green / "Verified" green / "Incomplete — 3 of 5"
//     warn / "Folder not found" bad).
//   Steps: 28pt badges (number / green check / grey locked), locked steps at
//     55% opacity with one-line subs, completed steps collapsed to one-line
//     summaries, active step expanded with its body. NO popover anywhere.
//   Step 1 "Model folder": path line + `Change` (always available) +
//     `Open in Finder` when the folder exists on disk. First run shows
//     `Choose folder…` primary + `When chosen, path appears here.` hint.
//     No `Clear` (Change covers switching; bookmark removal stays DEBUG-only).
//     Deleted-folder branch shows the not-found copy (`bad` header tone comes
//     from `setupStep`). Bookmark-unresolvable renders the same Step-1-active
//     route (modelFolder falls back to the default path).
//   Step 2 "Install the download tool": `brew install hf` paper well + `Copy`
//     secondary + `I've installed the tool` primary while active (sets the
//     Task 1 flag, advancing the wizard) + `When done, open a new Terminal
//     window.` hint. HF CLI is named once, in the detail line only.
    //   Step 3 "Download model": three selection cards over
    //     `availableModelVersions` (title = `pickerLabel`, receipt =
    //     per-version `derivedModelLine`, trailing check-ring marks the
    //     choice; no lead-in), full shell-quoted well from
    //     `model.downloadCommand`, `Copy download command` as the only primary,
//     quiet `Reveal in Finder` / `Check again` (`Check again` → rescanEngine).
//     v3 alone offers an `All 25 languages` disclosure (NVIDIA order; hidden
//     for v2/110M; collapses on version switch). Incomplete body: chip grid
//     from `modelFileManifest` + `Copy the command again` primary + S5/S6
//     quiet rows.
//   Repo guard: orange callout + `Use Parent Folder Instead` at the Setup
//     bottom (moved here from EngineWhereItLivesCard — that file is deleted;
//     `IsRepoGuardKey` moved with it, above).
// Styling roles: rowTopEdge / diveRowPad / cardRadius; 44px primaries.
// Copy: NSPasteboard.general.clearContents + setString (existing helper).

struct EngineGetTheModelCard: View {
    @Bindable var model: SettingsModel
    @State private var showAllLanguages = false
    @State private var copiedInstallCommand = false
    @State private var copiedDownloadCommand = false
    @State private var revealFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header("Setup", trailing: model.setupStep.headerTrailing, trailingColor: setupHeaderColor)

            stepRow(number: 1, title: "Model folder", state: step1State, trailingChange: step1State == .complete) {
                if step1State == .active {
                    step1Body
                } else {
                    Text(step1Summary)
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            stepRow(number: 2, title: "Install the download tool", state: step2State, trailingChange: false) {
                if step2State == .active {
                    step2Body
                } else if step2State == .complete {
                    Text(step2Summary)
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                } else {
                    Text("Choose a folder first.")
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                }
            }

            stepRow(number: 3, title: "Download model", state: step3State, trailingChange: false) {
                if step3State == .active {
                    step3Body
                } else if step3State == .complete {
                    Text(step3Summary)
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                } else {
                    Text(step3LockedSub)
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                }
            }

            if model.setupStep.isRepoGuard {
                repoGuardCallout
            }
        }
        .background(Color.kPanel, in: RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .stroke(Color.kHair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        // Bug A: wizard-state swaps (missing/incomplete/verified) apply
        // instantly — rows above the Step-3 well stay pinned, no drift.
        .animation(.none, value: model.setupStep)
        .onChange(of: model.selectedDownloadVersion) { _, _ in
            showAllLanguages = false
            copiedInstallCommand = false
            copiedDownloadCommand = false
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    /// D figures render the `N of 3 · ~SIZE` trailing in green (`.st`
    /// default), warn for Incomplete, bad for Folder-not-found.
    private var setupHeaderColor: Color {
        switch model.setupStep.headerTone {
        case .ok, .neutral:
            return Color.kGreen
        case .warn:
            return Color.kWarn
        case .bad:
            return Color.kBad
        }
    }

    // MARK: - Step states (from setupStep only)

    private var step1State: WizardStepState {
        model.setupStep.activeStep == .folder ? .active : .complete
    }

    private var step2State: WizardStepState {
        if model.setupStep.activeStep == .tool { return .active }
        return model.setupStep.isToolLocked ? .locked : .complete
    }

    private var step3State: WizardStepState {
        if model.setupStep.activeStep == .download { return .active }
        if model.setupStep.activeStep == .done { return .complete }
        return .locked
    }

    // MARK: - Step row shell

    private func stepRow<Content: View>(
        number: Int,
        title: String,
        state: WizardStepState,
        trailingChange: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepBadge(number: number, state: state)
                .accessibilityLabel("Step \(number) of 3, \(title): \(state.voiceWord)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.styleRowTitle)
                    .compassTracking(SettingsType.trackRowTitle)
                    .foregroundStyle(state == .locked ? Color.kInk3 : Color.kInk)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if trailingChange {
                Button("Change") {
                    Task { await model.chooseModelFolder() }
                }
                .buttonStyle(WizardSmallButtonStyle())
                .accessibilityLabel("Change model folder")
                .padding(.top, 1)
            }
        }
        .padding(SettingsLayout.diveRowPad)
        .rowTopEdge(first: number == 1)
        .background(state == .active ? Color.kStepWash : Color.clear)
        .opacity(state == .locked ? 0.55 : 1)
    }

    private func stepBadge(number: Int, state: WizardStepState) -> some View {
        ZStack {
            Circle()
                .fill(state == .complete ? AnyShapeStyle(Color.green.opacity(0.18)) : AnyShapeStyle(.quaternary))
                .frame(width: 28, height: 28)
            if state == .complete {
                Image(systemName: "checkmark")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
            } else {
                Text("\(number)")
                    .font(.footnote.bold())
                    .foregroundStyle(state == .locked ? .tertiary : .secondary)
            }
        }
        // Fixed badge box: numeral-vs-check glyph metrics must never alter
        // the badge frame (Bug A — Step-3 title row stays pinned).
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    // MARK: - Step 1: Model folder

    private var displayPath: String {
        let home = NSHomeDirectory()
        let path = model.modelFolder.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Collapsed Step-1 summary: the folder path; verified-multi appends the
    /// model count (D-Verified-multi: `~/Models — 2 models`).
    private var step1Summary: String {
        if case .verified = model.engine, model.activeInstalledVersions.count >= 2 {
            return "\(displayPath) — \(model.activeInstalledVersions.count) models"
        }
        return displayPath
    }

    private var step1ActiveSub: String {
        if model.isFolderMissingOnDisk {
            return "\(displayPath) — not found. It may have been moved, renamed, or deleted."
        }
        if model.setupStep.isRepoGuard {
            return displayPath
        }
        return "Choose where Kalam keeps speech models on this Mac. Nothing is downloaded by Kalam itself."
    }

    @ViewBuilder
    private var step1Body: some View {
        Text(step1ActiveSub)
            .font(SettingsType.styleRowDetail)
            .foregroundStyle(Color.kInk2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
        if model.isFolderMissingOnDisk {
            HStack(spacing: 8) {
                Button("Choose folder…") {
                    Task { await model.chooseModelFolder() }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Choose model folder")
                Button("Reveal in Finder") {
                    revealInFinder(model.modelFolder)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Reveal model folder in Finder")
            }
            revealFallbackHint
        } else if model.setupStep.isRepoGuard {
            HStack(spacing: 8) {
                Button("Change") {
                    Task { await model.chooseModelFolder() }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Change model folder")
                Button("Open in Finder") {
                    revealInFinder(model.modelFolder)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Open model folder in Finder")
            }
            revealFallbackHint
        } else {
            HStack(spacing: 8) {
                Button("Choose folder…") {
                    Task { await model.chooseModelFolder() }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Choose model folder")
                Text("When chosen, path appears here.")
                    .font(SettingsType.stylePathMono)
                    .foregroundStyle(Color.kInk3)
            }
        }
    }

    // MARK: - Step 2: Install the download tool

    /// Collapsed Step-2 summary (D-Step 3 key state vs D-Verified).
    private var step2Summary: String {
        model.setupStep.activeStep == .done
            ? "Confirmed"
            : "Confirmed — ready for the download step."
    }

    private var step2Body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (
                Text("One-time setup. Kalam uses models from Hugging Face — this installs the ")
                    + Text("hf").font(SettingsType.stylePathMono)
                    + Text(" tool so you can download the speech model.")
            )
            .font(SettingsType.styleRowDetail)
            .foregroundStyle(Color.kInk2)
            .fixedSize(horizontal: false, vertical: true)
            commandWell(model.installCommand)
                .padding(.top, 10)
            HStack(spacing: 8) {
                Button(copiedInstallCommand ? "Copied ✓" : "Copy") {
                    copyInstallCommand()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Copy install command")
                Text("When done, open a new Terminal window.")
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
            }
            .padding(.top, 8)
            Button("I've installed the tool") {
                model.hasConfirmedHFCLIInstall = true
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .frame(minHeight: 44)
            .accessibilityLabel("I've installed the tool")
            .padding(.top, 10)
        }
    }

    // MARK: - Step 3: Download model

    /// Locked Step-3 sub depends on which predecessor is incomplete
    /// (D-Missing vs D-Step 2 figures).
    private var step3LockedSub: String {
        !model.setupStep.isToolLocked
            ? "Install the tool first."
            : "Pick how you dictate — the command follows."
    }

    /// Collapsed Step-3 summary (verified only): multi names the switch
    /// below; single names the model on disk.
    private var step3Summary: String {
        let count = model.activeInstalledVersions.count
        if count >= 2 {
            return "\(count) models on disk — switch below."
        }
        return "\(shortModelName(for: model.selectedDownloadVersion)) — on disk."
    }

    @ViewBuilder
    private var step3Body: some View {
        if model.engine == .incomplete {
            incompleteBody
        } else {
            downloadPickerBody
        }
    }

    // MARK: Step 3 fresh — selection cards + well

    private var downloadPickerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                ForEach(model.availableModelVersions, id: \.self) { v in
                    modelVersionCard(for: v)
                }
            }
            .padding(.top, 8)
            // Bug A: the collapsed disclosure button row reserves identical
            // space for every version (hidden placeholder when not v3), so the
            // well sits at the same Y for v2/v3/110M. Only the expanded grid
            // (v3, explicit user toggle) reflows content below it.
            languageDisclosure
                .padding(.leading, 24)
                .opacity(model.selectedDownloadVersion == .v3 ? 1 : 0)
                .allowsHitTesting(model.selectedDownloadVersion == .v3)
                .accessibilityHidden(model.selectedDownloadVersion != .v3)
            commandWell(model.downloadCommand)
                .padding(.top, 10)
            HStack(spacing: 8) {
                Button(copiedDownloadCommand ? "Copied ✓" : "Copy download command") {
                    copyDownloadCommand()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Copy download command")
                Button("Reveal in Finder") {
                    revealInFinder(model.modelFolder)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Reveal model folder in Finder")
                Button("Check again") {
                    model.rescanEngine()
                }
                .buttonStyle(WizardSmallButtonStyle())
                .accessibilityLabel("Check again")
            }
            .padding(.top, 8)
            revealFallbackHint
            Text("Run this after the tool is installed. Re-run if interrupted — it skips files already on disk.")
                .font(SettingsFont.body(11))
                .foregroundStyle(Color.kInk3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        // Bug A: selection-driven swaps (picker version, well text) apply
        // instantly — no implicit animation may drift the title row or the
        // rows above the well. The disclosure toggle stays explicit state.
        .animation(.none, value: model.selectedDownloadVersion)
    }

    /// Step-3 selection card (C4): title = `pickerLabel`, receipt =
    /// per-version `derivedModelLine`, trailing 18px check-ring. Tap routes
    /// through the existing `selectedDownloadVersion` binding (header size +
    /// well swap re-derive; no routing changes).
    private func modelVersionCard(for version: ASRModelVersion) -> some View {
        let isSelected = version == model.selectedDownloadVersion
        return Button {
            model.selectedDownloadVersion = version
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pickerLabel(for: version))
                        .font(SettingsFont.body(12.5, weight: 600))
                        .foregroundStyle(Color.kInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(derivedModelLine(for: version))
                        .font(SettingsFont.mono(10.5))
                        .foregroundStyle(Color.kInk3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // Fixed 18px check-ring box in ALL states: the ring, the
                // check glyph, and the ZStack itself all carry the same
                // fixed frame, so filled+check vs empty never differ in
                // intrinsic size (state-dependent geometry fix — emphasis
                // via color/fill only).
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.kGreen : Color.clear)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.kGreen : Color.kHair, lineWidth: 1)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            // Floor 48 (not 44): two-line content already measures ~48, and the
            // floor pins every card there in every state, so no per-version
            // measurement quirk can ever reopen a height split. Floor-only:
            // larger Dynamic Type still grows past it, so nothing clips.
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(isSelected ? Color.kCardWash : Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.kCardEdge : Color.kHair2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // Selection applies instantly: no transition on card frames, so a
        // tap never leaves mid-flight geometry in screenshots (the picker
        // body already pins `.animation(.none)` on the version value).
        .animation(.none, value: isSelected)
        .accessibilityLabel(version.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Human answers (card titles). Card receipts and accessibility labels
    /// keep the full `ASRModelVersion.displayName` identity via
    /// `derivedModelLine(for:)` (short name + files + size) and explicit labels.
    private func pickerLabel(for version: ASRModelVersion) -> String {
        switch version {
        case .v2:
            return "English only — most accurate"
        case .v3:
            return "25 European languages"
        case .tdtCtc110m:
            return "English, smaller download"
        }
    }

    private func shortModelName(for version: ASRModelVersion) -> String {
        switch version {
        case .v2:
            return "Parakeet TDT v2"
        case .v3:
            return "Parakeet TDT v3"
        case .tdtCtc110m:
            return "Parakeet TDT-CTC 110M"
        }
    }

    /// Per-version card receipt
    /// (`Parakeet TDT v2 · 5 files · ~450 MB · Apple Neural Engine`).
    /// File count comes from the live manifest when available, else the
    /// per-version default (v2/v3: 5, 110M: 4).
    private func derivedModelLine(for version: ASRModelVersion) -> String {
        "\(shortModelName(for: version)) · \(fileCount(for: version)) files · \(version.modelSize) · Apple Neural Engine"
    }

    /// Selected-version receipt (delegates to the per-version function).
    private var derivedModelLine: String {
        derivedModelLine(for: model.selectedDownloadVersion)
    }

    private func fileCount(for version: ASRModelVersion) -> Int {
        let manifest = model.modelFileManifest(for: version)
        if !manifest.isEmpty { return manifest.count }
        switch version {
        case .v2, .v3:
            return 5
        case .tdtCtc110m:
            return 4
        }
    }

    // MARK: v3-only language disclosure (progressive disclosure, not decoration)

    /// Full v3 scope in NVIDIA card order.
    private static let v3Languages = [
        "Bulgarian", "Croatian", "Czech", "Danish", "Dutch", "English",
        "Estonian", "Finnish", "French", "German", "Greek", "Hungarian",
        "Italian", "Latvian", "Lithuanian", "Maltese", "Polish", "Portuguese",
        "Romanian", "Slovak", "Slovenian", "Spanish", "Swedish", "Russian",
        "Ukrainian",
    ]

    private var languageDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showAllLanguages.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAllLanguages ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("All 25 languages")
                        .font(SettingsFont.mono(11, weight: 600))
                }
                .foregroundStyle(Color.kInk3)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAllLanguages ? "All 25 languages, expanded" : "All 25 languages, collapsed")
            if showAllLanguages {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                    ForEach(Self.v3Languages, id: \.self) { language in
                        Text(language)
                            .font(SettingsFont.mono(10.5))
                            .foregroundStyle(Color.kInk2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(Color.kWell)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.kHair, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityLabel(language)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Step 3 incomplete — manifest chips + recovery rows

    private var incompleteManifest: [ASRModelFileEntry] {
        model.modelFileManifest(for: model.selectedDownloadVersion)
    }

    private var incompleteTitle: String {
        let total = incompleteManifest.count
        let present = incompleteManifest.filter(\.isPresent).count
        guard total > 0 else { return "Folder found, files incomplete" }
        return "Folder found, \(present) of \(total) files short"
    }

    private var incompleteBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(incompleteTitle)
                .font(SettingsFont.mono(11, weight: 600))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
                .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(incompleteManifest) { entry in
                    SetupFileChip(name: entry.name, present: entry.isPresent)
                }
            }
            .padding(.top, 8)
            commandWell(model.downloadCommand)
                .padding(.top, 10)
            HStack(spacing: 8) {
                Button(copiedDownloadCommand ? "Copied ✓" : "Copy the command again") {
                    copyDownloadCommand()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Copy the command again")
                Button("Reveal in Finder") {
                    revealInFinder(model.modelFolder)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Reveal model folder in Finder")
                Button("Check again") {
                    model.rescanEngine()
                }
                .buttonStyle(WizardSmallButtonStyle())
                .accessibilityLabel("Check again")
            }
            .padding(.top, 8)
            revealFallbackHint
            // S5 slot: tool missing on PATH — guidance points back to Step 2.
            VStack(alignment: .leading, spacing: 2) {
                Text("zsh: command not found: hf")
                    .font(SettingsType.stylePathMono)
                    .foregroundStyle(Color.kInk2)
                    .textSelection(.enabled)
                Text("Install the tool first (Step 2), open a new Terminal, then re-run.")
                    .font(SettingsFont.body(11))
                    .foregroundStyle(Color.kInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            // S6 slot: disk space readout with a smaller-model offer.
            HStack(spacing: 8) {
                Text(model.engineDiskSpace.summary)
                    .font(SettingsType.stylePathMono)
                    .foregroundStyle(Color.kInk2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.selectedDownloadVersion != .tdtCtc110m {
                    Button("Use 110M (\(ASRModelVersion.tdtCtc110m.modelSize))") {
                        model.selectedDownloadVersion = .tdtCtc110m
                    }
                    .buttonStyle(WizardSmallButtonStyle())
                    .accessibilityLabel("Use 110M, smaller download")
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Repo guard (moved from EngineWhereItLivesCard; Task 3 deletes that file)

    private var repoGuardTitle: String {
        let last = model.modelFolder.lastPathComponent
        if let version = ASRModelVersion.allCases.first(where: { $0.repositoryFolderName == last }) {
            switch version {
            case .v2:
                return "This folder is already the Parakeet TDT v2 repo."
            case .v3:
                return "This folder is already the Parakeet TDT v3 repo."
            case .tdtCtc110m:
                return "This folder is already the Parakeet TDT-CTC 110M repo."
            }
        }
        return "This folder is already a model repo."
    }

    private var repoGuardCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    // Mockup `.repoWarn .icon`: #FF9500 light / #E5A54B dark.
                    .fill(Color.adaptive(light: "FF9500", dark: "E5A54B"))
                    .frame(width: 22, height: 22)
                Text("!")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.adaptive(light: "FFFFFF", dark: "181816"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(repoGuardTitle)
                    .font(SettingsFont.body(12.5, weight: SettingsType.wMock600))
                    .foregroundStyle(Color.kWarn)
                Text("Choose the parent folder so Kalam can manage the library consistently.")
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use Parent Folder Instead") {
                    useParentFolder()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .padding(.top, 8)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .background(Color.kRepoWarn)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.kWarnWashEdge, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private func useParentFolder() {
        let parent = model.modelFolder.deletingLastPathComponent()
        // Live path: persist via ModelsConfiguration + bookmark (same as chooseModelFolder inner)
        // InMemory path: use test helper if available (cast via protocol extension check)
        if let store = modelValueAsInMemoryStore() {
            store.applyModelFolderForTesting(parent, presence: .missing)
            return
        }
        // Live fallback — attempt to apply via ModelsConfiguration directly (does not need open panel)
        // This mirrors ModelSetupSupport.applyingModelLibraryFolder but without UI.
        let defaults = UserDefaults.standard
        let config = ModelsConfiguration.load(from: defaults)
        do {
            let updated = try ModelSetupSupport.applyingModelLibraryFolder(parent, to: config)
            updated.save(to: defaults)
            NotificationCenter.default.post(name: .modelsConfigurationDidChange, object: nil)
            model.rescanEngine()
        } catch {
            // Fallback: open chooser pre-filled at parent
            Task { await model.chooseModelFolder() }
        }
        // Also reveal parent in Finder for confidence
        revealInFinder(parent)
    }

    /// Best-effort downcast to InMemory for preview/test; avoids importing test-only code in production.
    private func modelValueAsInMemoryStore() -> InMemorySettingsStore? {
        // Access via Mirror because `store` is private in SettingsModel
        let mirror = Mirror(reflecting: model)
        for child in mirror.children {
            if let store = child.value as? InMemorySettingsStore {
                return store
            }
            // Also check inside Any? wrappers
            let innerMirror = Mirror(reflecting: child.value)
            for inner in innerMirror.children {
                if let store = inner.value as? InMemorySettingsStore {
                    return store
                }
            }
        }
        return nil
    }

    // MARK: - Shared pieces

    /// Inline mono well (paper bg per `#optD` `.monowell`).
    private func commandWell(_ command: String) -> some View {
        Text(command)
            .font(SettingsType.stylePathMono)
            .foregroundStyle(Color.kInk)
            .lineSpacing(11 * 0.55)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 11)
            .background(Color.kPaper)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.kHair2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .textSelection(.enabled)
            .accessibilityLabel(command)
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// Transient `Copied ✓` swap mirroring the onboarding command rows
    /// (`OnboardingFlow.copyInstallCommand/copyDownloadCommand` + the D-Step 2
    /// mockup's dual `Copy/Copied ✓` states): the pasteboard write is
    /// instant, the label confirms it for 2 s, then resets. A picker switch
    /// clears it via the `selectedDownloadVersion` onChange above.
    private func copyInstallCommand() {
        copyToPasteboard(model.installCommand)
        copiedInstallCommand = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { copiedInstallCommand = false }
        }
    }

    private func copyDownloadCommand() {
        copyToPasteboard(model.downloadCommand)
        copiedDownloadCommand = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { copiedDownloadCommand = false }
        }
    }

    /// Reveal holding the same security-scoped access the availability check
    /// uses (`ModelsConfiguration.withSecurityScopedAccess`). Opening a
    /// manually-picked folder (e.g. `/Users/k/Developer`) without it strands
    /// the user on a raw system permission dialog. If access genuinely cannot
    /// be obtained, stay inside our UI — quiet inline hint + path on the
    /// clipboard — instead of the system error. No entitlement changes.
    private func revealInFinder(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        if NSWorkspace.shared.open(url) {
            revealFailed = false
        } else {
            copyToPasteboard(url.path)
            revealFailed = true
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { revealFailed = false }
            }
        }
    }

    @ViewBuilder
    private var revealFallbackHint: some View {
        if revealFailed {
            Text("Finder couldn't open this folder — its path is on the clipboard.")
                .font(SettingsFont.body(11))
                .foregroundStyle(Color.kInk3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ title: String, trailing: String? = nil, trailingColor: Color? = nil) -> some View {
        HStack {
            Text(title)
                .font(SettingsType.styleCardHeaderLabel)
                .compassTracking(SettingsType.trackCardHeaderLabel)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(SettingsType.styleCardHeaderState)
                    .compassTracking(SettingsType.trackMonoState)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingColor ?? Color.kGreen)
            }
        }
        .padding(SettingsLayout.diveCardHeaderPad)
    }
}

// MARK: - WizardStepState

private enum WizardStepState {
    case active
    case complete
    case locked

    var voiceWord: String {
        switch self {
        case .active:
            return "active"
        case .complete:
            return "complete"
        case .locked:
            return "locked"
        }
    }
}

// MARK: - WizardSmallButtonStyle — quiet small secondary (`.bsec.sm`: 24px, 11.5px)

private struct WizardSmallButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsFont.body(11.5))
            .foregroundStyle(Color.kInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(configuration.isPressed || hovering ? Color.kWell : Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.radiusButton)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: - SetupFileChip — 22px file presence chip (ok green / miss bad)

private struct SetupFileChip: View {
    let name: String
    let present: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: present ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(present ? Color.kGreen : Color.kBad)
            Text(name)
                .font(SettingsFont.mono(10))
                .foregroundStyle(present ? Color.kGreen : Color.kBad)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(present ? Color.kChipWash : Color.kBadSoft)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(present ? Color.kChipEdge : Color.kChipMissEdge, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("\(name) \(present ? "present" : "missing")")
    }
}

// MARK: - Previews — 7 D states (Task 1 fixtures)

#Preview("D — Missing (Step 1 active)") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupMissingDefault()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Step 2 active") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupFolderChosen()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Step 2 repo-guard variant") {
    // Task 1 routing sends a repo-folder pick to Step 1 active (folder not
    // complete), so the guard callout renders with Step 1 expanded — the
    // mock's collapsed-Step-1 + callout combo is unreachable from state alone.
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupRepoGuard()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Step 3 (v2)") {
    EngineGetTheModelCard(model: DPreview.step3(version: .v2))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Step 3 (v3)") {
    EngineGetTheModelCard(model: DPreview.step3(version: .v3))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Step 3 (110M)") {
    EngineGetTheModelCard(model: DPreview.step3(version: .tdtCtc110m))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Verified single") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupVerifiedSingle()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Verified multi") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupVerifiedMulti()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Incomplete") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupIncomplete()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Change folder (Step 3 re-active)") {
    EngineGetTheModelCard(model: DPreview.changeFolder())
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("D — Folder deleted") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureSetupFolderDeleted()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

/// Preview-only builders for wizard states that combine a Task 1 fixture
/// with a picker/flag change (no backing-file changes).
@MainActor
private enum DPreview {
    static func step3(version: ASRModelVersion) -> SettingsModel {
        let store = InMemorySettingsStore.fixtureSetupFolderChosen()
        store.hasConfirmedHFCLIInstall = true
        let model = SettingsModel(store: store)
        model.selectedDownloadVersion = version
        return model
    }

    static func changeFolder() -> SettingsModel {
        let store = InMemorySettingsStore()
        store.applyModelFolderForTesting(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NewModels"),
            presence: .missing
        )
        store.hasConfirmedHFCLIInstall = true
        return SettingsModel(store: store)
    }
}
