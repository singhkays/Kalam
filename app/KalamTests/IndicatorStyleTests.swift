import XCTest
@testable import Kalam_test

final class IndicatorStyleTests: XCTestCase {

    // MARK: - Raw values

    func testRawValuesAreStable() {
        XCTAssertEqual(IndicatorStyle.machined.rawValue, "machined")
        XCTAssertEqual(IndicatorStyle.whisper.rawValue, "whisper")
        XCTAssertEqual(
            IndicatorStyle.allCases,
            [.machined, .whisper],
            "case order feeds the settings picker; do not reorder casually"
        )
    }

    // MARK: - Migration

    func testMigrationDefaultsUnknownToMachined() {
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: nil), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "rainbow"), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "machined"), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "whisper"), .whisper)
        // Rejected caret style migrates to machined (removed 2026-09-12).
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "caret"), .machined)
    }

    // MARK: - Persistence

    func testConfigRoundTrip() {
        let suiteName = "test.indicatorstyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var config = GeneralSettingsConfiguration.load(from: defaults)
        config.indicatorStyle = .whisper
        config.save(to: defaults)

        let reloaded = GeneralSettingsConfiguration.load(from: defaults)
        XCTAssertEqual(reloaded.indicatorStyle, .whisper)
        XCTAssertEqual(
            defaults.string(forKey: GeneralSettingsKeys.indicatorStylePreset),
            "whisper"
        )
    }

    func testDefaultIsMachined() {
        let suiteName = "test.indicatorstyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = GeneralSettingsConfiguration.load(from: defaults)
        XCTAssertEqual(config.indicatorStyle, .machined)
        XCTAssertNil(
            defaults.string(forKey: GeneralSettingsKeys.indicatorStylePreset),
            "a fresh store must not have written the key yet"
        )
        XCTAssertEqual(config, GeneralSettingsConfiguration.defaults)
    }
}
