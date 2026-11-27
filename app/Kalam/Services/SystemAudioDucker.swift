import Foundation
import CoreAudio
import AudioToolbox
import OSLog

// Float clamp helper
private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - SystemAudioDucker

@MainActor
final class SystemAudioDucker {
    static let shared = SystemAudioDucker()
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "SystemAudioDucker")
    private let capabilitiesProvider: () -> RuntimeCapabilities

    struct VolumeIO {
        var defaultOutput: @MainActor () -> AudioDeviceID = SystemAudioDucker.getDefaultOutputDevice
        var uid: @MainActor (AudioDeviceID) -> String? = AudioDeviceDebug.deviceUID(for:)
        var read: @MainActor (AudioDeviceID) -> Float? = SystemAudioDucker.getVirtualMainVolume
        var write: @MainActor (AudioDeviceID, Float) -> Bool = SystemAudioDucker.setVirtualMainVolume
    }

    private let volume: VolumeIO
    private let isEnabled: () -> Bool

    init(
        capabilitiesProvider: @escaping () -> RuntimeCapabilities = RuntimeCapabilities.current,
        volume: VolumeIO = VolumeIO(),
        isEnabled: @escaping () -> Bool = { GeneralSettingsConfiguration.load().muteWhileRecording }
    ) {
        self.capabilitiesProvider = capabilitiesProvider
        self.volume = volume
        self.isEnabled = isEnabled
    }

    private struct DuckedOutput {
        let id: AudioDeviceID
        let uid: String
        let previousVolume: Float
    }

    private var duckedOutput: DuckedOutput?

    func initialize() {
        let capabilities = capabilitiesProvider()
        Self.logger.info("Runtime capabilities: sandbox=\(capabilities.appSandbox), audioInput=\(capabilities.audioInput), accessibility=\(capabilities.accessibility), outgoingNetwork=\(capabilities.outgoingNetworkClient)")
        if let caveat = capabilities.sandboxedAudioCaveat {
            Self.logger.warning("Manual CoreAudio ducking may be unavailable: \(caveat, privacy: .public)")
        }
    }
    
    func startDucking() {
        guard duckedOutput == nil, isEnabled() else { return }
        let device = volume.defaultOutput()
        guard device != kAudioObjectUnknown,
              let uid = volume.uid(device),
              let previous = volume.read(device), previous > 0,
              volume.write(device, 0) else { return }

        duckedOutput = DuckedOutput(id: device, uid: uid, previousVolume: previous)
        if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("Muted system volume for recording") }
    }

    func stopDucking() {
        guard let output = duckedOutput else { return }
        duckedOutput = nil
        // A reused or unavailable device ID and a user-adjusted volume
        // each invalidate the restore.
        guard volume.uid(output.id) == output.uid, volume.read(output.id) == 0 else { return }
        if volume.write(output.id, output.previousVolume), KalamDiagnosticFlags.verboseAudio {
            Self.logger.debug("Restored system volume after recording")
        }
    }

    // MARK: - CoreAudio Volume Helpers
    
    private static func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        
        if status != noErr {
            Self.logger.warning("Error getting default output device: \(status)")
        }
        return deviceID
    }
    
    private static func getVirtualMainVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0.0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            if KalamDiagnosticFlags.verboseAudio { Self.logger.debug("Device does not support VirtualMainVolume") }
            return nil
        }
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &volume
        )
        
        if status != noErr {
            Self.logger.warning("Error getting volume: \(status)")
            return nil
        }
        return volume
    }
    
    private static func setVirtualMainVolume(for deviceID: AudioDeviceID, volume: Float) -> Bool {
        var newVolume = volume.clamped(to: 0.0...1.0)
        let dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return false }
        
        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            dataSize,
            &newVolume
        )
        
        if status != noErr {
            Self.logger.warning("Error setting volume: \(status)")
        }
        return status == noErr
    }
}
