import AppKit
import SwiftUI

// MARK: - EngineGetTheModelCard — F popover + picker (Task 5)
//
// Card 2 of the F 3-card Engine pane. HTML parity with
// kalam-compass-v1.5.html F states, kalam-compass-engine-c3-refinements.html
// and kalam-existing-settings.html Step 2.
//
// Layout (per spec):
//   Header "Get the model" (trailing only when Verified/Incomplete)
//   Row 1 Install:  title "Install the download tool" + detail "Hugging Face CLI — runs once in Terminal."
//                  + View/Hide (Hide tint kWell when open) + Copy command
//                  popover anchored to Hide via overlay .bottomTrailing offset y:12 right:28 width:560 notch right:135
//                  popover content: title "Install command — Hugging Face CLI", well "brew install hf" (#F1F0EA), dismiss hint
//   Row 2 Download: title "Download model" + selChip (Menu of availableModelVersions, check on selectedDownloadVersion)
//                  + View/Hide + Copy. Picker before command (selChip in row, well in popover)
//                  popover: title "Download command — <version>", well = model.downloadCommand (full hf download … --local-dir)
//                  when engine .incomplete, popover shows chipGrid above well (✓ Preprocessor/Encoder/JointDecision + × Decoder/vocab)
//   Verified: rows show green check "Installed ✓"/"Confirmed" and no View/Copy
//   Repo guard (EnvironmentValues.isRepoGuard): dim rows opacity 0.55, disable View
//   Styling: HStack with rowTopEdge(first:true) on first row, divider kHair2 on second,
//            background kPanel stroke kHair radius 13, bsec sm (Hide kWell), selChip mono 11.5 padding 4/10 radius 8
//   Copy: NSPasteboard.general.clearContents(); setString(command, forType: .string)
//   Picker: Menu ForEach(availableModelVersions) Button sets model.selectedDownloadVersion = v
//   Card height stable: popover via .overlay (no row growth)

struct EngineGetTheModelCard: View {
    @Bindable var model: SettingsModel
    @Environment(\.isRepoGuard) private var isRepoGuard
    @State private var showInstall = false
    @State private var showDownload = false

    var body: some View {
        VStack(spacing: 0) {
            header("Get the model", trailing: headerTrailing, trailingColor: headerTrailingColor)

            installRow
            downloadRow
        }
        .background(Color.kPanel, in: RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .stroke(Color.kHair, lineWidth: 1)
        )
        .onExitCommand {
            if showInstall { showInstall = false }
            if showDownload { showDownload = false }
        }
        // Outside tap dismiss — cheap card-level handler (tapping the card outside the popover).
        // Popover itself consumes its own taps via .onTapGesture {} so it doesn't bubble.
        .contentShape(Rectangle())
        .onTapGesture {
            // If a popover is open, tapping the card background (outside popover) dismisses.
            // This is a best-effort "click outside" without a window-level monitor; Esc also works.
            if showInstall || showDownload {
                // Only dismiss if tap is not on the popover (popover handles its own tap).
                // SwiftUI hit-testing makes the popover the frontmost, so a tap on popover won't reach here.
                // A tap on the card chrome will.
                showInstall = false
                showDownload = false
            }
        }
    }

    // MARK: - Header

    private var headerTrailing: String? {
        switch model.engine {
        case .verified:
            return "Verified"
        case .incomplete:
            return "Incomplete"
        case .missing:
            return nil
        }
    }

    private var headerTrailingColor: Color? {
        switch model.engine {
        case .verified:
            return Color.kGreen
        case .incomplete:
            return Color.kWarn
        case .missing:
            return nil
        }
    }

    private var isVerified: Bool {
        if case .verified = model.engine { return true }
        return false
    }

    private var isIncomplete: Bool {
        if case .incomplete = model.engine { return true }
        return false
    }

    // MARK: - Rows

    private var installRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Install the download tool")
                    .font(SettingsType.styleRowTitle)
                    .compassTracking(SettingsType.trackRowTitle)
                    .foregroundStyle(Color.kInk)
                Text("Hugging Face CLI — runs once in Terminal.")
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
            }
            Spacer()
            if isVerified {
                verifiedBadge(text: "Installed ✓")
            } else {
                HStack(spacing: 8) {
                    viewHideButton(isActive: showInstall, isDisabled: isRepoGuard) {
                        guard !isRepoGuard else { return }
                        withAnimation(SettingsLayout.hoverAnim) {
                            let willShow = !showInstall
                            showInstall = willShow
                            if willShow { showDownload = false }
                        }
                    }
                    .anchorPreference(key: ViewButtonAnchorKey.self, value: .bounds, transform: { $0 })
                    copyButton {
                        copyToPasteboard(model.installCommand)
                    }
                    .opacity(isRepoGuard ? 0.55 : 1)
                    .disabled(false)
                }
            }
        }
        .padding(SettingsLayout.diveRowPad)
        .rowTopEdge(first: true)
        .opacity(isRepoGuard ? 0.55 : 1)
        .overlayPreferenceValue(ViewButtonAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showInstall && !isVerified && !isRepoGuard, let a = anchor {
                    let rect = proxy[a]
                    let popoverWidth: CGFloat = 560
                    let rowFrame = proxy.frame(in: .local)
                    // Popover right:28 from row trailing, top 12 below button (HTML: top calc(100%+12) right:28)
                    let popoverCenterX = rowFrame.maxX - 28 - popoverWidth / 2
                    let popoverCenterY = rect.maxY + 12 + 90 // 90 ≈ half popover height (180/2), so top = button bottom +12
                    Color.clear
                        .frame(width: popoverWidth, height: 180)
                        .overlay(
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Install command — Hugging Face CLI")
                                    .font(SettingsFont.mono(10))
                                    .tracking(0.9)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Color.kInk3)
                                    .padding(.bottom, 8)
                                EnginePopoverWell(command: model.installCommand)
                                Text("Click outside or press Esc to dismiss.")
                                    .font(SettingsFont.body(11))
                                    .foregroundStyle(Color.kInk3)
                                    .padding(.top, 10)
                            }
                            .padding(14)
                            .frame(width: popoverWidth)
                            .background(Color.kPanel)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.kHair))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .background(EnginePopoverNotch(), alignment: .topTrailing)
                        )
                        .position(x: popoverCenterX, y: popoverCenterY)
                        .allowsHitTesting(true)
                        .onTapGesture {} // consume
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var downloadRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Download model")
                    .font(SettingsType.styleRowTitle)
                    .compassTracking(SettingsType.trackRowTitle)
                    .foregroundStyle(Color.kInk)
                // SelChip lives in the row (picker before command). Dim + disable when verified or repo guard.
                if isVerified {
                    // When verified, show a quiet detail instead of the picker — the model is already on disk.
                    Text(model.selectedDownloadVersion.displayName)
                        .font(SettingsFont.mono(11.5))
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                } else {
                    selChip
                }
            }
            Spacer()
            if isVerified {
                verifiedBadge(text: "Confirmed")
            } else {
                HStack(spacing: 8) {
                    viewHideButton(isActive: showDownload, isDisabled: isRepoGuard) {
                        guard !isRepoGuard else { return }
                        withAnimation(SettingsLayout.hoverAnim) {
                            let willShow = !showDownload
                            showDownload = willShow
                            if willShow { showInstall = false }
                        }
                    }
                    .anchorPreference(key: ViewButtonAnchorKey.self, value: .bounds, transform: { $0 })
                    copyButton {
                        copyToPasteboard(model.downloadCommand)
                    }
                    .opacity(isRepoGuard ? 0.55 : 1)
                }
            }
        }
        .padding(SettingsLayout.diveRowPad)
        .overlay(alignment: .top) {
            Divider().background(Color.kHair2)
        }
        .opacity(isRepoGuard ? 0.55 : 1)
        .overlayPreferenceValue(ViewButtonAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showDownload && !isVerified && !isRepoGuard, let a = anchor {
                    let rect = proxy[a]
                    let popoverWidth: CGFloat = 560
                    let rowFrame = proxy.frame(in: .local)
                    let popoverCenterX = rowFrame.maxX - 28 - popoverWidth / 2
                    let popoverCenterY = rect.maxY + 12 + 90
                    Color.clear
                        .frame(width: popoverWidth, height: 180)
                        .overlay(
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Download command — \(model.selectedDownloadVersion.displayName)")
                                    .font(SettingsFont.mono(10))
                                    .tracking(0.9)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Color.kInk3)
                                    .padding(.bottom, 8)
                                if isIncomplete {
                                    incompleteChipGrid
                                        .padding(.bottom, 10)
                                }
                                EnginePopoverWell(command: model.downloadCommand)
                                Text("Click outside or press Esc to dismiss.")
                                    .font(SettingsFont.body(11))
                                    .foregroundStyle(Color.kInk3)
                                    .padding(.top, 10)
                            }
                            .padding(14)
                            .frame(width: popoverWidth)
                            .background(Color.kPanel)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.kHair))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .background(EnginePopoverNotch(), alignment: .topTrailing)
                        )
                        .position(x: popoverCenterX, y: popoverCenterY)
                        .allowsHitTesting(true)
                        .onTapGesture {}
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Download popover (with chipGrid when incomplete)

    private var downloadPopover: some View {
        // Title uses selected version's displayName; well is full hf download … --local-dir
        // When engine == .incomplete, chipGrid sits above the well (F7).
        let title = "Download command — \(model.selectedDownloadVersion.displayName)"
        return EnginePopover(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                if isIncomplete {
                    incompleteChipGrid
                }
                EnginePopoverWell(command: model.downloadCommand)
            }
        }
    }

    private var incompleteChipGrid: some View {
        // F7 — chipGrid inside Download popover when incomplete.
        // Hardcoded preview chips (static) per spec:  ✓ Preprocessor/Encoder/JointDecision + × Decoder/vocab
        // In a live incomplete build this would be driven by modelFileManifest; for headless preview we keep static.
        VStack(alignment: .leading, spacing: 6) {
            Text("Model files — 3 of 5 present")
                .font(SettingsFont.mono(10))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ChipView(name: "Preprocessor.mlmodelc", present: true)
                ChipView(name: "Encoder.mlmodelc", present: true)
                ChipView(name: "JointDecision.mlmodelc", present: true)
                ChipView(name: "Decoder.mlmodelc", present: false)
                ChipView(name: "vocab.json", present: false)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - SelChip

    private var selChip: some View {
        Menu {
            ForEach(model.availableModelVersions, id: \.self) { v in
                Button {
                    model.selectedDownloadVersion = v
                } label: {
                    HStack {
                        Text(v.displayName)
                        if v == model.selectedDownloadVersion {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedDownloadVersion.displayName)
                    .font(SettingsFont.mono(11.5))
                    .foregroundStyle(Color.kInk)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.kInk3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.kHair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isRepoGuard || isVerified)
        .opacity((isRepoGuard || isVerified) ? 0.55 : 1)
        .accessibilityLabel("Model version \(model.selectedDownloadVersion.displayName)")
    }

    // MARK: - Small buttons

    private func viewHideButton(isActive: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(isActive ? "Hide" : "View command", action: action)
            .font(SettingsFont.body(12.5))
            .foregroundStyle(Color.kInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(isActive ? Color.kWell : Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.radiusButton, style: .continuous)
                    .stroke(Color.kHair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton, style: .continuous))
            .opacity(isDisabled ? 0.55 : 1)
            .disabled(isDisabled)
            .accessibilityLabel(isActive ? "Hide command" : "View command")
    }

    private func copyButton(action: @escaping () -> Void) -> some View {
        Button("Copy command", action: action)
            .font(SettingsFont.body(12.5))
            .foregroundStyle(Color.kInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.radiusButton, style: .continuous)
                    .stroke(Color.kHair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton, style: .continuous))
            .accessibilityLabel("Copy command")
    }

    private func verifiedBadge(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.kGreen)
            Text(text)
                .font(SettingsFont.mono(10))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.kGreen.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.kGreen.opacity(0.20), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(text)
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
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
                    .font(SettingsFont.mono(9.5))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingColor ?? Color.kGreen)
            }
        }
        .padding(SettingsLayout.diveCardHeaderPad)
    }
}

// MARK: - ChipView — 22px file presence chip

private struct ChipView: View {
    let name: String
    let present: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: present ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(present ? Color.kGreen : Color(hex: "FF9500"))
            Text(name)
                .font(SettingsFont.mono(10))
                .foregroundStyle(present ? Color.kGreen : Color.kWarn)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(present ? Color.kGreen.opacity(0.07) : Color(hex: "FF9500").opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(present ? Color.kGreen.opacity(0.20) : Color(hex: "FF9500").opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("\(name) \(present ? "present" : "missing")")
    }
}

// MARK: - Previews

#Preview("F1 — collapsed (missing, default folder)") {
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Kalam/models"), presence: .missing)
        return s
    }()
    return EngineGetTheModelCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("F3 — Install popover open") {
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .missing)
        return s
    }()
    return EngineGetTheModelCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640, height: 420)
}

#Preview("F4 — Download popover (v3 selected)") {
    let model: SettingsModel = {
        let s: InMemorySettingsStore = {
            let s = InMemorySettingsStore()
            s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .missing)
            return s
        }()
        let m = SettingsModel(store: s)
        m.selectedDownloadVersion = .v3
        return m
    }()
    return EngineGetTheModelCard(model: model)
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("F6 — Verified (checks, no View)") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureEngineMultiple()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640)
}

#Preview("F7 — Incomplete (chipGrid in Download popover)") {
    EngineGetTheModelCard(model: SettingsModel(store: InMemorySettingsStore.fixtureEngineMultipleIncomplete()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 640, height: 520)
}

#Preview("F8 — Repo guard (dimmed)") {
    EngineGetTheModelCard(model: SettingsModel(store: {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models/parakeet-tdt-0.6b-v2"), presence: .missing)
        return s
    }()))
    .environment(\.isRepoGuard, true)
    .padding(24)
    .background(Color.kPaper)
    .frame(width: 640)
}

private struct ViewButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}
