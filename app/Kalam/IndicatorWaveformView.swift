import SwiftUI

/// The machined deck's waveform: one canvas draw per tick, isolated from the
/// rest of the surface tree (plan §6.4). Geometry uses a uniform green alpha;
/// SwiftUI waveform bars for the machined deck (the sole content path since
/// the Phase 4 cutover; values mirror the deleted AppKit implementation).
struct IndicatorWaveformView: View {
    @ObservedObject var waveform: IndicatorWaveformState

    var body: some View {
        Canvas { context, size in
            let drawHeight = size.height - IndicatorTokens.waveformVPadding * 2
            let minHeight = max(IndicatorTokens.waveformMinBarHeight, drawHeight * 0.05)
            let maxHeight = max(minHeight + 5, drawHeight * 0.96)
            let step = IndicatorTokens.barWidth + IndicatorTokens.barGap
            let entryX = size.width * IndicatorTokens.entryFraction
            let centerY = size.height / 2
            let history = waveform.envelope.history
            let barCount = Int(size.width / step) + 2

            for barsFromRight in 0..<barCount {
                let x = entryX - CGFloat(barsFromRight + 1) * step
                guard x + IndicatorTokens.barWidth >= 0, x <= size.width else { continue }
                let historyIndex = history.count - 1 - barsFromRight
                let amplitude = historyIndex >= 0 ? history[historyIndex] : 0.0
                let height = minHeight + (maxHeight - minHeight) * amplitude
                let rect = CGRect(x: x, y: centerY - height / 2, width: IndicatorTokens.barWidth, height: height)
                let alpha = IndicatorTokens.barAlpha
                context.fill(
                    Path(roundedRect: rect, cornerRadius: IndicatorTokens.barWidth / 2),
                    with: .color(IndicatorTokens.brandGreen.opacity(Double(alpha)))
                )
            }
        }
        .drawingGroup()
    }
}