import SwiftUI

struct CleanupPane: View {
    @Bindable var model: SettingsModel
    // K-55 degraded state is app-side UserDefaults (ValidationGateTripStore), not via SettingsBacking.
    // Poll revision to refresh when store changes (notification posts on main).
    @State private var isDegraded: Bool = UserDefaults.standard.bool(forKey: "validationGate.isDegraded")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cleanup")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
                .accessibilityAddTraits(.isHeader)

            // K-55 degraded banner
            if isDegraded {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-paused — using raw transcription until relaunch")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                            .foregroundStyle(Color.kInk)
                        Text("Last 3 pastes had formatting issues. Cleanup is bypassed to preserve your words.")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    Button("Re-enable") {
                        ValidationGateTripStore().reset()
                        isDegraded = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(SettingsLayout.diveRowPad)
                .background(Color.kPanel)
                .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
                .cornerRadius(SettingsLayout.cardRadius)
                .padding(.top, 12)
            }

            (
                Text("Messy in, ").font(SettingsType.styleDiveDisplay).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("Clean out.").font(SettingsType.styleDiveDisplayItalic).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(SettingsType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)

            // Master
            VStack(spacing: 0) {
                header("Master")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deterministic cleanup")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        Text("Turns the whole cleanup pass on or off.")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    PaperToggle(isOn: $model.cleanupEnabled)
                }
                .padding(SettingsLayout.diveRowPad)
                .rowTopEdge(first: true)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 18)

            // Rules
            VStack(spacing: 0) {
                header(
                    "Rules",
                    trailing: model.cleanupEnabled ? "\(model.cleanupRulesOnCount) of 4" : "Skipped",
                    trailingColor: model.cleanupEnabled ? nil : Color.kInk3 // neutral, not green (F-07)
                )
                ruleRow("Remove filler words", $model.removeFillers, first: true)
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
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .opacity(model.cleanupEnabled ? 1 : SettingsLayout.dimOpacity)
            .allowsHitTesting(model.cleanupEnabled)
            .padding(.top, 18)

            // Grammar
            VStack(spacing: 0) {
                header("Grammar pass")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How much to rewrite")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        Text(model.cleanupEnabled ? "Skipped past about 400 words." : "Skipped while cleanup is off.")
                            .font(SettingsType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                    }
                    Spacer()
                    PaperSegment(
                        selection: $model.grammarPass,
                        options: GrammarPass.allCases.map { ($0, $0.label) },
                        disabled: !model.cleanupEnabled
                    )
                }
                .padding(SettingsLayout.diveRowPad)
                .rowTopEdge(first: true)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .opacity(model.cleanupEnabled ? 1 : SettingsLayout.dimOpacity)
            .padding(.top, 18)
        }
        .onAppear {
            isDegraded = UserDefaults.standard.bool(forKey: "validationGate.isDegraded")
        }
        .onReceive(NotificationCenter.default.publisher(for: ValidationGateTripStore.didAutoDegrade)) { _ in
            isDegraded = true
        }
    }

    private var lede: String {
        model.cleanupEnabled
            ? "Fixed rules run on every transcript before it is typed; turn them off to type exactly what was heard."
            : "Cleanup is off, so Kalam types exactly what it heard. Turn the master on to use the rules below."
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

    private func ruleRow(_ title: String, _ binding: Binding<Bool>, first: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
            Spacer()
            PaperToggle(isOn: binding, disabled: !model.cleanupEnabled)
        }
        .padding(SettingsLayout.diveRowPad)
        .rowTopEdge(first: first)
    }

    private func sampleWell(messy: String, strike: String?, clean: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Messy input")
                    .font(SettingsType.styleSampleWellLabel)
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                messyText(messy, strike: strike)
                    .font(SettingsFont.body(SettingsType.sampleWellBody))
                    .foregroundStyle(Color.kInk2)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Clean output")
                    .font(SettingsType.styleSampleWellLabel)
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text(clean)
                    .font(SettingsFont.body(SettingsType.sampleWellBody))
                    .foregroundStyle(Color.kInk)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.kGreen.opacity(SettingsLayout.wellSplitOpacity))
                    .frame(width: 1)
            }
        }
        .background(Color.kPaper)
        .overlay(RoundedRectangle(cornerRadius: SettingsLayout.wellRadius).stroke(Color.kHair2))
        .cornerRadius(SettingsLayout.wellRadius)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// Mockup `.ba p s`: struck span renders ink3 with a 2pt line at 45% ink.
    private func messyText(_ messy: String, strike: String?) -> Text {
        guard let strike, let range = messy.range(of: strike) else { return Text(messy) }
        let pre = String(messy[..<range.lowerBound])
        let mid = String(messy[range])
        let post = String(messy[range.upperBound...])
        return Text(pre)
            + Text(mid)
                .strikethrough(true, color: Color.kStrike)
                .foregroundStyle(Color.kInk3)
            + Text(post)
    }
}
