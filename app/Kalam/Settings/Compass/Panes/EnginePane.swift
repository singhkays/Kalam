import AppKit
import SwiftUI

struct EnginePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The engine")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("The engine ").font(CompassType.styleDiveDisplay).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("lives on your disk.").font(CompassType.styleDiveDisplayItalic).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(CompassType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            // Install location
            VStack(spacing: 0) {
                header("Install location")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model folder")
                            .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                        Text(displayPath)
                            .font(CompassType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    Group {
                        if isVerified {
                            Button("Choose…") {
                                Task { await model.chooseModelFolder() }
                            }
                            .buttonStyle(CompassSecondaryButtonStyle())
                        } else {
                            Button("Choose…") {
                                Task { await model.chooseModelFolder() }
                            }
                            .buttonStyle(CompassPrimaryButtonStyle())
                        }
                    }
                }
                .padding(CompassLayout.diveRowPad)
                .overlay(alignment: .top) { Divider().background(Color.kHair2) }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy to install")
                            .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                        Text(model.installCommand)
                            .font(CompassType.stylePathMono)
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
                            .buttonStyle(CompassPrimaryButtonStyle())
                        } else {
                            Button("Copy command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.installCommand, forType: .string)
                            }
                            .buttonStyle(CompassSecondaryButtonStyle())
                        }
                    }
                }
                .padding(CompassLayout.diveRowPad)
                .overlay(alignment: .top) { Divider().background(Color.kHair2) }
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 18)

            // Active model
            VStack(spacing: 0) {
                header("Active model", trailing: statusLabel, trailingDim: !isVerified)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeTitle)
                            .font(CompassType.styleModelName).compassTracking(CompassType.trackModelName)
                        Text(activeDetail)
                            .font(CompassType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    if isVerified {
                        Text("ON DISK")
                            .font(CompassFont.mono(10))
                            .tracking(0.8)
                            .foregroundStyle(Color.kGreen)
                    }
                }
                .padding(CompassLayout.diveRowPad)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 7) {
                Text("Why there is no download")
                    .font(CompassFont.mono(9))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text("Kalam is compiled without network entitlements, so you bring the model; the app never fetches one.")
                    .font(CompassFont.body(12.5))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
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

    private func header(_ title: String, trailing: String? = nil, trailingDim: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(CompassType.styleCardHeaderLabel)
                .compassTracking(CompassType.trackCardHeaderLabel)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(CompassFont.mono(9.5))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingDim ? Color.kInk3 : Color.kGreen)
            }
        }
        .padding(CompassLayout.diveCardHeaderPad)
    }
}
