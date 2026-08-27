import Foundation

/// Monotonically increasing session counter for dictation recordings.
///
/// Each successful `startRecording` advances the counter and the in-flight
/// transcription task captures the generation of the recording it belongs to.
/// Immediately before dispatching a paste the task asks `isCurrent(_:)`; if a
/// newer recording has started, the old task is stale and must not paste (stale-recording paste guard).
struct RecordingSessionTracker {
    private var current = 0
    /// K-52: identity of the latest session, minted at `beginNewRecording`.
    /// Captured into every async callback (stop, ASR, paste) alongside the
    /// generation so stale completions are dropped BY POLICY — the lifecycle
    /// machine's staleness check and this value are the same fact.
    private(set) var currentSessionID: UUID?

    /// Starts a new dictation session, returning its generation.
    @discardableResult
    mutating func beginNewRecording() -> Int {
        current += 1
        currentSessionID = UUID()
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

    /// K-52: true if `id` names the latest dictation session. Async
    /// completion callbacks check this (or route through the lifecycle
    /// machine, which enforces the same policy) before touching shared state.
    func isCurrentSession(_ id: UUID) -> Bool {
        currentSessionID == id
    }
}
