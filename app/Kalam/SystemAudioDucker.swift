import AppKit
import AudioToolbox
import CoreAudio
import Foundation
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
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "SystemAudioDucker")
    private let capabilitiesProvider: () -> RuntimeCapabilities

    private init(capabilitiesProvider: @escaping () -> RuntimeCapabilities = RuntimeCapabilities.current) {
        self.capabilitiesProvider = capabilitiesProvider
    }
    
    private var duckingActive = false
    private var preDuckingVolume: Float? = nil
    
    func initialize() {
        let capabilities = capabilitiesProvider()
        logger.info("Runtime capabilities: sandbox=\(capabilities.appSandbox), audioInput=\(capabilities.audioInput), accessibility=\(capabilities.accessibility), outgoingNetwork=\(capabilities.outgoingNetworkClient)")
        if let caveat = capabilities.sandboxedAudioCaveat {
            logger.warning("Manual CoreAudio ducking may be unavailable: \(caveat, privacy: .public)")
        }
    }
    
    func startDucking() {
        guard !duckingActive else { return }
        guard GeneralSettingsConfiguration.load().muteWhileRecording else { return }
        
        duckingActive = true
        logger.info("Muting system volume for recording")
        
        let deviceID = getDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }
        
        if let currentVolume = getVirtualMainVolume(for: deviceID) {
            preDuckingVolume = currentVolume
            setVirtualMainVolume(for: deviceID, volume: 0.0)
        }
    }
    
    func stopDucking(cancelOnly: Bool = false) {
        guard duckingActive else { return }
        duckingActive = false
        logger.info("Restoring system volume after recording")
        
        guard let savedVolume = preDuckingVolume else { return }
        let deviceID = getDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }
        
        setVirtualMainVolume(for: deviceID, volume: savedVolume)
        preDuckingVolume = nil
    }
    
    // MARK: - CoreAudio Volume Helpers
    
    private func getDefaultOutputDevice() -> AudioDeviceID {
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
            logger.warning("Error getting default output device: \(status)")
        }
        return deviceID
    }
    
    private func getVirtualMainVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0.0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            logger.info("Device does not support VirtualMainVolume")
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
            logger.warning("Error getting volume: \(status)")
            return nil
        }
        return volume
    }
    
    private func setVirtualMainVolume(for deviceID: AudioDeviceID, volume: Float) {
        var newVolume = volume.clamped(to: 0.0...1.0)
        let dataSize = UInt32(MemoryLayout<Float>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return }
        
        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            dataSize,
            &newVolume
        )
        
        if status != noErr {
            logger.warning("Error setting volume: \(status)")
        }
    }
}
