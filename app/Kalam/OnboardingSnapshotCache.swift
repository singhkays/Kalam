import Foundation

/// Pure freshness decision for the per-press onboarding snapshot cache.
/// Headless-testable; the AppDelegate owns the actual cached value and
/// invalidation wiring.
enum OnboardingSnapshotCacheDecision {
    static func shouldReuse(cachedAt: Date?, now: Date, maxAgeSeconds: TimeInterval) -> Bool {
        guard let cachedAt else { return false }
        return now.timeIntervalSince(cachedAt) < maxAgeSeconds
    }
}
