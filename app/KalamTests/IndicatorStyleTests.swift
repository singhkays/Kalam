import XCTest
@testable import Kalam_test

final class IndicatorStyleTests: XCTestCase {

    // MARK: - Raw values

    func testRawValuesAreStable() {
        XCTAssertEqual(IndicatorStyle.machined.rawValue, "machined")
        XCTAssertEqual(IndicatorStyle.whisper.rawValue, "whisper")
        XCTAssertEqual(IndicatorStyle.caret.rawValue, "caret")
        XCTAssertEqual(
            IndicatorStyle.allCases,
            [.machined, .whisper, .caret],
            "case order feeds the settings picker; do not reorder casually"
        )
    }

    // MARK: - Migration

    func testMigrationDefaultsUnknownToMachined() {
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: nil), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "rainbow"), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "machined"), .machined)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "whisper"), .whisper)
        XCTAssertEqual(IndicatorStyle.migrating(fromStored: "caret"), .caret)
    }

    // MARK: - Persistence

    func testConfigRoundTrip() {
        let suiteName = "test.indicatorstyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var config = GeneralSettingsConfiguration.load(from: defaults)
        config.indicatorStyle = .caret
        config.save(to: defaults)

        let reloaded = GeneralSettingsConfiguration.load(from: defaults)
        XCTAssertEqual(reloaded.indicatorStyle, .caret)
        XCTAssertEqual(
            defaults.string(forKey: GeneralSettingsKeys.indicatorStylePreset),
            "caret"
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
