import CoreAudio
import XCTest
@testable import Kalam_test

@MainActor
final class SystemAudioDuckerTests: XCTestCase {
    func testOutputSwapRestoresOnlyOriginalDevice() {
        let output = VolumeFixture()
        let ducker = output.makeDucker()
        ducker.startDucking()
        output.device = 2
        ducker.stopDucking()

        XCTAssertEqual(output.volumes, [1: 0.6, 2: 0.8])
        XCTAssertEqual(output.writes, [1, 1])
    }

    func testVolumeChangedByUserIsPreserved() {
        let output = VolumeFixture()
        let ducker = output.makeDucker()
        ducker.startDucking()
        output.volumes[1] = 0.25
        ducker.stopDucking()

        XCTAssertEqual(output.volumes[1], 0.25)
        XCTAssertEqual(output.writes, [1])
    }

    func testAReusedDeviceIDDoesNotReceiveSavedVolume() {
        let output = VolumeFixture()
        let ducker = output.makeDucker()
        ducker.startDucking()
        output.uids[1] = "replacement device"
        ducker.stopDucking()

        XCTAssertEqual(output.writes, [1])
        XCTAssertEqual(output.volumes[1], 0)
    }

    func testRejectedMuteDoesNotLeaveAStaleRestore() {
        let output = VolumeFixture()
        let ducker = output.makeDucker()
        output.rejectsWrites = true
        ducker.startDucking()
        output.rejectsWrites = false
        output.volumes[1] = 0
        ducker.stopDucking()

        XCTAssertEqual(output.writes, [1])
        XCTAssertEqual(output.volumes[1], 0)
    }

}

@MainActor
private final class VolumeFixture {
    var device: AudioDeviceID = 1
    var volumes: [AudioDeviceID: Float] = [1: 0.6, 2: 0.8]
    var writes: [AudioDeviceID] = []
    var uids: [AudioDeviceID: String] = [1: "speakers", 2: "headphones"]
    var rejectsWrites = false

    func makeDucker() -> SystemAudioDucker {
        SystemAudioDucker(volume: .init(
            defaultOutput: { self.device },
            uid: { self.uids[$0] },
            read: { self.volumes[$0] },
            write: { device, volume in
                self.writes.append(device)
                guard !self.rejectsWrites else { return false }
                self.volumes[device] = volume
                return true
            }
        ), isEnabled: { true })
    }
}
