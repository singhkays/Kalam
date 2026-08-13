import AppKit
import SwiftUI

struct UpdatesPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Maintenance")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(model.versionString)
                    .font(CompassType.styleUpdatesFigure).compassTracking(CompassType.trackUpdatesFigure)
                    .foregroundStyle(Color.kInk)
                Text("Universal build for Apple silicon and Intel.")
                    .font(CompassFont.body(13))
                    .foregroundStyle(Color.kInk2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .padding(.top, 12)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for a newer release")
                        .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                    Text("Opens the release page in your browser without sending anything from this Mac.")
                        .font(CompassType.styleRowDetail)
                        .foregroundStyle(Color.kInk2)
                }
                Spacer()
                Button("View latest release") {
                    NSWorkspace.shared.open(model.releaseURL)
                }
                .buttonStyle(CompassPrimaryButtonStyle())
            }
            .padding(CompassLayout.diveRowPad)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 7) {
                Text("Why there is no auto update")
                    .font(CompassFont.mono(9))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text("Kalam makes no outbound requests for telemetry, crash reports, license checks, or update pings. Audio and transcripts stay on this Mac, which is simpler to guarantee with no network code in the app. Release notes open in the browser so you can read what changed before you replace the build.")
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
    }
}
