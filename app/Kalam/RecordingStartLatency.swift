import Foundation
import OSLog

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

    /// Marks relative to an absolute timestamp. Out-of-order marks (earlier than
    /// the previously marked stage) are ignored so a slow AX reply arriving late
    /// can never corrupt the sequence.
    mutating func markWithTime(_ stage: Stage, _ time: CFAbsoluteTime) {
        let index = stage.rawValue
        guard times[0] != nil || index == 0 else { return }
        if index > 0, let previous = times[index - 1], time < previous { return }
        times[index] = time
    }

    /// One-line cumulative deltas from keydown. Nil until every stage marked.
    func summaryLine() -> String? {
        guard let start = times[0] else { return nil }
        let labels = ["toGuardsMs", "toPreparedMs", "toEngineMs", "toIndicatorMs"]
        var parts: [String] = []
        for stage in Stage.allCases.dropFirst() {
            guard let t = times[stage.rawValue] else { return nil }
            let ms = max(0, Int((t - start) * 1000))
            parts.append("\(labels[stage.rawValue - 1])=\(ms)")
        }
        return parts.joined(separator: " ")
    }
}
