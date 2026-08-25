import XCTest
@testable import Kalam_test

// microphone recovery after sleep or device change: device-change bursts (dock reconnect churn) must coalesce into one
// refresh; wake must fire immediately, NOT debounced. @MainActor: the
// monitor is MainActor-isolated (dictionary data-loss edge cases pattern).
@MainActor
final class AudioDeviceMonitorTests: XCTestCase {
    func testDebounceCoalescesBurstOfDeviceEvents() async throws {
        let monitor = AudioDeviceMonitor(debounceInterval: 0.05)
        let fired = expectation(description: "device change fired")
        fired.assertForOverFulfill = false
        var count = 0
        monitor.start(onDeviceChange: { count += 1; fired.fulfill() }, onWake: {})
        monitor.fireDevicesChangedForTesting()
        monitor.fireDevicesChangedForTesting()
        monitor.fireDevicesChangedForTesting()
        await fulfillment(of: [fired], timeout: 1.0)
        XCTAssertEqual(count, 1)
        monitor.stop()
    }

    func testWakeFiresImmediately() async throws {
        let monitor = AudioDeviceMonitor(debounceInterval: 10) // long debounce: wake must NOT wait
        let fired = expectation(description: "wake fired")
        monitor.start(onDeviceChange: {}, onWake: { fired.fulfill() })
        monitor.fireWakeForTesting()
        await fulfillment(of: [fired], timeout: 1.0)
        monitor.stop()
    }

    func testStopCancelsPendingDebounce() {
        let monitor = AudioDeviceMonitor(debounceInterval: 0.05)
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        monitor.start(onDeviceChange: { fired.fulfill() }, onWake: {})
        monitor.fireDevicesChangedForTesting()
        monitor.stop()
        wait(for: [fired], timeout: 0.2)
    }
}
