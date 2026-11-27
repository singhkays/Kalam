import KalamTextEngine
import XCTest
@testable import Kalam_test

/// relaunch lifecycle rework regression pins for the relaunch orchestration.
///
/// The pre-relaunch lifecycle rework code (`open -n` + unconditional `exit(0)`) had two defects
/// this suite pins against:
/// 1. `exit(0)` ran even when launching the new instance FAILED — the app
///    disappeared with no way to retry.
/// 2. `exit(0)` skipped the orderly termination lifecycle
///    (`applicationWillTerminate`: transcription-task cancellation, observer
///    removal) that `NSApp.terminate` runs.
///
/// The tests drive `AppRelauncher.relaunch(strategy:)` with injected fake
/// launch/terminate closures (same testable-seam pattern as
/// `PasteService.PasteStrategies`, clipboard restore on failed paste) — no real processes are spawned.
@MainActor
final class AppRelauncherTests: XCTestCase {

    func testPendingDictionaryIsOnDiskBeforeLaunchingReplacementProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KalamRelaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("dictionary.json")
        let manager = CustomDictionaryManager(storeURL: store, scheduleSave: { _ in })
        manager.bootstrap()
        let rule = DictionaryEntry(trigger: "sam", replacement: "Sam")
        manager.addEntry(rule)
        let launched = expectation(description: "launch is called with completed persistence")

        AppRelauncher.relaunch(strategy: .init(
            launchNewInstance: { _, complete in
                let persisted = try? Data(contentsOf: store)
                let entries = persisted.flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) }
                XCTAssertEqual(entries, [rule])
                launched.fulfill()
                complete(nil)
            },
            terminate: {},
            prepareForLaunch: { manager.flushPendingSave() }
        ))
        wait(for: [launched], timeout: 2)
    }

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
