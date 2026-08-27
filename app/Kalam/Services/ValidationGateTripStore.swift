import Foundation
import KalamTextEngine

/// App-side rolling trip counter for ValidationGate (K-55 / Task 4).
/// - Persists trips in UserDefaults as [TimeInterval] (unix epoch).
/// - Window 86,400 s (24h), threshold 3 trips.
/// - Degraded flag is runtime until relaunch or manual reset / success-streak.
/// - Posts `didAutoDegrade` exactly once per degrade episode.
/// - `successStreak` resets degraded after N consecutive accepts (N=5).
final class ValidationGateTripStore: @unchecked Sendable {
    static let didAutoDegrade = Notification.Name("validationGateAutoDegraded")

    private let defaults: UserDefaults
    private let now: () -> Date
    private let windowSeconds: TimeInterval = 86_400
    private let degradeThreshold = 3
    private let successStreakReset = 5

    private let tripsKey = "validationGate.trips"
    private let degradedKey = "validationGate.isDegraded"
    private let successStreakKey = "validationGate.successStreak"
    private let lock = NSLock()
    private var hasPostedDegradeForCurrentEpisode = false

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        // hasPostedDegradeForCurrentEpisode is per-process, not persisted
        self.hasPostedDegradeForCurrentEpisode = (defaults.bool(forKey: degradedKey) == true)
    }

    var isDegraded: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: degradedKey)
    }

    func record(_ verdict: GateVerdict) {
        lock.lock()
        defer { lock.unlock() }
        switch verdict {
        case .accept:
            var streak = defaults.integer(forKey: successStreakKey)
            streak += 1
            defaults.set(streak, forKey: successStreakKey)
            if streak >= successStreakReset {
                // Success streak resets degraded + trips
                defaults.removeObject(forKey: tripsKey)
                defaults.removeObject(forKey: degradedKey)
                defaults.removeObject(forKey: successStreakKey)
                hasPostedDegradeForCurrentEpisode = false
            }
        case .reject:
            // Reset success streak
            defaults.set(0, forKey: successStreakKey)
            // Append trip, filter window
            var trips = (defaults.array(forKey: tripsKey) as? [Double]) ?? []
            let nowT = now().timeIntervalSince1970
            trips.append(nowT)
            // Filter to window
            let cutoff = nowT - windowSeconds
            trips = trips.filter { $0 >= cutoff }
            defaults.set(trips, forKey: tripsKey)
            if trips.count >= degradeThreshold && !defaults.bool(forKey: degradedKey) {
                defaults.set(true, forKey: degradedKey)
                if !hasPostedDegradeForCurrentEpisode {
                    hasPostedDegradeForCurrentEpisode = true
                    NotificationCenter.default.post(name: Self.didAutoDegrade, object: nil)
                }
            }
        }
    }

    /// Manual reset — clears trips, degraded, streak, and resets episode flag.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: tripsKey)
        defaults.removeObject(forKey: degradedKey)
        defaults.removeObject(forKey: successStreakKey)
        hasPostedDegradeForCurrentEpisode = false
    }

    /// For tests: inject trips directly
    func _setTripsForTesting(_ timestamps: [Date]) {
        lock.lock()
        defer { lock.unlock() }
        let doubles = timestamps.map { $0.timeIntervalSince1970 }
        defaults.set(doubles, forKey: tripsKey)
    }

    func _tripsCountForTesting() -> Int {
        let arr = (defaults.array(forKey: tripsKey) as? [Double]) ?? []
        let nowT = now().timeIntervalSince1970
        let cutoff = nowT - windowSeconds
        return arr.filter { $0 >= cutoff }.count
    }
}
