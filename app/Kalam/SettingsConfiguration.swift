import Foundation
import AppKit
import CoreAudio
import AudioToolbox

enum GeneralSettingsKeys {
    static let launchAtLogin = "general.launchAtLogin"
    static let showInDock = "general.showInDock"
    static let escapeCancelsRecording = "general.escapeCancelsRecording"
    static let indicatorPlacementPreset = "general.indicatorPlacementPreset"
    static let selectedInputUID = "audio.selectedInputDeviceUID"
    static let muteWhileRecording = "general.muteWhileRecording"
}

enum IndicatorPlacementPreset: String, CaseIterable, Equatable {
    case topCenter
    case bottomCenter

    var title: String {
        switch self {
        case .topCenter:
            return "Top Center"
        case .bottomCenter:
            return "Bottom Center"
        }
    }
}

struct GeneralSettingsConfiguration: Equatable {
    static let defaults = GeneralSettingsConfiguration(
        launchAtLogin: false,
        showInDock: true,
        escapeCancelsRecording: false,
        indicatorPlacementPreset: .topCenter,
        muteWhileRecording: true
    )

    var launchAtLogin: Bool
    var showInDock: Bool
    var escapeCancelsRecording: Bool
    var indicatorPlacementPreset: IndicatorPlacementPreset
    var muteWhileRecording: Bool

    static func load(from defaults: UserDefaults = .standard) -> GeneralSettingsConfiguration {
        let presetRaw = defaults.string(forKey: GeneralSettingsKeys.indicatorPlacementPreset) ?? Self.defaults.indicatorPlacementPreset.rawValue
        let preset = IndicatorPlacementPreset(rawValue: presetRaw) ?? Self.defaults.indicatorPlacementPreset
        
        return GeneralSettingsConfiguration(
            launchAtLogin: bool(forKey: GeneralSettingsKeys.launchAtLogin, defaults: defaults, fallback: Self.defaults.launchAtLogin),
            showInDock: bool(forKey: GeneralSettingsKeys.showInDock, defaults: defaults, fallback: Self.defaults.showInDock),
            escapeCancelsRecording: bool(forKey: GeneralSettingsKeys.escapeCancelsRecording, defaults: defaults, fallback: Self.defaults.escapeCancelsRecording),
            indicatorPlacementPreset: preset,
            muteWhileRecording: bool(forKey: GeneralSettingsKeys.muteWhileRecording, defaults: defaults, fallback: Self.defaults.muteWhileRecording)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchAtLogin, forKey: GeneralSettingsKeys.launchAtLogin)
        defaults.set(showInDock, forKey: GeneralSettingsKeys.showInDock)
        defaults.set(escapeCancelsRecording, forKey: GeneralSettingsKeys.escapeCancelsRecording)
        defaults.set(indicatorPlacementPreset.rawValue, forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        defaults.set(muteWhileRecording, forKey: GeneralSettingsKeys.muteWhileRecording)
    }

    func saveAndNotify(to defaults: UserDefaults = .standard) {
        save(to: defaults)
        NotificationCenter.default.post(name: .generalSettingsConfigurationDidChange, object: nil)
    }

    private static func bool(forKey key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

struct MicrophonePriorityConfiguration: Equatable {
    static let defaults = MicrophonePriorityConfiguration(priorityUIDs: [], knownDeviceNames: [:])

    var priorityUIDs: [String]
    var knownDeviceNames: [String: String]

    private static let priorityUIDsKey = "audio.inputPriorityUIDs"
    private static let knownDeviceNamesKey = "audio.inputKnownDeviceNames"

    static func load(from defaults: UserDefaults = .standard) -> MicrophonePriorityConfiguration {
        let uids = defaults.array(forKey: priorityUIDsKey) as? [String] ?? []
        let names = defaults.dictionary(forKey: knownDeviceNamesKey) as? [String: String] ?? [:]
        return MicrophonePriorityConfiguration(priorityUIDs: uids, knownDeviceNames: names)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(priorityUIDs, forKey: Self.priorityUIDsKey)
        defaults.set(knownDeviceNames, forKey: Self.knownDeviceNamesKey)
    }

    func saveAndNotify(to defaults: UserDefaults = .standard) {
        save(to: defaults)
        NotificationCenter.default.post(name: .microphonePriorityDidChange, object: nil)
    }
}

struct MicrophoneDeviceDescriptor: Identifiable, Equatable {
    let id: String // UID
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
    let isAvailable: Bool
    let channelCount: UInt32
}

enum MicrophoneDeviceService {
    static func availableInputDevices() -> [MicrophoneDeviceDescriptor] {
        let infos = (try? AudioDeviceDebug.allInputDeviceInfos()) ?? []
        return infos
        .filter { !$0.isVirtualLike && !$0.isHiddenLike }
        .map {
            MicrophoneDeviceDescriptor(
                id: $0.uid,
                uid: $0.uid,
                name: $0.name,
                deviceID: $0.id,
                isAvailable: true,
                channelCount: $0.inputChannels
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func mergedPriorityList(config: MicrophonePriorityConfiguration) -> [MicrophoneDeviceDescriptor] {
        let available = availableInputDevices()
        let availableByUID = Dictionary(uniqueKeysWithValues: available.map { ($0.uid, $0) })
        var result: [MicrophoneDeviceDescriptor] = []
        var seen = Set<String>()

        for uid in config.priorityUIDs where !seen.contains(uid) {
            if let device = availableByUID[uid] {
                result.append(device)
            } else {
                let fallbackName = config.knownDeviceNames[uid] ?? "Unavailable microphone"
                if shouldFilterPersistedUnavailableDevice(uid: uid, name: fallbackName) {
                    seen.insert(uid)
                    continue
                }
                result.append(
                    MicrophoneDeviceDescriptor(
                        id: uid,
                        uid: uid,
                        name: fallbackName,
                        deviceID: 0,
                        isAvailable: false,
                        channelCount: 0
                    )
                )
            }
            seen.insert(uid)
        }

        for device in available where !seen.contains(device.uid) {
            result.append(device)
            seen.insert(device.uid)
        }

        return result
    }

    static func normalize(config: MicrophonePriorityConfiguration) -> MicrophonePriorityConfiguration {
        let merged = mergedPriorityList(config: config)
        let allowedUIDs = Set(merged.map(\.uid))
        var names = config.knownDeviceNames.filter { allowedUIDs.contains($0.key) }
        for device in merged where device.isAvailable {
            names[device.uid] = device.name
        }
        return MicrophonePriorityConfiguration(
            priorityUIDs: merged.map(\.uid),
            knownDeviceNames: names
        )
    }

    private static func shouldFilterPersistedUnavailableDevice(uid: String, name: String?) -> Bool {
        AudioDeviceDebug.isLikelyVirtualOrAggregate(uid: uid, name: name, transportType: nil)
            || AudioDeviceDebug.isLikelyHiddenDevice(uid: uid, name: name)
    }
}

extension Notification.Name {
    static let generalSettingsConfigurationDidChange = Notification.Name("generalSettingsConfigurationDidChange")
    static let microphonePriorityDidChange = Notification.Name("microphonePriorityDidChange")
    static let openSetupFlow = Notification.Name("openSetupFlow")
}

// MARK: - Audio Device Utilities

enum AudioDeviceDebug {
    struct DeviceInfo {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let nominalSampleRate: Double
        let inputChannels: UInt32
        let transportType: UInt32?
        let isAggregateLike: Bool
        let isHiddenLike: Bool
        let isVirtualLike: Bool
    }
    
    static func logDefaultInputDeviceSummary() {
        let info: DeviceInfo?
        do {
            info = try defaultInputDeviceInfo()
        } catch {
            print("Failed to query default input device: \(error.localizedDescription)")
            info = nil
        }
        if let info = info {
            let isLogitech = info.name.localizedCaseInsensitiveContains("logitech") ||
            info.name.localizedCaseInsensitiveContains("c920")
            print("""
            Input Device:
            - Name: \(info.name)
            - UID: \(info.uid)
            - Channels (in): \(info.inputChannels)
            - Nominal SR: \(info.nominalSampleRate) Hz
            \(isLogitech ? "✅ Detected Logitech C920 (or similar)" : "ℹ️ Not a Logitech C920")
            """)
        } else {
            print("ℹ️ Could not query input device details (non-fatal, proceeding with defaults).")
        }
    }
    
    static func defaultInputDeviceInfo() throws -> DeviceInfo {
        var deviceID = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &deviceID)
        guard status == noErr else { throw error(status) }
        
        let name: String = try getCFString(deviceID, selector: kAudioObjectPropertyName)
        let uid: String = try getCFString(deviceID, selector: kAudioDevicePropertyDeviceUID)
        let sr: Double = try getDouble(deviceID, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioDevicePropertyScopeInput)
        let channels: UInt32 = try getInputChannelCount(deviceID)
        let transportType = try? getUInt32(deviceID, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        let isAggregateLike = (transportType == kAudioDeviceTransportTypeAggregate)
        let isHiddenLike = isLikelyHiddenDevice(uid: uid, name: name)
        let isVirtualLike = isLikelyVirtualOrAggregate(uid: uid, name: name, transportType: transportType)

        return DeviceInfo(
            id: deviceID,
            name: name,
            uid: uid,
            nominalSampleRate: sr,
            inputChannels: channels,
            transportType: transportType,
            isAggregateLike: isAggregateLike,
            isHiddenLike: isHiddenLike,
            isVirtualLike: isVirtualLike
        )
    }

    static func allInputDeviceInfos() throws -> [DeviceInfo] {
        try allDeviceIDs().compactMap { id in
            do {
                let channels = try getInputChannelCount(id)
                guard channels > 0 else { return nil }
                let name = try getCFString(id, selector: kAudioObjectPropertyName)
                let uid = try getCFString(id, selector: kAudioDevicePropertyDeviceUID)
                let sampleRate = (try? getDouble(id, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioDevicePropertyScopeInput)) ?? 0
                let transportType = try? getUInt32(id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
                let isAggregateLike = (transportType == kAudioDeviceTransportTypeAggregate)
                let isHiddenLike = isLikelyHiddenDevice(uid: uid, name: name)
                let isVirtualLike = isLikelyVirtualOrAggregate(uid: uid, name: name, transportType: transportType)
                return DeviceInfo(
                    id: id,
                    name: name,
                    uid: uid,
                    nominalSampleRate: sampleRate,
                    inputChannels: channels,
                    transportType: transportType,
                    isAggregateLike: isAggregateLike,
                    isHiddenLike: isHiddenLike,
                    isVirtualLike: isVirtualLike
                )
            } catch {
                return nil
            }
        }
    }

    static func isLikelyVirtualOrAggregate(uid: String, name: String?, transportType: UInt32?) -> Bool {
        if transportType == kAudioDeviceTransportTypeAggregate || transportType == kAudioDeviceTransportTypeVirtual {
            return true
        }

        let haystack = "\(uid) \(name ?? "")".lowercased()
        let virtualHints = [
            "cadefaultdeviceaggregate",
            "aggregate",
            "blackhole",
            "soundflower",
            "loopback",
            "vb-cable",
            "virtual"
        ]
        return virtualHints.contains { haystack.contains($0) }
    }

    static func isLikelyHiddenDevice(uid: String, name: String?) -> Bool {
        let haystack = "\(uid) \(name ?? "")".lowercased()
        let hiddenHints = [
            "process tap",
            "system sounds",
            "null"
        ]
        return hiddenHints.contains { haystack.contains($0) }
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let statusSize = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard statusSize == noErr else { throw error(statusSize) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let statusData = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard statusData == noErr else { throw error(statusData) }
        return ids
    }
    
    private static func getCFString(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr else { throw error(status) }
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { value.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, value)
        guard status == noErr, let cf = value.pointee else { throw error(status) }
        return cf as String
    }
    
    private static func getDouble(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var val = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &val)
        guard status == noErr else { throw error(status) }
        return val
    }

    private static func getUInt32(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &val)
        guard status == noErr else { throw error(status) }
        return val
    }
    
    private static func getInputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr else { throw error(status) }
        
        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablPtr)
        guard status == noErr else {
            if status == -10877 {
                print("ℹ️ Non-fatal invalid property (-10877) for input channels; assuming default (2).")
                return 2
            }
            throw error(status)
        }
        
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1).pointee
        var count: UInt32 = 0
        
        withUnsafePointer(to: abl) { ptr in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ptr))
            for i in 0 ..< buffers.count {
                count += buffers[i].mNumberChannels
            }
        }
        
        return count
    }
    
    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: "Kalam.AudioDeviceDebug", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "OSStatus \(status)"])
    }
}
