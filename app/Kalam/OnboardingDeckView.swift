import AppKit
import SwiftUI

struct OnboardingDeckView: View {
    @ObservedObject var controller: OnboardingFlowController
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var route: OnboardingDeckRoute
#if DEBUG
    @State private var isOptionKeyPressed = false
    private let modifierTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
#endif

    init(controller: OnboardingFlowController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        // Fresh-start flag is no longer load-bearing for routing (firstRun
        // always opens welcome); retained for the DEBUG reset ceremony.
        let freshStart = Self.peekDebugFreshStart()
        _route = State(initialValue: initialDeckRoute(mode: controller.snapshot.mode, snapshot: controller.snapshot, isFreshStart: freshStart))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch route {
                case .welcome:
                    OnboardingDeckCards(route: route, controller: controller, onAdvance: advanceRoute, onBack: goBack, headingFocused: $headingFocused)
                case .microphone, .microphoneSelection, .accessibility, .modelFolder, .modelAcquisition, .hotkey, .ready:
                    OnboardingDeckCards(route: route, controller: controller, onAdvance: advanceRoute, onBack: goBack, headingFocused: $headingFocused)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Option B (2026-08-21): no horizontal/top padding — the card IS
            // the window ground, edge-to-edge; its top corners ride the
            // window's own rounded silhouette. No bottom padding either: the
            // squared card bottom sits flush on the rail (Task 4 junction);
            // a gap here would read as a detached card.

            // Option A (2026-08-21): the rail exists only once the journey
            // does — hidden on welcome (the poster owns the full silhouette,
            // and a pre-lit "step 1 active" band there was dishonest the same
            // way pre-lit future steps were), it rises from the bottom edge
            // as the first gate card arrives and retreats on Back. Move +
            // opacity only (GPU-safe); reduce-motion resolves to instant via
            // the nil animation below.
            if route != .welcome {
                OnboardingProgressRail(
                    snapshot: controller.snapshot,
                    activeRoute: route
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 700, height: 600)
        // Scoped at the deck root so BOTH the card swap and the rail's
        // insertion/removal ride the same spring.
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: route)
        // No window background (Option B retired the dark shell): card +
        // rail are the only surfaces and fill the full silhouette; the system
        // clips them to the rounded window (transparent titlebar, clear
        // NSWindow background — see configureOnboardingWindow).
        .accentColor(OnboardingDeckTokens.accent)
        // Conventional window drag, made explicit (Option B follow-up): a
        // transparent strip along the top edge drives NSWindow.performDrag,
        // so the window stays movable WITHOUT isMovableByWindowBackground
        // (which swallows mouse-downs and turned the Task 7 icon drag into a
        // whole-window drag). Rendered BELOW the top-trailing controls
        // overlay so the DEBUG reset keeps hit priority.
        .overlay(alignment: .top) {
            WindowDragStrip()
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
        .onAppear {
            SettingsFont.ensureBrandFontRegistered()
            focusHeading()
            // Continue on the model card confirms the library location and
            // then advances explicitly — the refreshed arrival from the app
            // would otherwise re-run the hold against the stale snapshot
            // (2026-08-22 acknowledgment stop).
            controller.onAdvanceAfterModelConfirmation = advanceRoute
        }
        .onChange(of: controller.snapshot) { _, snapshot in
            // Welcome stays pinned until the user begins setup — snapshot
            // refreshes (TCC re-checks, audio prepare) must never bounce the
            // deck off the promise card. Begin setup is the only exit.
            // The microphone SELECTION card is likewise pinned (2026-08-21):
            // it is a multi-choice card whose rows refresh the snapshot on
            // every tap, which used to auto-advance before Continue was
            // touched. Both pins live in routeAfterSnapshotUpdate (tested);
            // permission cards intentionally keep snapshot-following —
            // "Check again" depends on it.
            route = routeAfterSnapshotUpdate(current: route, snapshot: snapshot)
            focusHeading()
        }
#if DEBUG
        .onReceive(modifierTimer) { _ in
            let isPressed = NSEvent.modifierFlags.contains(.option)
            if isPressed != isOptionKeyPressed {
                isOptionKeyPressed = isPressed
            }
        }
#endif
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kalam onboarding")
    }

    private var closeButton: some View {
        HStack(spacing: 10) {
#if DEBUG
            debugResetButton
#endif
        }
        // No visible close affordance (matches the mockup): Escape closes via
        // onExitCommand + .cancelAction. The ✕ that used to sit here is gone.
    }

#if DEBUG
    private var debugResetButton: some View {
        Button {
            controller.resetAllOnboardingState()
        } label: {
            Text("Reset (Option+Click)")
                .font(SettingsFont.mono(9))
                .underline()
                // Sits on the light card ground now (Option B) — use the card
                // muted ink, not the retired rail-silver.
                .foregroundStyle(OnboardingDeckTokens.ink3)
        }
        .buttonStyle(.plain)
        .opacity(isOptionKeyPressed ? 0.75 : 0)
        .allowsHitTesting(isOptionKeyPressed)
        .accessibilityHidden(!isOptionKeyPressed)
        .animation(.easeInOut, value: isOptionKeyPressed)
    }
#endif

    private func advanceRoute() {
        // Leaving welcome clears the fresh-start flag (DEBUG reset ceremony).
        if route == .welcome {
            Self.clearDebugFreshStart()
        }
        route = nextDeckRoute(after: route, snapshot: controller.snapshot)
        focusHeading()
    }

    private func goBack() {
        // Back skips satisfied gates (2026-08-22): the forward router holds
        // the model card open for first-run acknowledgment, so returning to
        // the naive predecessor would snapshot-advance straight back here.
        route = previousDeckRoute(before: route, snapshot: controller.snapshot)
        focusHeading()
    }

    private func focusHeading() {
        headingFocused = true
    }

    /// Peeks the fresh-start flag WITHOUT clearing it (DEBUG reset ceremony).
    private static func peekDebugFreshStart() -> Bool {
        OnboardingConfiguration.peekDebugFreshStart()
    }

    /// Clears the fresh-start flag once setup has actually begun.
    private static func clearDebugFreshStart() {
        OnboardingConfiguration.clearDebugFreshStart()
    }
}

/// Transparent AppKit strip along the deck's top edge that makes the window
/// draggable by its "titlebar" region — the conventional affordance the deck
/// keeps even though the window is borderless and the traffic lights are
/// hidden. `performDrag` runs the system move loop, so dragging works even
/// with `isMovableByWindowBackground = false` (required by the Task 7 drag
/// tile, which needs mouse-downs in the content).
private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> DragStripView {
        let view = DragStripView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: DragStripView, context: Context) {}

    final class DragStripView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // The strip is invisible chrome: never the first responder, never
        // part of the accessibility tree (hidden at the SwiftUI layer too).
        override var acceptsFirstResponder: Bool { false }
        override func accessibilityIsIgnored() -> Bool { true }
    }
}
