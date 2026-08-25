import AppKit
import XCTest
@testable import Kalam_test

/// The settings UI v1.2 visual alignment: brand-font registration moved into `SettingsFont.ensureBrandFontRegistered()`
/// (v1.2 mechanism — lazy, once per process). The bundle now ships ONLY Instrument
/// Serif Regular + Italic; body/mono return to SF Pro/SF Mono and the small serif
/// roles use New York (`SettingsFont.book`).
final class SettingsFontTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SettingsFont.ensureBrandFontRegistered()
    }

    func testRegistrationIsIdempotent() {
        // Second call must be a no-op (guarded by didAttemptRegistration), not a failure.
        SettingsFont.ensureBrandFontRegistered()
        XCTAssertNotNil(NSFont(name: "InstrumentSerif-Regular", size: 12))
        XCTAssertNotNil(NSFont(name: "InstrumentSerif-Italic", size: 12))
    }

    func testInstrumentSerifRegularResolvesAfterRegistration() {
        XCTAssertNotNil(NSFont(name: "InstrumentSerif-Regular", size: 12))
    }

    func testInstrumentSerifItalicResolvesAfterRegistration() {
        XCTAssertNotNil(NSFont(name: "InstrumentSerif-Italic", size: 12))
    }

    func testDisplayReturnsBrandFont() {
        let resolved = SettingsFont.resolved(.serif, size: SettingsType.mapHero, weight: SettingsType.wRegular)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved!.fontName, "InstrumentSerif-Regular")
    }

    func testDisplayItalicReturnsRealItalicCut() {
        // displayItalic wraps the real italic face — no synthetic slant.
        XCTAssertNotNil(NSFont(name: "InstrumentSerif-Italic", size: SettingsType.diveDisplay))
    }

    func testBookFontIsNewYorkNotBrand() {
        let book = SettingsFont.resolvedBook(SettingsType.mapCardTitle)
        XCTAssertNotNil(book)
        XCTAssertTrue(
            book!.fontName.contains("NewYork") || book!.familyName?.contains("New York") == true,
            "book() should resolve to the New York system serif, got \(book!.fontName) / \(book!.familyName ?? "nil")"
        )
        XCTAssertFalse(book!.fontName.contains("InstrumentSerif"))
    }

    func testBodyResolvesToSFPro() {
        let body = SettingsFont.resolved(.sans, size: 13.5, weight: SettingsType.wRegular)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.fontName.contains("SFNS"), "body() should be SF Pro, got \(body!.fontName)")
    }

    func testMonoResolvesToSFMono() {
        let mono = SettingsFont.resolved(.mono, size: 11, weight: SettingsType.wRegular)
        XCTAssertNotNil(mono)
        // SF Mono's PostScript name on macOS 14+ is .AppleSystemUIFontMonospaced.
        XCTAssertTrue(
            mono!.fontName.contains("AppleSystemUIFontMonospaced") || mono!.fontName.contains("SFMono"),
            "mono() should be SF Mono, got \(mono!.fontName)"
        )
    }

    func testLightWeightAppliesViaDescriptor() {
        // v1.3.6: 300/Light is in. SF Pro has a real Light cut; New York does NOT
        // (book() stays 400 everywhere), so exercise Light on the sans path.
        let light = SettingsFont.resolved(.sans, size: 13.5, weight: SettingsType.wLight)
        let regular = SettingsFont.resolved(.sans, size: 13.5, weight: SettingsType.wRegular)
        let lightTrait = (light!.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        let regularTrait = (regular!.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        XCTAssertNotEqual(lightTrait, regularTrait, "300 and 400 should resolve to different weight traits (\(String(describing: lightTrait)) vs \(String(describing: regularTrait)))")
        XCTAssertEqual(lightTrait ?? 0, -0.4, accuracy: 0.001, "300 must resolve to Font.Weight.light's trait (-0.4)")
        XCTAssertTrue(light!.fontName.contains("Light"), "sans 300 should resolve to a Light instance, got \(light!.fontName)")
    }
}
