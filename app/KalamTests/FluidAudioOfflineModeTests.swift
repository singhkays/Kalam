import XCTest
@preconcurrency import FluidAudio
@testable import Kalam_test

/// FluidAudio 0.15.5 adoption regression tests.
/// See app/docs/dev-design/2026-08-11-fluidaudio-0.15.x-adoption.md.
///
/// Kalam has no network entitlement (hard convention). Without
/// `ModelHub.offlineMode`, a failed `AsrModels.load` triggers ModelHub's
/// delete-cache-and-redownload fallback — a HuggingFace fetch that cannot
/// succeed in the sandbox and would leave the user's model library deleted.
/// These tests pin the enforcement at both entry points: the app launch
/// (AppDelegate) and ASRService's loader chokepoint.
final class FluidAudioOfflineModeTests: XCTestCase {

    /// The test host runs `applicationDidFinishLaunching` before tests, which
    /// calls `ASRService.enforceOfflineMode()`. If this fails, the AppDelegate
    /// wiring regressed.
    func testAppLaunchEnforcesOfflineMode() {
        XCTAssertTrue(
            ModelHub.offlineMode,
            "AppDelegate must set ModelHub.offlineMode = true at launch (no network entitlement)"
        )
    }

    /// ASRService.initialize is the loader chokepoint; it must re-assert the
    /// flag defensively even if a future launch path skips the AppDelegate call.
    func testASRServiceEnforceOfflineModeIsIdempotent() {
        ModelHub.offlineMode = false
        ASRService.enforceOfflineMode()
        XCTAssertTrue(ModelHub.offlineMode)

        // Idempotent: calling again keeps it true.
        ASRService.enforceOfflineMode()
        XCTAssertTrue(ModelHub.offlineMode)
    }
}
