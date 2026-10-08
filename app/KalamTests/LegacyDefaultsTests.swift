import XCTest
@testable import Kalam_test

/// Dead-key sweep for removed features (K-55/K-57/K-58, cut 2026-10-02).
final class LegacyDefaultsTests: XCTestCase {
    private let suiteName = "LegacyDefaultsTests.ephemeral"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        for key in ["retention.enabled", "validationGate.isDegraded", "validationGate.trips",
                    "validationGate.successStreak", "fnAdvisor.lastNotifiedReason", "fnAdvisor.lastShouldAdvise",
                    "general.showInDock"] {
            defaults.set(true, forKey: key)
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRemoveLegacyDefaultsClearsOnlyDeadKeys() {
        AppDelegate.removeLegacyDefaults(defaults)
        for key in ["retention.enabled", "validationGate.isDegraded", "validationGate.trips",
                    "validationGate.successStreak", "fnAdvisor.lastNotifiedReason", "fnAdvisor.lastShouldAdvise"] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must be swept")
        }
        XCTAssertNotNil(defaults.object(forKey: "general.showInDock"), "live keys must survive the sweep")
    }

    func testRemoveLegacyDefaultsIsIdempotent() {
        AppDelegate.removeLegacyDefaults(defaults)
        AppDelegate.removeLegacyDefaults(defaults) // must not throw or touch live keys
        XCTAssertNotNil(defaults.object(forKey: "general.showInDock"))
    }
}
