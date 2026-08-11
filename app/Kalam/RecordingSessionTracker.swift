import Foundation

/// Monotonically increasing session counter for dictation recordings.
///
/// Each successful `startRecording` advances the counter and the in-flight
/// transcription task captures the generation of the recording it belongs to.
/// Immediately before dispatching a paste the task asks `isCurrent(_:)`; if a
/// newer recording has started, the old task is stale and must not paste (K-01).
struct RecordingSessionTracker {
    private var current = 0

    /// Starts a new dictation session, returning its generation.
    @discardableResult
    mutating func beginNewRecording() -> Int {
        current += 1
        return current
    }

    /// The generation of the latest dictation session.
    func currentGeneration() -> Int {
        current
    }

    /// True if `generation` belongs to the latest dictation session.
    func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}
