import CoreAudio
import Foundation

/// Stage timing for one recording START (keydown -> indicator visible).
/// Timings only, never content: the flushed line carries integer milliseconds,
/// safe as `privacy: .public` (SECURITY.md policy).
struct RecordingStartLatencyProbe {
    enum Stage: Int, CaseIterable {
        case hotkeyReceived = 0
        case guardsCompleted
        case audioPrepared
        case engineStarted
        case indicatorShown
    }

    private var times: [CFAbsoluteTime?] = Array(repeating: nil, count: Stage.allCases.count)

    var isComplete: Bool { times.allSatisfy { $0 != nil } }

    mutating func mark(_ stage: Stage) {
        markWithTime(stage, CFAbsoluteTimeGetCurrent())
    }

    /// Marks relative to an absolute timestamp. Marks that would corrupt the
    /// sequence are ignored: earlier than the previously marked stage, or (when
    /// the predecessor is unmarked) earlier than the hotkeyReceived seed.
    mutating func markWithTime(_ stage: Stage, _ time: CFAbsoluteTime) {
        let index = stage.rawValue
        guard times[0] != nil || index == 0 else { return }
        if index > 0 {
            if let previous = times[index - 1], time < previous { return }
            if let seed = times[0], time < seed { return }
        }
        times[index] = time
    }

    /// One-line cumulative deltas from keydown. Nil until every stage marked.
    func summaryLine() -> String? {
        guard let start = times[0] else { return nil }
        let labels = ["toGuardsMs", "toPreparedMs", "toEngineMs", "toIndicatorMs"]
        var parts: [String] = []
        for stage in Stage.allCases.dropFirst() {
            guard let t = times[stage.rawValue] else { return nil }
            let ms = max(0, Int(((t - start) * 1000).rounded()))
            parts.append("\(labels[stage.rawValue - 1])=\(ms)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Cross-leg session timing (Task 0, K-52–K-58 plan Appendix B)

/// Immutable snapshot of one recording session's low-overhead timing stamps.
/// Timestamps are absolute `CFAbsoluteTime`s (timings only, never content —
/// SECURITY.md policy allows integer-ms deltas as `privacy: .public`).
struct SessionTimingSnapshot: Sendable, Equatable {
    var engineStartAt: CFAbsoluteTime?
    var firstBufferAt: CFAbsoluteTime?
    var transportTag: String
}

/// One-time-per-session timing stamps shared between the main actor (session
/// bookkeeping) and the audio tap thread (first captured input buffer).
///
/// Concurrency posture: the tap thread pays one uncontended `os_unfair_lock`
/// acquisition per buffer (~tens of ns — three orders of magnitude below the
/// 1 ms resolution of every value reported from these stamps). Steady-state
/// rendering stays non-blocking in effect; deliberate trade-off reviewed
/// against the render-thread rule documented in DEVELOPER_GUIDE.md.
///
/// Semantics: `beginSession()` clears both timestamps (transport tag survives
/// — it describes the bound graph, re-resolved only when the graph rebuilds).
/// `markEngineStart` records the LATEST successful start (recovery re-starts
/// supersede); `markFirstBufferIfNeeded` records ONLY the first buffer.
final class SessionTimingMarks: @unchecked Sendable {
    private var mutex = os_unfair_lock()
    private var engineStartAt: CFAbsoluteTime?
    private var firstBufferAt: CFAbsoluteTime?
    private var transportTag: String

    init(initialTransportTag: String = AudioTransportTag.unknown) {
        self.transportTag = initialTransportTag
    }

    /// Clears both session timestamps at capture-session start.
    func beginSession() {
        os_unfair_lock_lock(&mutex)
        defer { os_unfair_lock_unlock(&mutex) }
        engineStartAt = nil
        firstBufferAt = nil
    }

    /// Records when the capture engine became usable for THIS session. Later
    /// marks win (recovery re-start path); explicit `time` injection mirrors
    /// `RecordingStartLatencyProbe.markWithTime` for headless testing.
    func markEngineStart(at time: CFAbsoluteTime? = nil) {
        os_unfair_lock_lock(&mutex)
        defer { os_unfair_lock_unlock(&mutex) }
        engineStartAt = time ?? CFAbsoluteTimeGetCurrent()
    }

    /// Records the FIRST input buffer only. Subsequent calls (every remaining
    /// tap callback of the session) observe a non-nil stamp and exit.
    func markFirstBufferIfNeeded(at time: CFAbsoluteTime? = nil) {
        os_unfair_lock_lock(&mutex)
        defer { os_unfair_lock_unlock(&mutex) }
        guard firstBufferAt == nil else { return }
        firstBufferAt = time ?? CFAbsoluteTimeGetCurrent()
    }

    func setTransportTag(_ tag: String) {
        os_unfair_lock_lock(&mutex)
        defer { os_unfair_lock_unlock(&mutex) }
        transportTag = tag
    }

    func snapshot() -> SessionTimingSnapshot {
        os_unfair_lock_lock(&mutex)
        defer { os_unfair_lock_unlock(&mutex) }
        return SessionTimingSnapshot(
            engineStartAt: engineStartAt,
            firstBufferAt: firstBufferAt,
            transportTag: transportTag
        )
    }
}

/// Mic-transport classification for latency baselines (built-in / USB /
/// Bluetooth buckets match the plan's Appendix B route columns). The numeric
/// lookup reuses the same CoreAudio selector the settings layer reads
/// (`kAudioDevicePropertyTransportType`) but answers for an already-bound
/// `AudioDeviceID`, so session logging never re-enumerates devices.
enum AudioTransportTag {
    static let unknown = "unknown"

    static func label(forTransportType transportType: UInt32?) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "builtin"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAutoAggregate:
            return "virtual"
        case .none:
            return unknown
        case .some:
            return "other"
        }
    }

    /// One-shot CoreAudio query. Errors/absence classify as `"unknown"`
    /// rather than guessing from the device name.
    static func label(forDeviceID deviceID: AudioObjectID?) -> String {
        guard let deviceID, deviceID != 0 else { return unknown }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return unknown }
        return label(forTransportType: transport)
    }
}
