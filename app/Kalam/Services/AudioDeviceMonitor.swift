import AppKit
import CoreAudio
import Foundation
import OSLog

enum AudioInputTopologyAction: Equatable {
    case rebuildGraph
    case abandonPendingStart
    case deferRebuild
    case finishCapture
    case finishDrain

    static func afterChange(
        starting: Bool, recording: Bool, draining: Bool, streamIsLive: @autoclosure () -> Bool
    ) -> Self {
        if starting { return .abandonPendingStart }
        if recording { return streamIsLive() ? .deferRebuild : .finishCapture }
        if draining { return streamIsLive() ? .deferRebuild : .finishDrain }
        return .rebuildGraph
    }
}

/// Watches for audio input topology changes (device plug/unplug, default-input
/// switches, device death) and system wake events. Kalam uses it to re-prepare
/// the AVAudioEngine input graph after sleep/wake and dock reconnects — without
/// it the engine stays bound to a stale CoreAudio device until the user
/// manually reorders microphones (microphone recovery after sleep or device change).
@MainActor
final class AudioDeviceMonitor {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioDevice")

    private var onDeviceChange: (() -> Void)?
    private var onWake: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private var wakeObserver: NSObjectProtocol?
    private var registeredListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var aliveListener: (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?

    struct PropertyIO {
        var add: (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> OSStatus = { object, address, block in
            var address = address
            return AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        var remove: (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> Void = { object, address, block in
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        var defaultInput: @MainActor () -> AudioDeviceID = AudioDeviceMonitor.defaultInputDeviceID
        var isAlive: @MainActor (AudioDeviceID) -> Bool? = AudioDeviceMonitor.deviceIsAlive
    }

    private let properties: PropertyIO
    private var recordingDevice: AudioDeviceID?

    var recordingDeviceIsAlive: Bool? {
        recordingDevice.flatMap(properties.isAlive)
    }

    func trackRecordingDevice(_ id: AudioDeviceID?) {
        recordingDevice = id
        updateAliveListener()
    }

    init(debounceInterval: TimeInterval = 0.5, properties: PropertyIO = PropertyIO()) {
        self.debounceInterval = debounceInterval
        self.properties = properties
    }

    func start(onDeviceChange: @escaping () -> Void, onWake: @escaping () -> Void) {
        stop()
        self.onDeviceChange = onDeviceChange
        self.onWake = onWake
        registerHardwareListeners()
        registerWakeObserver()
        updateAliveListener()
    }

    func stop() {
        onDeviceChange = nil
        onWake = nil
        recordingDevice = nil
        for listener in registeredListeners {
            properties.remove(listener.object, listener.address, listener.block)
        }
        registeredListeners.removeAll()
        if let aliveListener {
            properties.remove(aliveListener.object, aliveListener.address, aliveListener.block)
            self.aliveListener = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Test hooks (bypass CoreAudio registration)

    func fireDevicesChangedForTesting() {
        scheduleRefresh()
    }

    func fireWakeForTesting() {
        handleWake()
    }

    // MARK: - Events

    private func scheduleRefresh() {
        guard onDeviceChange != nil else { return }
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDeviceChange()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func handleDeviceChange() {
        updateAliveListener()
        onDeviceChange?()
    }

    private func handleWake() {
        onWake?()
    }

    // MARK: - CoreAudio registration

    private func registerHardwareListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices
        ]
        for selector in selectors {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
            let status = properties.add(systemObject, address, block)
            if status == noErr {
                registeredListeners.append((systemObject, address, block))
            } else {
                logger.warning("Failed to register audio property listener status=\(status, privacy: .public)")
            }
        }
    }

    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    /// Watch the device bound to the live graph, including a preferred
    /// microphone that differs from the system default.
    private func updateAliveListener() {
        guard onDeviceChange != nil else { return }
        let deviceID = recordingDevice ?? properties.defaultInput()
        if let aliveListener, aliveListener.object == deviceID {
            return
        }
        if let aliveListener {
            properties.remove(aliveListener.object, aliveListener.address, aliveListener.block)
            self.aliveListener = nil
        }
        guard deviceID != kAudioObjectUnknown else { return }
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        let status = properties.add(deviceID, address, block)
        if status == noErr {
            aliveListener = (deviceID, address, block)
        } else {
            logger.warning("Failed to register device-alive listener status=\(status, privacy: .public)")
        }
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool? {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        if status == kAudioHardwareBadObjectError { return false }
        return status == noErr ? alive != 0 : nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return kAudioObjectUnknown
        }
        return deviceID
    }
}
