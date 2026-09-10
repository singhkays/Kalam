import AppKit
import Foundation

/// What the indicator surfaces render for the current overlay state. The
/// controller publishes once per transition and on waveform/timer ticks; the
/// SwiftUI parity surfaces read only this. No SwiftUI imports — AppKit appears
/// solely as NSImage for the target-app icon (plan §5.3 amendment).
@MainActor
final class IndicatorPresentationState: ObservableObject {

    struct Presentation {
        var message: String = ""
        var primaryActionTitle: String?
        var secondaryActionTitle: String?
        var primaryAction: (() -> Void)?
        var secondaryAction: (() -> Void)?
        var targetAppName: String = ""
        var targetAppIcon: NSImage?
        var isRecording: Bool = false
        /// Canonical K-48 state behind the overlay state; nil for the transient
        /// info/error forms (they always render the deck per the fallback law).
        var canonicalState: IndicatorState?

        static var idle: Presentation { Presentation() }

        var showsTranscribingLabel: Bool { message.hasPrefix("Transcribing") }
    }

    struct Session {
        var style: IndicatorStyle = .machined
        var usesDarkAppearance: Bool = true
        var reduceMotion: Bool = false
    }

    /// Monotonic counter: exactly one bump per publish. The probe asserts this
    /// and SwiftUI reads it for debug tracing.
    @Published private(set) var revision = 0
    @Published private(set) var presentation = Presentation()
    @Published private(set) var session = Session()
    @Published private(set) var elapsed = "00:00"
    let waveform = IndicatorWaveformState()

    func publish(presentation: Presentation, session: Session) {
        self.presentation = presentation
        self.session = session
        revision += 1
    }

    func publishElapsed(_ text: String) {
        elapsed = text
    }
}

/// Waveform + glyph live-data, split from the presentation so the 30Hz tick
/// invalidates only the bars/glyph views, never the whole surface tree
/// (plan §6.4/§9).
@MainActor
final class IndicatorWaveformState: ObservableObject {
    @Published private(set) var envelope = IndicatorWaveformMath.Envelope()
    @Published private(set) var glyph = IndicatorWaveformMath.GlyphEnvelope()

    func ingest(samples: [Float], active: Bool) {
        IndicatorWaveformMath.ingest(samples: samples, active: active, into: &envelope)
    }

    func ingestGlyph(samples: [Float]) {
        glyph.ingest(samples)
    }

    func reset() {
        IndicatorWaveformMath.reset(&envelope)
        glyph = IndicatorWaveformMath.GlyphEnvelope()
    }
}