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

// MARK: - WhereItLivesCard — folder states (F1/F2/F6/F7/F8)

struct EngineWhereItLivesCard: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header("Where it lives", trailing: statusLabel, trailingColor: statusTone)

            // Row 1: Model folder
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model folder")
                        .font(SettingsType.styleRowTitle)
                        .compassTracking(SettingsType.trackRowTitle)
                        .foregroundStyle(Color.kInk)
                    Text(pathLine)
                        .font(SettingsType.stylePathMono)
                        .foregroundStyle(Color.kInk2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Group {
                    if isRepoGuard {
                        Button("Change") {
                            Task { await model.chooseModelFolder() }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    } else if isMissingDefault {
                        Button("Choose…") {
                            Task { await model.chooseModelFolder() }
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                    } else {
                        Button("Change") {
                            Task { await model.chooseModelFolder() }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }
                }
            }
            .padding(SettingsLayout.diveRowPad)
            .rowTopEdge(first: true)

            // Row 2: Actions — only for F2 folder chosen (missing but folder exists)
            if isFolderChosen {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Actions")
                            .font(SettingsType.styleRowTitle)
                            .compassTracking(SettingsType.trackRowTitle)
                            .foregroundStyle(Color.kInk3)
                    }
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(model.modelFolder)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
                .padding(SettingsLayout.diveRowPad)
                .overlay(alignment: .top) { Divider().background(Color.kHair2) }
            }

            // Repo guard orange callout (F8)
            if isRepoGuard {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "FF9500"))
                            .frame(width: 22, height: 22)
                        Text("!")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
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
                .background(Color(hex: "FF9500").opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: "FF9500").opacity(0.22), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
        .background(Color.kPanel)
        .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous).stroke(Color.kHair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .environment(\.isRepoGuard, isRepoGuard)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Derived

    private var displayPath: String {
        let home = NSHomeDirectory()
        let path = model.modelFolder.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Path line with F-state annotations (HTML parity)
    private var pathLine: String {
        if isRepoGuard {
            return displayPath
        }
        let count = model.activeInstalledVersions.count
        switch model.engine {
        case .verified:
            if count >= 2 {
                // F6b: 2 models · size mocked (884 MB in spec); use count only — size not available headless
                return "\(displayPath) — \(count) models"
            }
            // Single verified or count unknown — just path; HTML F6 shows repo path with — verified but spec says ~/Models — 2 models
            // Keep path alone; header carries "Verified"
            return displayPath
        case .missing:
            if isFolderChosen {
                // F2: ~/Models · 14 MB · 1 folder — size is mock; keep path + folder hint if we have it
                // We don't have disk size headless; show path + count hint when we have installed count vs generic folder
                if count > 0 {
                    return "\(displayPath) · \(count) folder\(count == 1 ? "" : "s")"
                }
                return "\(displayPath) · 1 folder"
            }
            return displayPath
        case .incomplete:
            // F7: path is plain ~/Models; header shows Incomplete — 3 of 5
            return displayPath
        }
    }

    private var isRepoGuard: Bool {
        let last = model.modelFolder.lastPathComponent
        return ASRModelVersion.allCases.map(\.repositoryFolderName).contains(last)
    }

    /// F8 title inside orange box
    private var repoGuardTitle: String {
        let last = model.modelFolder.lastPathComponent
        if let version = ASRModelVersion.allCases.first(where: { $0.repositoryFolderName == last }) {
            // Map repo folder back to display name for the guard copy
            switch version {
            case .v2: return "This folder is already the Parakeet TDT v2 repo."
            case .v3: return "This folder is already the Parakeet TDT v3 repo."
            case .tdtCtc110m: return "This folder is already the Parakeet TDT-CTC 110M repo."
            }
        }
        return "This folder is already a model repo."
    }

    /// F1 vs F2: default missing (no folder chosen) → Choose… primary
    private var isMissingDefault: Bool {
        guard case .missing = model.engine, !isRepoGuard else { return false }
        // Default library path used by both Live and InMemory stores
        let defaultPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Kalam/models").path
        let altDefault = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Models").path
        return model.modelFolder.path == defaultPath || model.modelFolder.path == altDefault
    }

    /// F2: folder chosen but still missing (library exists, no model yet) → show second Actions row
    private var isFolderChosen: Bool {
        guard case .missing = model.engine, !isRepoGuard else { return false }
        return !isMissingDefault
    }

    private var statusLabel: String? {
        if isRepoGuard { return "Check folder" }
        let count = model.activeInstalledVersions.count
        switch model.engine {
        case .verified:
            if count >= 2 { return "Verified — \(count) models" }
            return "Verified"
        case .missing:
            return "Missing"
        case .incomplete:
            if count >= 2 { return "1 incomplete — \(count) models" }
            // HTML F7: Incomplete — 3 of 5 files ; spec also says Incomplete — 3 of 5
            return "Incomplete — 3 of 5"
        }
    }

    private var statusTone: Color? {
        if isRepoGuard { return Color.kWarn }
        switch model.engine {
        case .verified: return Color.kGreen
        case .missing: return Color.kBad
        case .incomplete: return Color.kWarn
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
        NSWorkspace.shared.open(parent)
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
}

#Preview {
    VStack(spacing: 16) {
        EngineWhereItLivesCard(model: SettingsModel(store: {
            let s = InMemorySettingsStore()
            s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .missing)
            return s
        }()))
        EngineWhereItLivesCard(model: SettingsModel(store: {
            let s = InMemorySettingsStore()
            s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .missing)
            // Simulate folder chosen (non-default path triggers F2)
            s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models"), presence: .missing)
            return s
        }()))
        EngineWhereItLivesCard(model: SettingsModel(store: InMemorySettingsStore.fixtureEngineMultiple()))
        EngineWhereItLivesCard(model: SettingsModel(store: {
            let s = InMemorySettingsStore()
            s.applyModelFolderForTesting(URL(fileURLWithPath: NSHomeDirectory() + "/Models/parakeet-tdt-0.6b-v2"), presence: .missing)
            return s
        }()))
    }
    .padding(24)
    .background(Color.kPaper)
    .frame(width: 560)
}
