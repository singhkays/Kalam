import SwiftUI

struct CleanupPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cleanup")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("Messy in, ").font(CompassType.styleDiveDisplay).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("Clean out.").font(CompassType.styleDiveDisplayItalic).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(CompassType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)

            // Master
            VStack(spacing: 0) {
                header("Master")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deterministic cleanup")
                            .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                        Text("Turns the whole cleanup pass on or off.")
                            .font(CompassType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    PaperToggle(isOn: $model.cleanupEnabled)
                }
                .padding(CompassLayout.diveRowPad)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 18)

            // Rules
            VStack(spacing: 0) {
                header(
                    "Rules",
                    trailing: model.cleanupEnabled ? "\(model.cleanupRulesOnCount) of 4" : "Skipped"
                )
                ruleRow("Remove filler words", $model.removeFillers)
                if model.cleanupEnabled && model.removeFillers {
                    sampleWell(
                        messy: "So um I think we should ship it",
                        strike: "um",
                        clean: "So I think we should ship it"
                    )
                }
                ruleRow("Handle backtracks", $model.handleBacktracks)
                if model.cleanupEnabled && model.handleBacktracks {
                    sampleWell(
                        messy: "send this now scratch that send it tomorrow",
                        strike: "scratch that",
                        clean: "send it tomorrow"
                    )
                }
                ruleRow("Format spoken numbered lists", $model.formatLists)
                if model.cleanupEnabled && model.formatLists {
                    sampleWell(
                        messy: "one buy milk, two call Sam",
                        strike: "two call Sam",
                        clean: "1. Buy milk / 2. Call Sam"
                    )
                }
                ruleRow("Normalize punctuation and spacing", $model.normalizePunctuation)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .opacity(model.cleanupEnabled ? 1 : CompassLayout.dimOpacity)
            .allowsHitTesting(model.cleanupEnabled)
            .padding(.top, 18)

            // Grammar
            VStack(spacing: 0) {
                header("Grammar pass")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How much to rewrite")
                            .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                        Text(model.cleanupEnabled ? "Skipped past about 400 words." : "Skipped while cleanup is off.")
                            .font(CompassType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    PaperSegment(
                        selection: $model.grammarPass,
                        options: GrammarPass.allCases.map { ($0, $0.label) },
                        disabled: !model.cleanupEnabled
                    )
                }
                .padding(CompassLayout.diveRowPad)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .opacity(model.cleanupEnabled ? 1 : CompassLayout.dimOpacity)
            .padding(.top, 18)
        }
    }

    private var lede: String {
        model.cleanupEnabled
            ? "Fixed rules run on every transcript before it is typed; turn them off to type exactly what was heard."
            : "Cleanup is off, so Kalam types exactly what it heard. Turn the master on to use the rules below."
    }

    private func header(_ title: String, trailing: String? = nil) -> some View {
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
                    .foregroundStyle(Color.kGreen)
            }
        }
        .padding(CompassLayout.diveCardHeaderPad)
    }

    private func ruleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
            Spacer()
            PaperToggle(isOn: binding, disabled: !model.cleanupEnabled)
        }
        .padding(CompassLayout.diveRowPad)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
    }

    private func sampleWell(messy: String, strike: String?, clean: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Messy input")
                    .font(CompassType.styleSampleWellLabel)
                    .compassTracking(CompassType.trackSampleWellLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                messyText(messy, strike: strike)
                    .font(CompassFont.body(CompassType.sampleWellBody))
                    .foregroundStyle(Color.kInk2)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Clean output")
                    .font(CompassType.styleSampleWellLabel)
                    .compassTracking(CompassType.trackSampleWellLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text(clean)
                    .font(CompassFont.body(CompassType.sampleWellBody))
                    .foregroundStyle(Color.kInk)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.kGreen.opacity(CompassLayout.wellSplitOpacity))
                    .frame(width: 1)
            }
        }
        .background(Color.kWell)
        .cornerRadius(CompassLayout.wellRadius)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    /// Mockup `.ba p s`: struck span renders ink3 with a 2pt line at 45% ink.
    private func messyText(_ messy: String, strike: String?) -> Text {
        guard let strike, let range = messy.range(of: strike) else { return Text(messy) }
        let pre = String(messy[..<range.lowerBound])
        let mid = String(messy[range])
        let post = String(messy[range.upperBound...])
        return Text(pre)
            + Text(mid)
                .strikethrough(true, color: Color.kInk.opacity(0.45))
                .foregroundStyle(Color.kInk3)
            + Text(post)
    }
}
