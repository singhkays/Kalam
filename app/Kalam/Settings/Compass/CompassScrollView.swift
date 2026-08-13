import SwiftUI

/// Scroll container with a thin auto-hiding indicator (mockup: no persistent scrollbar).
/// The 4 pt capsule fades in while scrolling and fades out ~0.6 s after scrolling stops —
/// deterministic regardless of the system "Show scroll bars" preference.
struct CompassScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var indicatorVisible = false
    @State private var hideTask: Task<Void, Never>?

    private var fraction: CGFloat {
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 0, viewportHeight > 0 else { return 0 }
        return min(max(offset / scrollable, 0), 1)
    }

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: CompassScrollMetricsKey.self,
                            value: CompassScrollMetrics(
                                offset: -geo.frame(in: .named("compassScroll")).minY,
                                height: geo.size.height
                            )
                        )
                    }
                )
        }
        .coordinateSpace(name: "compassScroll")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewportHeight = h }
            }
        )
        .scrollIndicators(.hidden)
        .onPreferenceChange(CompassScrollMetricsKey.self) { metrics in
            contentHeight = metrics.height
            let moved = abs(metrics.offset - offset) > 0.5
            offset = metrics.offset
            guard moved, contentHeight > viewportHeight + 1 else { return }
            indicatorVisible = true
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                indicatorVisible = false
            }
        }
        .overlay(alignment: .trailing) { indicator }
    }

    @ViewBuilder
    private var indicator: some View {
        if contentHeight > viewportHeight + 1 {
            GeometryReader { geo in
                let thumbH = max(36, viewportHeight * (viewportHeight / contentHeight))
                Capsule()
                    .fill(Color.kInk3.opacity(0.38))
                    .frame(width: 4, height: thumbH)
                    .offset(y: max(0, (geo.size.height - thumbH) * fraction))
                    .padding(.trailing, 5)
                    .opacity(indicatorVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: indicatorVisible)
                    .animation(.easeOut(duration: 0.12), value: fraction)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct CompassScrollMetrics: Equatable {
    var offset: CGFloat
    var height: CGFloat
}

struct CompassScrollMetricsKey: PreferenceKey {
    static var defaultValue: CompassScrollMetrics {
        CompassScrollMetrics(offset: 0, height: 0)
    }
    static func reduce(value: inout CompassScrollMetrics, nextValue: () -> CompassScrollMetrics) {
        value = nextValue()
    }
}
