import XCTest
@testable import Kalam_test

final class OnboardingSnapshotCacheTests: XCTestCase {
    func testNilTimestampAlwaysRebuilds() {
        XCTAssertFalse(OnboardingSnapshotCacheDecision.shouldReuse(
            cachedAt: nil, now: Date(), maxAgeSeconds: 2.0))
    }

    func testFreshCacheReused() {
        XCTAssertTrue(OnboardingSnapshotCacheDecision.shouldReuse(
            cachedAt: Date(timeIntervalSinceNow: -0.5), now: Date(), maxAgeSeconds: 2.0))
    }

    func testExpiredCacheRebuilds() {
        XCTAssertFalse(OnboardingSnapshotCacheDecision.shouldReuse(
            cachedAt: Date(timeIntervalSinceNow: -2.1), now: Date(), maxAgeSeconds: 2.0))
    }

    func testZeroMaxAgeNeverReuses() {
        let now = Date()
        XCTAssertFalse(OnboardingSnapshotCacheDecision.shouldReuse(
            cachedAt: now, now: now, maxAgeSeconds: 0))
    }
}
