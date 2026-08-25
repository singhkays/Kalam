import AppKit
import SwiftUI

struct EnginePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The engine")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
                .accessibilityAddTraits(.isHeader)

            (
                Text("The engine ").font(SettingsType.styleDiveDisplay).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("lives on your disk.").font(SettingsType.styleDiveDisplayItalic).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(SettingsType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            // Install location
            VStack(spacing: 0) {
                header("Install location")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model folder")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        Text(displayPath)
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    Group {
                        if isVerified {
                            Button("Choose…") {
                                Task { await model.chooseModelFolder() }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                        } else {
                            Button("Choose…") {
                                Task { await model.chooseModelFolder() }
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                        }
                    }
                }
                .padding(SettingsLayout.diveRowPad)
                .rowTopEdge(first: true)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy to install")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        Text(model.installCommand)
                            .font(SettingsType.stylePathMono)
                            .foregroundStyle(Color.kInk2)
                            .lineLimit(2)
                    }
                    Spacer()
                    Group {
                        if isVerified {
                            Button("Copy command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.installCommand, forType: .string)
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                        } else {
                            Button("Copy command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.installCommand, forType: .string)
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                        }
                    }
                }
                .padding(SettingsLayout.diveRowPad)
                .overlay(alignment: .top) { Divider().background(Color.kHair2) }
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 18)

            // Active model
            VStack(spacing: 0) {
                header("Active model", trailing: statusLabel, trailingColor: statusTone)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeTitle)
                            .font(SettingsType.styleModelName).compassTracking(SettingsType.trackModelName)
                        Text(activeDetail)
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    if isVerified {
                        Text("ON DISK")
                            .font(SettingsFont.mono(10))
                            .tracking(0.8)
                            .foregroundStyle(Color.kGreen)
                    }
                }
                .padding(SettingsLayout.diveRowPad)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 7) {
                Text("Why there is no download")
                    .font(SettingsFont.mono(9))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text("Kalam is compiled without network entitlements, so you bring the model; the app never fetches one.")
                    .font(SettingsFont.body(12.5))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)
        }
        .onAppear { model.rescanEngine() }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        let path = model.modelFolder.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var lede: String {
        switch model.engine {
        case .verified:
            return "You supply the model and Kalam loads it locally on the Apple Neural Engine."
        case .missing:
            return "No model in this folder yet. Copy the Parakeet files here and return when they are in place."
        case .incomplete:
            return "This folder is not a full model yet. Copy the remaining Parakeet files and return when they are in place."
        }
    }

    private var isVerified: Bool {
        if case .verified = model.engine { return true }
        return false
    }

    private var statusLabel: String {
        switch model.engine {
        case .verified: return "Verified"
        case .missing: return "Missing"
        case .incomplete: return "Incomplete"
        }
    }

    /// Status tone — shared warn/bad vocabulary from onboarding (F-07).
    private var statusTone: Color {
        switch model.engine {
        case .verified: return Color.kGreen
        case .missing: return Color.kBad
        case .incomplete: return Color.kWarn
        }
    }

    private var activeTitle: String {
        switch model.engine {
        case .verified(let info): return info.name
        case .missing: return "No model found"
        case .incomplete: return "Incomplete"
        }
    }

    private var activeDetail: String {
        switch model.engine {
        case .verified(let info): return info.detail
        case .missing: return "The folder is empty, or no model is installed."
        case .incomplete: return "The folder does not have a full model yet."
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
