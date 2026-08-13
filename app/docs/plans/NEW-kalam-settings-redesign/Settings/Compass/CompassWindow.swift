import SwiftUI

/// Root of the Settings utility window. Inject a live `CompassSettingsBacking` in production.
struct CompassRoot: View {
    @State private var model: SettingsModel
    @State private var path: [Destination] = []
    /// Rolled once per window lifetime; shared Map + Dive (do not re-roll on navigation).
    @State private var privacyLine: PrivacyLine = PrivacyLine.allCases.randomElement()!
    @Environment(\.dismiss) private var dismiss

    init(store: any CompassSettingsBacking) {
        _model = State(initialValue: SettingsModel(store: store))
    }

    var body: some View {
        NavigationStack(path: $path) {
            MapView(model: model, privacyLine: privacyLine) { dest in
                path = [dest]
            } onClose: {
                dismiss()
            }
            .navigationDestination(for: Destination.self) { dest in
                DiveView(
                    destination: dest,
                    path: $path,
                    model: model,
                    privacyLine: privacyLine
                )
            }
        }
        .toolbar(.hidden)
        .frame(width: CompassLayout.window.width, height: CompassLayout.window.height)
        .background(Color.kPaper)
        .preferredColorScheme(.light)
        .dynamicTypeSize(.large) // fixed utility chrome; mockups are not Dynamic Type
        .onAppear {
            model.refreshMicrophones()
            model.rescanEngine()
        }
    }
}

// MARK: - Scene helper (host app)

enum CompassScene {
    static let windowID = "compass"

    /// Call from App: WindowGroup(id: CompassScene.windowID) { CompassRoot(store: ...) }
    /// .windowStyle(.plain)
    /// .windowResizability(.contentSize)
    /// .windowBackgroundDragBehavior(.enabled)
    /// .defaultSize(width: 980, height: 660)
}

#if DEBUG
#Preview("Compass · empty dictionary") {
    CompassRoot(store: InMemoryCompassStore.fixtureDefaultEmptyDictionary())
}
#endif
