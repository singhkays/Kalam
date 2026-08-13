import AppKit
import SwiftUI

// MARK: - Compass settings window root
//
// Stub deviation (plan §5.1, 2026-08-13): the original stub used @Environment(\.dismiss) and a
// WindowGroup(id: "compass") scene. The live app is AppKit-led (menu-bar item → AppDelegate
// NSWindow), so CompassRoot is scene-agnostic: Close is injected as `onClose`, and the window
// itself is the borderless `CompassWindow` subclass configured in KalamApp.openSettingsWindow.
// There is deliberately NO parallel WindowGroup Settings scene (user decision 2026-08-13).

/// Root of the Compass settings window. Hosted by AppDelegate's NSWindow.
struct CompassRoot: View {
    @State private var model: SettingsModel
    @State private var path: [Destination] = []
    /// Rolled once per window lifetime; shared Map + Dive (do not re-roll on navigation).
    @State private var privacyLine: PrivacyLine = PrivacyLine.allCases.randomElement()!
    /// Local monitor for Cmd-W (borderless windows have no native key equivalent).
    @State private var cmdWMonitor: Any?

    var onClose: () -> Void

    init(store: any CompassSettingsBacking, onClose: @escaping () -> Void = {}) {
        _model = State(initialValue: SettingsModel(store: store))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack(path: $path) {
            MapView(model: model, privacyLine: privacyLine) { dest in
                path = [dest]
            } onClose: {
                onClose()
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
            installCmdWMonitor(install: true)
            model.refreshMicrophones()
            model.rescanEngine()
        }
        .onDisappear {
            installCmdWMonitor(install: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier == NSUserInterfaceItemIdentifier("KalamSettingsWindow") else { return }
            model.refreshMicrophones()
            model.rescanEngine()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectModelsSettingsTab)) { _ in
            // Deep link: "open settings at the Engine dive" (P6 wiring).
            path = [.engine]
        }
    }

    private func installCmdWMonitor(install: Bool) {
        if install, cmdWMonitor == nil {
            cmdWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 13, event.modifierFlags.contains(.command) {
                    onClose()
                    return nil
                }
                return event
            }
        } else if !install, let monitor = cmdWMonitor {
            NSEvent.removeMonitor(monitor)
            cmdWMonitor = nil
        }
    }
}

// MARK: - Window

/// Borderless NSWindow that accepts key/main status (required for text fields, menus, Cmd-W).
final class CompassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

#if DEBUG
#Preview("Compass · empty dictionary") {
    CompassRoot(store: InMemoryCompassStore.fixtureDefaultEmptyDictionary())
}
#endif
