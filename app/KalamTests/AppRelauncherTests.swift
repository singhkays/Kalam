import XCTest
@testable import Kalam_test

/// K-12 regression pins for the relaunch orchestration.
///
/// The pre-K-12 code (`open -n` + unconditional `exit(0)`) had two defects
/// this suite pins against:
/// 1. `exit(0)` ran even when launching the new instance FAILED — the app
///    disappeared with no way to retry.
/// 2. `exit(0)` skipped the orderly termination lifecycle
///    (`applicationWillTerminate`: transcription-task cancellation, observer
///    removal) that `NSApp.terminate` runs.
///
/// The tests drive `AppRelauncher.relaunch(strategy:)` with injected fake
/// launch/terminate closures (same testable-seam pattern as
/// `PasteService.PasteStrategies`, K-02) — no real processes are spawned.
@MainActor
final class AppRelauncherTests: XCTestCase {

    func testRelaunchTerminatesAfterSuccessfulLaunch() {
        let terminated = expectation(description: "terminate called")
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { _, completion in completion(nil) },
            terminate: { terminated.fulfill() }
        )

        AppRelauncher.relaunch(strategy: strategy)

        // `relaunch` hops to the main queue before terminating; XCTest's
        // `wait(for:)` pumps the main runloop, so the hop executes here.
        wait(for: [terminated], timeout: 2)
    }

    func testRelaunchDoesNotTerminateWhenLaunchFails() {
        // Inverted: this test passes only if terminate is NOT called.
        let mustNotTerminate = expectation(description: "terminate must not be called")
        mustNotTerminate.isInverted = true
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { _, completion in
                completion(NSError(domain: "KalamTests", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "simulated launch failure"]))
            },
            terminate: { mustNotTerminate.fulfill() }
        )

        AppRelauncher.relaunch(strategy: strategy)

        wait(for: [mustNotTerminate], timeout: 1)
    }

    func testRelaunchLaunchesTheMainBundleURL() {
        let launched = expectation(description: "launch called")
        let capture = URLCapture()
        let strategy = AppRelauncher.Strategy(
            launchNewInstance: { url, completion in
                capture.set(url)
                completion(nil)
                launched.fulfill()
            },
            terminate: {}
        )

        AppRelauncher.relaunch(strategy: strategy)

        wait(for: [launched], timeout: 2)
        XCTAssertEqual(capture.url, Bundle.main.bundleURL)
    }
}

/// Swift-6-safe holder for a URL captured inside a `@Sendable` closure (same
/// pattern as `StallMeter` in `AudioCaptureExchangeTests`).
private final class URLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    func set(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        _url = url
    }
    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _url
    }
}
