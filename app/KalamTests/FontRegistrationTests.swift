import XCTest
import AppKit
import CoreText
@testable import Kalam_test

/// K-31: bundled OFL web fonts for the Compass settings window.
/// Hosted tests: the app launches first (FontRegistration runs at launch), so
/// `Bundle.main` is the app bundle and the faces are already registered process-wide.
final class FontRegistrationTests: XCTestCase {

    func testBundledFontsRegisterCleanly() {
        let result = FontRegistration.registerBundledFonts()
        XCTAssertEqual(result.failed, 0, "no bundled font should fail registration")
        XCTAssertGreaterThanOrEqual(
            result.registered + result.alreadyRegistered, 6,
            "all six bundled faces must be registered (or already registered)"
        )
    }

    func testAllSixFacesResolve() {
        for name in [
            "InstrumentSerif-Regular", "InstrumentSerif-Italic",
            "PlusJakartaSans-Regular",
            "IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold",
        ] {
            XCTAssertNotNil(NSFont(name: name, size: 14), "face \(name) must resolve after registration")
        }
    }

    func testPlusJakartaSansResolvesExactNonStandardWeights() {
        guard let base = NSFont(name: "PlusJakartaSans-Regular", size: 14) else {
            return XCTFail("PlusJakartaSans-Regular missing")
        }
        // The spec's non-standard weights (560 chapter, 640 card header) must resolve
        // exactly on the variable wght axis — no snapping (K-31 plan §5.3).
        for w in [560.0, 640.0] {
            let desc = base.fontDescriptor.addingAttributes([.variation: ["wght": w]])
            guard let f = NSFont(descriptor: desc, size: 14) else {
                XCTFail("wght \(w) did not resolve")
                continue
            }
            let variation = f.fontDescriptor.object(forKey: .variation) as? [String: Any]
            let actual = variation?["wght"] as? Double
            XCTAssertEqual(actual ?? -1, w, accuracy: 0.001, "wght \(w) must resolve exactly")
        }
    }

    func testInstrumentSerifItalicIsRealItalicFace() {
        guard let f = NSFont(name: "InstrumentSerif-Italic", size: 14) else {
            return XCTFail("InstrumentSerif-Italic missing")
        }
        XCTAssertTrue(
            f.fontDescriptor.symbolicTraits.contains(.italic),
            "Instrument Serif Italic must carry the real italic trait (no faux synthesis)"
        )
    }

    func testBrandFamiliesAvailable() {
        let families = NSFontManager.shared.availableFontFamilies
        for family in ["Instrument Serif", "Plus Jakarta Sans", "IBM Plex Mono"] {
            XCTAssertTrue(families.contains(family), "family \(family) must be registered")
        }
    }
}
