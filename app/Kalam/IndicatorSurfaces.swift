import AppKit
import SwiftUI

// MARK: - Stadium chrome

/// Flat obsidian stadium: the one surface fill + white 14% border + black 18%
/// rim stroke. Deliberately NOT a live blur (standing ruling) — the WindowServer
/// window shadow provides elevation outside this view.
struct IndicatorStadium<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IndicatorTokens.obsidian)
            .clipShape(shape)
            .overlay(shape.stroke(IndicatorTokens.surfaceBorder, lineWidth: 1))
            .overlay(shape.stroke(IndicatorTokens.rimStroke, lineWidth: 1))
    }
}

// MARK: - Green ring (contrast-remedy spec)

/// Rotating conic arc masked to a 1.5px stadium stroke, plus its arc-bound
/// glow twin. The glow is derived FROM the arc (blur of the arc layer), so it
/// exists exactly where the arc exists and nowhere else — never a constant
/// full-perimeter blur ring. Reduce Motion resolves to the static hairline;
/// `period == nil` removes the ring (the gating law lives with the caller).
struct IndicatorRing: View {
    let period: Double?
    let cornerRadius: CGFloat
    let reduceMotion: Bool

    private var strokeShape: some InsettableShape {
        let inset = IndicatorTokens.ringLineWidth / 2
        return RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
            .inset(by: inset)
    }

    var body: some View {
        ZStack {
            if let period {
                if reduceMotion {
                    // Reduce Motion: static 1px hairline at 48%, no glow, no rotation.
                    strokeShape
                        .stroke(IndicatorTokens.brandGreen, style: StrokeStyle(lineWidth: IndicatorTokens.ringLineWidth))
                        .opacity(IndicatorTokens.ringStaticOpacity)
                } else {
                    // Deterministic sweep, clockwise on screen: SwiftUI positive
                    // rotation is clockwise, so the angle applies directly
                    // (mirrors the approved AppKit clockwise spin).
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let angle = elapsed.truncatingRemainder(dividingBy: period) / period * 360
                        arcAndGlow(sweepAngle: angle)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The arc + glow twin at a sweep angle. The gradient is transparent for the
    /// first 255deg and ramps to brand green over the last 105deg (mockup spec).
    private func arcAndGlow(sweepAngle: Double) -> some View {
        GeometryReader { geo in
            // Oversized so the gradient still covers the stadium mid-rotation.
            let span = max(geo.size.width, geo.size.height) * 2
            let gradient = AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 255.0 / 360.0),
                    .init(color: IndicatorTokens.brandGreen, location: 1.0)
                ]),
                center: .center,
                startAngle: .degrees(0),
                endAngle: .degrees(360)
            )
            let positioned = gradient
                .frame(width: span, height: span)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .rotationEffect(.degrees(sweepAngle))
            let arc = positioned
                .mask(
                    strokeShape.stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: IndicatorTokens.ringLineWidth, lineCap: .round)
                    )
                )
            // Arc-bound glow: a blurred copy of the arc layer itself, so glow
            // exists exactly where the arc exists. A separate full-stroke mask
            // here would render a constant blur ring the mockup never had.
            arc
            arc
                .blur(radius: IndicatorTokens.ringGlowWidth / 2)
                .opacity(IndicatorTokens.ringGlowOpacity)
        }
    }
}

// MARK: - Shimmer + breathing dot

/// Transcribing shimmer: three brand-green dots, phase-staggered opacity cycle.
/// Reduce Motion freezes them at a mid opacity.
struct ShimmerDots: View {
    let reduceMotion: Bool

    @State private var phase = false

    var body: some View {
        HStack(spacing: IndicatorTokens.shimmerDotSpacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(IndicatorTokens.brandGreen)
                    .frame(width: IndicatorTokens.shimmerDotSize, height: IndicatorTokens.shimmerDotSize)
                    .opacity(reduceMotion ? 0.8 : (phase ? 1.0 : IndicatorTokens.shimmerOpacityFloor))
                    .animation(
                        reduceMotion ? nil : .linear(duration: IndicatorTokens.shimmerCycleDuration)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * IndicatorTokens.shimmerStagger),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}

/// The recording dot: brand green with a soft glow, breathing while live.
struct BreathingDot: View {
    let reduceMotion: Bool

    @State private var phase = false

    var body: some View {
        Circle()
            .fill(IndicatorTokens.brandGreen)
            .frame(width: IndicatorTokens.recordingDotSize, height: IndicatorTokens.recordingDotSize)
            .shadow(color: IndicatorTokens.brandGreen.opacity(0.6), radius: 2)
            .opacity(reduceMotion ? 1.0 : (phase ? 1.0 : 0.55))
            .animation(
                reduceMotion ? nil : .linear(duration: 1.6).repeatForever(autoreverses: true),
                value: phase
            )
            .onAppear { phase = true }
    }
}

// MARK: - Level glyph

/// The three-bar level glyph (whisper pill). Heights come from the
/// published glyph levels; the low floor keeps bars clearly bar-shaped.
struct IndicatorLevelGlyph: View {
    let levels: [CGFloat]
    let barWidth: CGFloat
    var maxBarHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: IndicatorTokens.glyphBarGap) {
            ForEach(0..<3, id: \.self) { index in
                let level = index < levels.count ? min(1.0, max(0.0, levels[index])) : 0.0
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(IndicatorTokens.brandGreen)
                    .frame(
                        width: barWidth,
                        height: IndicatorTokens.glyphMinBarHeight + (maxBarHeight - IndicatorTokens.glyphMinBarHeight) * level
                    )
            }
        }
    }
}

/// Target-app icon with the generic `app` fallback for iconless helpers.
struct IndicatorAppIcon: View {
    let image: NSImage?
    let side: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .frame(width: side, height: side)
        } else {
            Image(systemName: "app")
                .resizable()
                .frame(width: side, height: side)
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - Surfaces

/// Machined deck: the full capsule. Recording states show icon row + waveform;
/// transcribing shows the shimmer row; held/blocked show message + actions.
struct IndicatorDeckSurface: View {
    let presentation: IndicatorPresentationState.Presentation
    let session: IndicatorPresentationState.Session
    let elapsed: String
    @ObservedObject var waveform: IndicatorWaveformState

    var body: some View {
        IndicatorStadium(cornerRadius: IndicatorTokens.cornerRadius) {
            if presentation.isRecording {
                VStack(spacing: IndicatorTokens.waveformTopSpacing) {
                    HStack(spacing: 7) {
                        IndicatorAppIcon(image: presentation.targetAppIcon, side: 16)
                        Text(presentation.targetAppName.isEmpty ? "App" : presentation.targetAppName)
                            .font(IndicatorTokens.appNameFont(compact: false))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        BreathingDot(reduceMotion: session.reduceMotion)
                        Text(elapsed)
                            .font(IndicatorTokens.timerFont(compact: false))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(height: IndicatorTokens.topRowHeight)
                    IndicatorWaveformView(waveform: waveform)
                        .frame(height: IndicatorTokens.waveformHeight)
                }
                .padding(.top, IndicatorTokens.topRowTopPadding)
                .padding(.horizontal, IndicatorTokens.hPadding)
            } else if presentation.showsTranscribingLabel {
                HStack(spacing: 6) {
                    Text(presentation.message)
                        .font(IndicatorTokens.messageFont)
                        .foregroundStyle(.white)
                    ShimmerDots(reduceMotion: session.reduceMotion)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, IndicatorTokens.hPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    Text(presentation.message)
                        .font(IndicatorTokens.messageFont)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let title = presentation.secondaryActionTitle, let action = presentation.secondaryAction {
                        Button(title) { action() }
                            .font(IndicatorTokens.buttonFont)
                            .foregroundStyle(.white.opacity(0.7))
                            .buttonStyle(.plain)
                    }
                    if let title = presentation.primaryActionTitle, let action = presentation.primaryAction {
                        Button(title) { action() }
                            .font(IndicatorTokens.buttonFont)
                            .buttonStyle(.automatic)
                    }
                }
                .padding(.horizontal, IndicatorTokens.hPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Whisper pill: the compact surface. Listening/pausing show icon + name +
/// glyph + timer; transcribing shows the label + shimmer.
struct IndicatorPillSurface: View {
    let presentation: IndicatorPresentationState.Presentation
    let session: IndicatorPresentationState.Session
    let elapsed: String
    @ObservedObject var waveform: IndicatorWaveformState

    var body: some View {
        IndicatorStadium(cornerRadius: IndicatorTokens.pillCornerRadius) {
            if presentation.showsTranscribingLabel {
                HStack(spacing: 6) {
                    Text(presentation.message)
                        .font(IndicatorTokens.appNameFont(compact: true))
                        .foregroundStyle(.white)
                    ShimmerDots(reduceMotion: session.reduceMotion)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, IndicatorTokens.hPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 7) {
                    IndicatorAppIcon(image: presentation.targetAppIcon, side: 14)
                    Text(presentation.targetAppName.isEmpty ? "App" : presentation.targetAppName)
                        .font(IndicatorTokens.appNameFont(compact: true))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    IndicatorLevelGlyph(levels: waveform.glyph.smoothed, barWidth: IndicatorTokens.glyphBarWidth)
                        .frame(width: IndicatorTokens.glyphSize.width, height: IndicatorTokens.glyphSize.height)
                    Text(elapsed)
                        .font(IndicatorTokens.timerFont(compact: true))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, IndicatorTokens.hPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Window roots

/// Main capsule window root. Picks the surface from session style +
/// canonical state (whisper renders the compact pill, everything else the
/// deck); the controller owns window sizing.
struct IndicatorCapsuleRootView: View {
    @ObservedObject var state: IndicatorPresentationState

    private var isCompact: Bool {
        guard let canonical = state.presentation.canonicalState else { return false }
        return IndicatorStateModel.usesCompactSurface(style: state.session.style, state: canonical)
    }

    /// Ring gating law (D-2): transcribing only — see IndicatorTokens.ringPeriod.
    private var ringPeriod: Double? {
        IndicatorTokens.ringPeriod(style: state.session.style, canonicalState: state.presentation.canonicalState)
    }

    var body: some View {
        Group {
            if isCompact {
                IndicatorPillSurface(
                    presentation: state.presentation,
                    session: state.session,
                    elapsed: state.elapsed,
                    waveform: state.waveform
                )
            } else {
                IndicatorDeckSurface(
                    presentation: state.presentation,
                    session: state.session,
                    elapsed: state.elapsed,
                    waveform: state.waveform
                )
            }
        }
        .overlay(
            IndicatorRing(
                period: ringPeriod,
                cornerRadius: isCompact ? IndicatorTokens.pillCornerRadius : IndicatorTokens.cornerRadius,
                reduceMotion: state.session.reduceMotion
            )
        )
    }
}