import SwiftUI

struct EngineActiveCard: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let rows = model.activeModelRows
        let present = rows.filter { $0.status != .missing }
        VStack(spacing: 0) {
            header(for: present)
            if present.isEmpty {
                emptyRow
            } else if let row = present.first, present.count == 1, row.status == .active {
                singleActiveRow(row)
            } else {
                ForEach(present) { row in
                    modelRow(row)
                }
                if present.count > 1 {
                    ForEach(rows.filter { $0.status == .missing }) { row in
                        modelRow(row)
                    }
                }
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

    private func header(for rows: [ActiveModelRow]) -> some View {
        let status = headerStatus(for: rows)
        return HStack {
            Text("Active model")
                .font(SettingsType.styleCardHeaderLabel)
                .compassTracking(SettingsType.trackCardHeaderLabel)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            Spacer()
            Text(status.label)
                .font(SettingsFont.mono(9.5))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(status.color)
        }
        .padding(SettingsLayout.diveCardHeaderPad)
    }

    private func headerStatus(for rows: [ActiveModelRow]) -> (label: String, color: Color) {
        if let active = rows.first(where: { $0.status == .active }) {
            let label = rows.count == 1 ? "Verified" : "\(shortLabel(active.version)) active"
            return (label, Color.kGreen)
        }
        if rows.contains(where: { $0.status == .installed }) {
            return ("Model available", Color.kInk3)
        }
        if let row = rows.first, rows.count == 1 {
            return ("\(shortLabel(row.version)) · \(row.presentFiles) of \(row.totalFiles) files", Color.kWarn)
        }
        return rows.isEmpty ? ("Missing", Color.kBad) : ("Incomplete", Color.kWarn)
    }

    private var emptyRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("No model found")
                    .font(SettingsType.styleModelName)
                    .compassTracking(SettingsType.trackModelName)
                    .foregroundStyle(Color.kInk)
                Text("Choose a model folder or finish setup above.")
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
            }
            Spacer()
        }
        .padding(SettingsLayout.diveRowPad)
        .rowTopEdge(first: true)
    }

    private func singleActiveRow(_ row: ActiveModelRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(row.version))
                    .font(SettingsType.styleModelName)
                    .compassTracking(SettingsType.trackModelName)
                    .foregroundStyle(Color.kInk)
                Text(detail(row))
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

    private func modelRow(_ row: ActiveModelRow) -> some View {
        let isActive = row.status == .active
        let isIncomplete = row.status == .incomplete
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(row.version))
                    .font(SettingsType.styleRowTitle)
                    .compassTracking(SettingsType.trackRowTitle)
                    .foregroundStyle(Color.kInk)
                Text(detail(row))
                    .font(SettingsType.styleRowDetail)
                    .foregroundStyle(Color.kInk2)
                if isIncomplete {
                    Text("Missing files: \(row.missingFiles.joined(separator: ", "))")
                        .font(SettingsType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isActive {
                Text("ON")
                    .font(SettingsFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(Color.kGreen)
                    .accessibilityLabel("On")
            } else if row.status == .installed {
                Button("Use") {
                    model.selectActiveModel(row.version)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel("Use \(displayName(row.version))")
            } else if row.status == .missing {
                Text("Missing")
                    .font(SettingsFont.mono(10))
                    .foregroundStyle(Color.kInk3)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
        .background(isActive ? Color.kGreenT : (isIncomplete ? Color.kWarnWash : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Color.kGreen : (isIncomplete ? Color.kWarnWashEdge : Color.clear), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(row.status == .missing ? 0.55 : 1)
    }

    private func displayName(_ version: ASRModelVersion) -> String {
        switch version {
        case .v2: return "Parakeet TDT v2"
        case .v3: return "Parakeet TDT v3"
        case .tdtCtc110m: return "Parakeet TDT-CTC 110M"
        }
    }

    private func shortLabel(_ version: ASRModelVersion) -> String {
        switch version {
        case .v2: return "v2"
        case .v3: return "v3"
        case .tdtCtc110m: return "110M"
        }
    }

    private func detail(_ row: ActiveModelRow) -> String {
        switch row.status {
        case .incomplete:
            return "\(row.presentFiles) of \(row.totalFiles) files · incomplete"
        case .missing:
            return "Model folder missing or empty"
        case .active, .installed:
            let kind: String
            switch row.version {
            case .v2: kind = "English-only"
            case .v3: kind = "Multilingual · 25 European languages"
            case .tdtCtc110m: kind = "Lightweight"
            }
            return "\(kind) · \(row.presentFiles) of \(row.totalFiles) · \(row.version.modelSize)"
        }
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
        s.testSetManifest(presentCount: ModelSetupSupport.requiredModelFiles(for: .v2).count, totalFor: .v2)
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
        s.testSetManifest(presentCount: 3, totalFor: .v2)
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
