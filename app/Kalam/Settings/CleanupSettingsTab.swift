import SwiftUI
import KalamTextEngine

struct CleanupSettingsTab: View {
    @Binding var modelsConfig: ModelsConfiguration
    @State private var showFullGrammarWarning = false
    @State private var previousGrammarModeSelection: TextCleanupGrammarMode = .light

    var body: some View {
        refineContent
            .onAppear { previousGrammarModeSelection = modelsConfig.textCleanup.grammarMode }
            .alert("Use Full Grammar Mode?", isPresented: $showFullGrammarWarning) {
                Button("OK") {
                    modelsConfig.textCleanup.grammarMode = .full
                }
                Button("Cancel", role: .cancel) {
                    modelsConfig.textCleanup.grammarMode = previousGrammarModeSelection
                }
            } message: {
                Text(
                    "Full mode can increase paste delay variability and may over-correct names or technical terms. Use Full only if you prefer extra polish over consistent low-latency output."
                )
            }
    }

    private var refineContent: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                Spacer().frame(height: 6)

                VStack(spacing: 16) {
                    PreferenceRow {
                        Text("Deterministic Cleanup")
                            .font(KalamTheme.sectionTitleFont)
                            .foregroundColor(KalamTheme.textPrimary)
                    } content: {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $modelsConfig.textCleanup.enabled) {
                                Text("Enable cleanup pipeline before dictionary replacement")
                                    .font(KalamTheme.bodyFont)
                                    .foregroundColor(KalamTheme.textPrimary)
                            }
                            .toggleStyle(KalamCheckboxStyle())
                            .controlSize(.regular)
                        }
                    }

                    PreferenceRow {
                        Text("Rules")
                            .font(KalamTheme.sectionTitleFont)
                            .foregroundColor(KalamTheme.textPrimary)
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            refineOption(
                                title: "Remove filler words",
                                helper:
                                    "\"um I think we should ship\" -> \"I think we should ship\"",
                                binding: $modelsConfig.textCleanup.removeFillers,
                                isEnabled: modelsConfig.textCleanup.enabled
                            )

                            refineOption(
                                title: "Handle backtracks (e.g. \"scratch that\")",
                                helper:
                                    "\"send this now scratch that send it tomorrow\" -> \"send it tomorrow\"",
                                binding: $modelsConfig.textCleanup.backtrack,
                                isEnabled: modelsConfig.textCleanup.enabled
                            )

                            refineOption(
                                title: "Format spoken numbered lists",
                                helper:
                                    "\"one/1 gather logs two/2 isolate bug\" -> \"1. gather logs\n2. isolate bug\"",
                                binding: $modelsConfig.textCleanup.listFormatting,
                                isEnabled: modelsConfig.textCleanup.enabled
                            )

                            refineOption(
                                title: "Normalize punctuation and spacing",
                                helper:
                                    "\"hello ,world!!this is fine\" -> \"hello, world! this is fine\"",
                                binding: $modelsConfig.textCleanup.punctuation,
                                isEnabled: modelsConfig.textCleanup.enabled
                            )
                        }
                    }
                }
                .padding(16)
                .settingsCardSurface()

                Divider()
                    .overlay(KalamTheme.strokeSubtle)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 60)

                VStack(spacing: 16) {
                    PreferenceRow {
                        Text("Grammar Pass")
                            .font(KalamTheme.sectionTitleFont)
                            .foregroundColor(KalamTheme.textPrimary)
                    } content: {
                        VStack(alignment: .leading, spacing: 8) {
                            KalamSegmentedControl(
                                selection: grammarModeBinding,
                                options: TextCleanupGrammarMode.allCases,
                                content: { mode in Text(mode.displayName) }
                            )
                            .frame(maxWidth: 240)
                            .disabled(!modelsConfig.textCleanup.enabled)

                            Text(grammarDescription(for: modelsConfig.textCleanup.grammarMode))
                                .font(KalamTheme.footnoteFont)
                                .foregroundColor(KalamTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Grammar pass is skipped for long transcripts.")
                                .font(KalamTheme.footnoteFont)
                                .foregroundColor(KalamTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .settingsCardSurface()

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    @ViewBuilder
    private func refineOption(
        title: String, helper: String, binding: Binding<Bool>, isEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: binding) {
                Text(title)
                    .font(KalamTheme.bodyFont)
                    .foregroundColor(KalamTheme.textPrimary)
            }
            .toggleStyle(KalamCheckboxStyle())
            .controlSize(.regular)
            .disabled(!isEnabled)

            Text(helper)
                .font(KalamTheme.footnoteFont)
                .foregroundColor(KalamTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
        .opacity(isEnabled ? 1 : 0.6)
    }
    private func grammarDescription(for mode: TextCleanupGrammarMode) -> String {
        switch mode {
        case .off:
            return "No grammar correction is applied."
        case .light:
            return "Light: fixes common typos, spacing, and punctuation with minimal latency."
        case .full:
            return "Full: stronger sentence-level correction for polish, with higher variability."
        }
    }
    private var grammarModeBinding: Binding<TextCleanupGrammarMode> {
        Binding(
            get: {
                modelsConfig.textCleanup.grammarMode
            },
            set: { newMode in
                if newMode == .full && modelsConfig.textCleanup.grammarMode != .full {
                    previousGrammarModeSelection = modelsConfig.textCleanup.grammarMode
                    showFullGrammarWarning = true
                    return
                }
                modelsConfig.textCleanup.grammarMode = newMode
            }
        )
    }
}

private struct PreferenceRow<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    init(@ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack {
                Spacer()
                label
                    .multilineTextAlignment(.trailing)
            }
            .frame(width: 140)

            content
            Spacer()
        }
    }
}

