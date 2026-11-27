import CoreAudio
import XCTest
@testable import Kalam_test

// microphone recovery after sleep or device change: device-change bursts (dock reconnect churn) must coalesce into one
// refresh; wake must fire immediately, NOT debounced. @MainActor: the
// monitor is MainActor-isolated (dictionary data-loss edge cases pattern).
@MainActor
final class AudioDeviceMonitorTests: XCTestCase {
    func testRegistersReadableSelectorsAndRemovesEveryRegistration() {
        var added: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        var removed: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        let device: AudioDeviceID = 67
        let properties = AudioDeviceMonitor.PropertyIO(
            add: { object, address, _ in added.append((object, address)); return noErr },
            remove: { object, address, _ in removed.append((object, address)) },
            defaultInput: { device }
        )
        let monitor = AudioDeviceMonitor(properties: properties)
        monitor.start(onDeviceChange: {}, onWake: {})
        monitor.stop()

        let system = AudioObjectID(kAudioObjectSystemObject)
        XCTAssertEqual(added.map(\.0), [system, system, device])
        XCTAssertEqual(added.map { $0.1.mSelector }, [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
            kAudioDevicePropertyDeviceIsAlive
        ])
        XCTAssertTrue(added.allSatisfy { $0.1.mScope == kAudioObjectPropertyScopeGlobal })
        XCTAssertEqual(removed.map(\.0), added.map(\.0))
        XCTAssertEqual(removed.map { $0.1.mSelector }, added.map { $0.1.mSelector })
    }

    func testAliveListenerStaysOnTheRecordingDeviceAcrossDefaultSwitch() async {
        var defaultInput: AudioDeviceID = 10
        var alive: [AudioDeviceID: Bool] = [99: true]
        var monitored: [AudioDeviceID] = []
        let properties = AudioDeviceMonitor.PropertyIO(
            add: { object, address, _ in
                if address.mSelector == kAudioDevicePropertyDeviceIsAlive { monitored.append(object) }
                return noErr
            },
            remove: { _, _, _ in },
            defaultInput: { defaultInput },
            isAlive: { alive[$0] }
        )
        let monitor = AudioDeviceMonitor(debounceInterval: 0, properties: properties)
        let changed = expectation(description: "default input changed")
        monitor.start(onDeviceChange: { changed.fulfill() }, onWake: {})
        defer { monitor.stop() }
        monitor.trackRecordingDevice(99)
        defaultInput = 20
        monitor.fireDevicesChangedForTesting()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(monitored, [10, 99])
        XCTAssertEqual(monitor.recordingDeviceIsAlive, true)
        alive[99] = false
        XCTAssertEqual(monitor.recordingDeviceIsAlive, false)
        monitor.trackRecordingDevice(nil)
        XCTAssertEqual(monitored, [10, 99, 20])
    }

    func testTopologyChangesDoNotRebuildAnOwnedGraph() {
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: true, recording: false, draining: false,
                                                            streamIsLive: false), .abandonPendingStart)
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: false, recording: true, draining: false,
                                                            streamIsLive: true), .deferRebuild)
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: false, recording: true, draining: false,
                                                            streamIsLive: false), .finishCapture)
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: false, recording: false, draining: true,
                                                            streamIsLive: true), .deferRebuild)
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: false, recording: false, draining: true,
                                                            streamIsLive: false), .finishDrain)
        XCTAssertEqual(AudioInputTopologyAction.afterChange(starting: false, recording: false, draining: false,
                                                            streamIsLive: false), .rebuildGraph)
    }

    func testDebounceCoalescesBurstOfDeviceEvents() async throws {
        let monitor = makeMonitor(debounceInterval: 0.05)
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
        let monitor = makeMonitor(debounceInterval: 10) // long debounce: wake must NOT wait
        let fired = expectation(description: "wake fired")
        monitor.start(onDeviceChange: {}, onWake: { fired.fulfill() })
        monitor.fireWakeForTesting()
        await fulfillment(of: [fired], timeout: 1.0)
        monitor.stop()
    }

    func testStopCancelsPendingDebounce() {
        let monitor = makeMonitor(debounceInterval: 0.05)
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        monitor.start(onDeviceChange: { fired.fulfill() }, onWake: {})
        monitor.fireDevicesChangedForTesting()
        monitor.stop()
        wait(for: [fired], timeout: 0.2)
    }

    private func makeMonitor(debounceInterval: TimeInterval) -> AudioDeviceMonitor {
        AudioDeviceMonitor(debounceInterval: debounceInterval, properties: .init(
            add: { _, _, _ in noErr },
            remove: { _, _, _ in },
            defaultInput: { kAudioObjectUnknown }
        ))
    }

}
