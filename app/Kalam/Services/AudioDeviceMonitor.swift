import AppKit
import CoreAudio
import Foundation
import OSLog

/// Watches for audio input topology changes (device plug/unplug, default-input
/// switches, device death) and system wake events. Kalam uses it to re-prepare
/// the AVAudioEngine input graph after sleep/wake and dock reconnects — without
/// it the engine stays bound to a stale CoreAudio device until the user
/// manually reorders microphones (K-26).
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

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    func start(onDeviceChange: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onDeviceChange = onDeviceChange
        self.onWake = onWake
        registerHardwareListeners()
        registerWakeObserver()
        updateAliveListener()
    }

    func stop() {
        for listener in registeredListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        registeredListeners.removeAll()
        if let aliveListener {
            var address = aliveListener.address
            AudioObjectRemovePropertyListenerBlock(aliveListener.object, &address, DispatchQueue.main, aliveListener.block)
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
        // The *Changed notification selectors are not exposed to Swift in
        // current SDKs — use the four-char codes directly:
        //   'dfch' = kAudioHardwarePropertyDefaultInputDeviceChanged
        //   'devc' = kAudioHardwarePropertyDevicesChanged
        let selectors: [AudioObjectPropertySelector] = [
            AudioObjectPropertySelector(0x64666368),
            AudioObjectPropertySelector(0x64657663)
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
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

    /// Re-arms the device-alive listener on the current default input device
    /// (the one Kalam would record from when no explicit mic is chosen).
    private func updateAliveListener() {
        let deviceID = Self.defaultInputDeviceID()
        if let aliveListener, aliveListener.object == deviceID {
            return
        }
        if let aliveListener {
            var address = aliveListener.address
            AudioObjectRemovePropertyListenerBlock(aliveListener.object, &address, DispatchQueue.main, aliveListener.block)
            self.aliveListener = nil
        }
        guard deviceID != kAudioObjectUnknown else { return }
        // kAudioDevicePropertyDeviceIsAliveChanged ('alvc') is not exposed to
        // Swift in current SDKs — use the four-char code directly.
        let aliveChangedSelector = AudioObjectPropertySelector(0x616C7663)
        var address = AudioObjectPropertyAddress(
            mSelector: aliveChangedSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status == noErr {
            aliveListener = (deviceID, address, block)
        } else {
            logger.warning("Failed to register device-alive listener status=\(status, privacy: .public)")
        }
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
