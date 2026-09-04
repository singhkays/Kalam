import XCTest
import SwiftUI
@testable import Kalam_test

@MainActor
final class AppearancePreferenceTests: XCTestCase {
    func testMigratingMapsKnownValues() {
        XCTAssertEqual(AppearancePreference.migrating(fromStored: "light"), .light)
        XCTAssertEqual(AppearancePreference.migrating(fromStored: "dark"), .dark)
    }

    func testMigratingDefaultsToSystem() {
        XCTAssertEqual(AppearancePreference.migrating(fromStored: nil), .system)
        XCTAssertEqual(AppearancePreference.migrating(fromStored: "neon"), .system)
    }

    func testOverrideSchemePassesSystemThrough() {
        XCTAssertNil(AppearancePreference.system.overrideScheme)
        XCTAssertEqual(AppearancePreference.light.overrideScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.overrideScheme, .dark)
    }

    func testModelPassthrough() {
        let store = InMemorySettingsStore()
        let model = SettingsModel(store: store)
        model.appearance = .dark
        XCTAssertEqual(store.appearance, .dark)
        XCTAssertEqual(model.appearance, .dark)
    }
}
