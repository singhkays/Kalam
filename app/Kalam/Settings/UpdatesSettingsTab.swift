import SwiftUI

struct UpdatesSettingsTab: View {
    var body: some View {
        updatesContent
    }

    private var updatesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Updates")
                        .font(KalamTheme.pageTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)
                    Text("Stay current with the latest Kalam release.")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Latest Release")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Installed version")
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textPrimary)

                            Spacer()

                            Text(KalamAppVersion.displayString)
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)

                        Divider().overlay(KalamTheme.strokeSubtle)

                        Text("Kalam is intentionally built with ")
                            .font(KalamTheme.calloutFont)
                            .foregroundColor(KalamTheme.textSecondary)
                            + Text("zero network access")
                            .font(KalamTheme.calloutFont.bold())
                            .foregroundColor(KalamTheme.textSecondary)
                            + Text(
                                ". It will not check for updates or download models automatically. To see the latest release, click View Latest Release… and compare it with your installed version."
                            )
                            .font(KalamTheme.calloutFont)
                            .foregroundColor(KalamTheme.textSecondary)

                        Button("View Latest Release…") {
                            KalamExternalLinks.openLatestRelease()
                        }
                        .buttonStyle(OnboardingPremiumButtonStyle(isCompact: true))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .settingsCardSurface()
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
