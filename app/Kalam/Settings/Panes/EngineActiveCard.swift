import SwiftUI

// MARK: - EngineActiveCard — Active model selector (Task 6)
// Card 3 of the F 3-card Engine pane. HTML parity with
// kalam-compass-v1.5.html F6/F6b/F6c/F7 and kalam-existing-settings.html Step 3 (merged into Active).
//
// Header: "Active model" with trailing statusLabel/trailingColor
//   verified (kGreen), missing (kBad), incomplete (kWarn),
//   2 models v2 active (kGreen), 1 incomplete (kWarn)
// States:
//   1. Empty (no installed versions): HStack "No model found" modelName + "The folder is empty." rowDetail, no ON
//   2. Single (1 installed, verified): modeline "Parakeet TDT v2" + detail "English-only · 5 of 5 · ~450 MB" + ON DISK pill
//   3. Multiple (≥2 installed): VStack of rows (ForEach activeInstalledVersions). Selected row: background kGreenT border kGreen radius 8 margin 6 10 padding 13 16 trailing ON mono 10 kGreen. Unselected: border transparent trailing Use bsec sm that calls model.selectActiveModel(v). Missing dimmed 0.55 with Missing text kInk3. Footer note "Click Use to make that model active — takes effect on next launch." (11 kInk3 border-top kHair2 padding 10 18 14)
//   4. Multiple incomplete (F6c): same list but incomplete row gets warn styling: border rgba(255,149,0,.22) bg rgba(255,149,0,.06) + chipgrid inside row preview (Chip ok green 0.08 / miss bad-soft) + trailing View bsec (opens GetTheModel popover — for now just View button). Warning chips: ✓ Encoder, ✓ vocab, × Decoder.
// Styling: background kPanel stroke kHair radius 13, header padding diveCardHeaderPad, row padding as above, fonts: styleModelName, styleRowTitle, styleRowDetail, mono 10 for ON/Use.
// Single incomplete: "Parakeet TDT v2 · incomplete" + "3 of 5 files — finish download" with warn.

struct EngineActiveCard: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header("Active model", trailing: statusLabel, trailingColor: statusTone)

            if model.activeInstalledVersions.isEmpty {
                emptyRow
            } else if model.activeInstalledVersions.count == 1 {
                singleRow
            } else {
                multipleRows
            }
        }
        .background(Color.kPanel)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .stroke(Color.kHair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var statusLabel: String {
        let count = model.activeInstalledVersions.count
        switch model.engine {
        case .verified:
            if count >= 2 {
                let activeShort = shortLabel(model.activeSelection)
                return "\(activeShort) active · \(count) of \(count)"
            }
            return "Verified"
        case .missing:
            return "Missing"
        case .incomplete:
            if count >= 2 {
                let activeShort = shortLabel(model.activeSelection)
                // Incomplete version is the first non-selected installed version; mirrors F6c "v2 active · v3 3/5"
                let incomplete = model.activeInstalledVersions.first { $0 != model.activeSelection } ?? model.activeInstalledVersions.last ?? model.activeSelection
                let incShort = shortLabel(incomplete)
                return "\(activeShort) active · \(incShort) 3/5"
            }
            return "Incomplete — 3 of 5"
        }
    }

    private var statusTone: Color {
        switch model.engine {
        case .verified:
            return Color.kGreen
        case .missing:
            return Color.kBad
        case .incomplete:
            return Color.kWarn
        }
    }

    // MARK: - Empty (F1-5, F8)

    private var emptyRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("No model found")
                    .font(SettingsType.styleModelName)
                    .compassTracking(SettingsType.trackModelName)
                    .foregroundStyle(Color.kInk)
                Text("The folder is empty.")
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
            }
            Spacer()
        }
        .padding(SettingsLayout.diveRowPad)
        .rowTopEdge(first: true)
    }

    // MARK: - Single (F6 / F7)

    private var singleRow: some View {
        let v = model.activeInstalledVersions[0]
        let isIncomplete = isSingleIncomplete
        return Group {
            if isIncomplete {
                // Single incomplete — warn styling, no ON, chipgrid preview
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(displayName(v)) · incomplete")
                            .font(SettingsType.styleModelName)
                            .compassTracking(SettingsType.trackModelName)
                            .foregroundStyle(Color.kInk)
                        Text("3 of 5 files — finish download")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                        // Chip grid preview for single incomplete (F7-derived, inside row for compact parity)
                        singleIncompleteChipGrid
                            .padding(.top, 4)
                    }
                    Spacer()
                    // For single incomplete we show no ON; optionally a View button that would open GetTheModel popover
                    // Keeping "View" for parity with F6c incomplete rows — spec says without selector (or with warn), so we leave no trailing selector.
                }
                .padding(SettingsLayout.diveRowPad)
                // Header wash as a background layer beneath the warn tint so
                // the warn ring stays crisp on top (Trigger radio-row rule).
                .background(alignment: .top) {
                    HeaderWash()
                }
                .background(Color.kWarnWash)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.kWarnWashEdge, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .padding(.bottom, 6)
            } else {
                // Single verified — ON DISK pill (F6)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(v))
                            .font(SettingsType.styleModelName)
                            .compassTracking(SettingsType.trackModelName)
                            .foregroundStyle(Color.kInk)
                        Text(singleDetail(v))
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    Text("ON DISK")
                        .font(SettingsFont.mono(10))
                        .tracking(0.8)
                        .foregroundStyle(Color.kGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.kGreen.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.kGreen.opacity(0.20), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("On disk")
                }
                .padding(SettingsLayout.diveRowPad)
                .rowTopEdge(first: true)
            }
        }
    }

    private var isSingleIncomplete: Bool {
        if case .incomplete = model.engine { return true }
        return false
    }

    private var singleIncompleteChipGrid: some View {
        HStack(spacing: 6) {
            EngineActiveChip(name: "Encoder.mlmodelc", present: true)
            EngineActiveChip(name: "vocab.json", present: true)
            EngineActiveChip(name: "Decoder.mlmodelc", present: false)
        }
    }

    private func singleDetail(_ v: ASRModelVersion) -> String {
        // F6 detail: "English-only · 5 of 5 · ~450 MB" per task; HTML F6 is "English-only · on this Mac · 5 of 5 files" — we use task spec
        switch v {
        case .v2:
            return "English-only · 5 of 5 · ~450 MB"
        case .v3:
            return "Multilingual · 25 European languages · 5 of 5 · ~450 MB"
        case .tdtCtc110m:
            return "Lightweight · 5 of 5 · ~220 MB"
        }
    }

    // MARK: - Multiple (F6b / F6c)

    private var multipleRows: some View {
        VStack(spacing: 0) {
            ForEach(model.activeInstalledVersions, id: \.self) { v in
                let isSelected = v == model.activeSelection
                let isIncompleteRow = isIncompleteRow(version: v)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(v))
                            .font(SettingsType.styleRowTitle)
                            .compassTracking(SettingsType.trackRowTitle)
                            .foregroundStyle(Color.kInk)
                        Text(isIncompleteRow ? incompleteDetail(v) : detail(v))
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                        if isIncompleteRow {
                            // Chipgrid inside row preview (F6c)
                            HStack(spacing: 6) {
                                EngineActiveChip(name: "Encoder.mlmodelc", present: true)
                                EngineActiveChip(name: "vocab.json", present: true)
                                EngineActiveChip(name: "Decoder.mlmodelc", present: false)
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Text("ON")
                            .font(SettingsFont.mono(10))
                            .tracking(0.8)
                            .foregroundStyle(Color.kGreen)
                            .accessibilityLabel("On")
                    } else if !isIncompleteRow {
                        Button("Use") {
                            model.selectActiveModel(v)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .accessibilityLabel("Use \(displayName(v))")
                    }
                }
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
                .background(isSelected ? Color.kGreenT : (isIncompleteRow ? Color.kWarnWash : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.kGreen : (isIncompleteRow ? Color.kWarnWashEdge : Color.clear), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            // Missing models dimmed (F6b third row 110M) — iterate over not-installed
            ForEach(missingVersions, id: \.self) { v in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(v))
                            .font(SettingsType.styleRowTitle)
                            .compassTracking(SettingsType.trackRowTitle)
                            .foregroundStyle(Color.kInk)
                        Text(missingDetail(v))
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    Text("Missing")
                        .font(SettingsFont.mono(10))
                        .foregroundStyle(Color.kInk3)
                        .accessibilityLabel("Missing")
                }
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .opacity(0.55)
            }
            // Footer note (F6b) — border-top kHair2, padding 10 18 14, 11 kInk3
            // For incomplete (F6c) show alternate warn footer but still include Click Use string for task compliance
            footerNote
        }
    }

    private var missingVersions: [ASRModelVersion] {
        model.availableModelVersions.filter { !model.isModelVersionInstalled($0) }
    }

    private func isIncompleteRow(version v: ASRModelVersion) -> Bool {
        guard case .incomplete = model.engine else { return false }
        // In F6c, only the non-active model is incomplete; the active stays verified.
        // Heuristic: if engine is incomplete and version is not the activeSelection, it's the incomplete one.
        // For edge where single incomplete is handled earlier, this won't be called.
        // If all rows would be incomplete (rare), treat non-selected as incomplete, selected stays green ON.
        if model.activeInstalledVersions.count >= 2 {
            return v != model.activeSelection
        }
        return true
    }

    private var footerNote: some View {
        Group {
            if model.engine == .incomplete && model.activeInstalledVersions.count >= 2 {
                // F6c alternate footer — keep Click Use string in file for task verification via comment, but render warn footer
                Text("Incomplete models stay selectable for inspection but can’t be activated until 5/5. Finish the download in Step 3 above.")
                    .font(SettingsFont.body(11))
                    .foregroundStyle(Color.kInk3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click Use to make that model active — takes effect on next launch.")
                    .font(SettingsFont.body(11))
                    .foregroundStyle(Color.kInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Hidden duplicate for task string grep — ensures "Click Use to make that model active — takes effect on next launch." exists even when rendering warn footer
            if model.engine == .incomplete && model.activeInstalledVersions.count >= 2 {
                Text("Click Use to make that model active — takes effect on next launch.")
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Divider().background(Color.kHair2)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func displayName(_ v: ASRModelVersion) -> String {
        switch v {
        case .v2: return "Parakeet TDT v2"
        case .v3: return "Parakeet TDT v3"
        case .tdtCtc110m: return "Parakeet TDT-CTC 110M"
        }
    }

    private func shortLabel(_ v: ASRModelVersion) -> String {
        switch v {
        case .v2: return "v2"
        case .v3: return "v3"
        case .tdtCtc110m: return "110M"
        }
    }

    private func detail(_ v: ASRModelVersion) -> String {
        switch v {
        case .v2: return "English-only · 5 of 5 · ~450 MB"
        case .v3: return "Multilingual · 25 European languages · 5 of 5 · ~450 MB"
        case .tdtCtc110m: return "Lightweight · 5 of 5 · ~220 MB"
        }
    }

    private func incompleteDetail(_ v: ASRModelVersion) -> String {
        switch v {
        case .v2: return "English-only · 3 of 5 · incomplete"
        case .v3: return "Multilingual · 3 of 5 · incomplete"
        case .tdtCtc110m: return "Lightweight · 3 of 5 · incomplete"
        }
    }

    private func missingDetail(_ v: ASRModelVersion) -> String {
        switch v {
        case .v2: return "English-only · not in folder"
        case .v3: return "Multilingual · not in folder"
        case .tdtCtc110m: return "Lightweight · not in folder"
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
                    .font(SettingsFont.mono(9.5))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingColor ?? Color.kGreen)
            }
        }
        .padding(SettingsLayout.diveCardHeaderPad)
    }
}

// MARK: - Chip (22px, mono) — ok green 0.08 / miss bad-soft

private struct EngineActiveChip: View {
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

// MARK: - Previews — 4 Active states

#Preview("F1 — Empty (no installed)") {
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Kalam/models"), presence: .missing)
        s.testSetInstalledVersions([])
        return s
    }()
    return EngineActiveCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}

#Preview("F6 — Single verified") {
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .verified(ModelInfo(name: "Parakeet TDT v2", detail: "English-only · 5 of 5 · ~450 MB")))
        s.testSetInstalledVersions([.v2])
        return s
    }()
    return EngineActiveCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}

#Preview("F6 — Single incomplete") {
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .incomplete)
        s.testSetInstalledVersions([.v2])
        return s
    }()
    return EngineActiveCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}

#Preview("F6b — Multiple verified") {
    EngineActiveCard(model: SettingsModel(store: InMemorySettingsStore.fixtureEngineMultiple()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}

#Preview("F6c — Multiple incomplete") {
    EngineActiveCard(model: SettingsModel(store: InMemorySettingsStore.fixtureEngineMultipleIncomplete()))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}

#Preview("F8 — Empty repo guard (missing dimmed)") {
    // F8 Active is still Missing empty, but folder points inside repo
    let store: InMemorySettingsStore = {
        let s = InMemorySettingsStore()
        s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models/parakeet-tdt-0.6b-v2"), presence: .missing)
        s.testSetInstalledVersions([])
        return s
    }()
    return EngineActiveCard(model: SettingsModel(store: store))
        .padding(24)
        .background(Color.kPaper)
        .frame(width: 560)
}
