import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import OSLog
import AVFoundation

enum GeneralSettingsKeys {
    static let launchAtLogin = "general.launchAtLogin"
    static let showInDock = "general.showInDock"
    static let escapeCancelsRecording = "general.escapeCancelsRecording"
    static let indicatorPlacementPreset = "general.indicatorPlacementPreset"
    static let indicatorStylePreset = "general.indicatorStylePreset"
    static let selectedInputUID = "audio.selectedInputDeviceUID"
    static let muteWhileRecording = "general.muteWhileRecording"
}

struct GeneralSettingsConfiguration: Equatable {
    static let defaults = GeneralSettingsConfiguration(
        launchAtLogin: false,
        showInDock: true,
        escapeCancelsRecording: false,
        indicatorPlacement: .topCenter,
        indicatorStyle: .machined,
        muteWhileRecording: true
    )

    var launchAtLogin: Bool
    var showInDock: Bool
    var escapeCancelsRecording: Bool
    var indicatorPlacement: IndicatorPlacement
    var indicatorStyle: IndicatorStyle
    var muteWhileRecording: Bool

    static func load(from defaults: UserDefaults = .standard) -> GeneralSettingsConfiguration {
        let presetRaw = defaults.string(forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        let preset = IndicatorPlacement.migrating(fromStored: presetRaw)

        let styleRaw = defaults.string(forKey: GeneralSettingsKeys.indicatorStylePreset)
        let style = IndicatorStyle.migrating(fromStored: styleRaw)

        return GeneralSettingsConfiguration(
            launchAtLogin: bool(forKey: GeneralSettingsKeys.launchAtLogin, defaults: defaults, fallback: Self.defaults.launchAtLogin),
            showInDock: bool(forKey: GeneralSettingsKeys.showInDock, defaults: defaults, fallback: Self.defaults.showInDock),
            escapeCancelsRecording: bool(forKey: GeneralSettingsKeys.escapeCancelsRecording, defaults: defaults, fallback: Self.defaults.escapeCancelsRecording),
            indicatorPlacement: preset,
            indicatorStyle: style,
            muteWhileRecording: bool(forKey: GeneralSettingsKeys.muteWhileRecording, defaults: defaults, fallback: Self.defaults.muteWhileRecording)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchAtLogin, forKey: GeneralSettingsKeys.launchAtLogin)
        defaults.set(showInDock, forKey: GeneralSettingsKeys.showInDock)
        defaults.set(escapeCancelsRecording, forKey: GeneralSettingsKeys.escapeCancelsRecording)
        defaults.set(indicatorPlacement.rawValue, forKey: GeneralSettingsKeys.indicatorPlacementPreset)
        defaults.set(indicatorStyle.rawValue, forKey: GeneralSettingsKeys.indicatorStylePreset)
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
    /// AudioTransportTag bucket ("builtin"/"usb"/"bluetooth"/…); "unknown" when
    /// only a remembered-but-absent fallback is constructible.
    var transportTag: String = "unknown"
    /// True when the hardware object IS present yet exposes no input stream —
    /// Bluetooth parked in A2DP. Renders TAP TO WAKE instead of dead OFFLINE.
    var isWakeable: Bool = false
}

enum MicrophoneDeviceService {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "MicPriority")

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
                channelCount: $0.inputChannels,
                transportTag: AudioTransportTag.label(forTransportType: $0.transportType)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    ///
    /// - Parameter liveTransportTagsByUID: Test seam — UID→AudioTransportTag for
    ///   devices physically present NOW, including zero-input-channel objects.
    ///   Nil = query CoreAudio (only done when a fallback actually needs classifying).
    static func mergedPriorityList(
        config: MicrophonePriorityConfiguration,
        liveTransportTagsByUID: [String: String]? = nil
    ) -> [MicrophoneDeviceDescriptor] {
        let available = availableInputDevices()
        let availableByUID = Dictionary(uniqueKeysWithValues: available.map { ($0.uid, $0) })

        // Presence sweep runs ONLY when some priority UID fell out of the live
        // usable list: it separates truly-gone devices (no hardware object at
        // all) from A2DP-idle Bluetooth headsets (object present, zero input
        // channels) which become wakeable rather than OFFLINE.
        let pendingFallbackUIDs = config.priorityUIDs.filter { !availableByUID.keys.contains($0) }
        let presentTransportTags = liveTransportTagsByUID
            ?? (pendingFallbackUIDs.isEmpty ? [:] : AudioDeviceDebug.presentDeviceTransportTags())

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
                logger.info("Mic priority: uid=\(uid, privacy: .public) ('\("\(fallbackName)", privacy: .public)') not in live enumeration — showing OFFLINE fallback")
                // Idle-BT presence can hide under a sibling UID: the stored
                // priority UID is the HFP-live "<base>:input" form, while the
                // parked A2DP object enumerates as "<base>"/"<base>:output".
                // Exact-miss must not kill wakeability (2026-08-27 live log:
                // the probe never showed for the AirPods row).
                let uidCandidates = AudioDeviceDebug.candidateUIDs(forStoredUID: uid)
                let presentTag = presentTransportTags[uid]
                    ?? uidCandidates.dropFirst().compactMap { presentTransportTags[$0] }.first
                let isWakeable = uidCandidates.contains { presentTransportTags[$0] == "bluetooth" }
                if isWakeable, presentTransportTags[uid] == nil {
                    logger.info("Mic priority: uid=\(uid, privacy: .public) idle Bluetooth present under a sibling UID — offering wake")
                }
                result.append(
                    MicrophoneDeviceDescriptor(
                        id: uid,
                        uid: uid,
                        name: fallbackName,
                        deviceID: 0,
                        isAvailable: false,
                        channelCount: 0,
                        transportTag: presentTag ?? "unknown",
                        isWakeable: isWakeable
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
    /// CoreAudio topology changed (device plug/unplug, default-input switch, wake).
    /// Posted by KalamApp's AudioDeviceMonitor path so open settings UI re-enumerates
    /// the mic list instead of rendering a stale one-shot snapshot.
    static let audioDevicesDidChange = Notification.Name("audioDevicesDidChange")
    static let openSetupFlow = Notification.Name("openSetupFlow")
    /// settings deep link: open settings at the Engine dive (settings redesign; formerly the Models tab).
    static let selectModelsSettingsTab = Notification.Name("selectModelsSettingsTab")
}

// MARK: - Audio Device Utilities

enum AudioDeviceDebug {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioDevice")

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
            logger.error("Failed to query default input device domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            info = nil
        }
        if let info = info {
            let isLogitech = info.name.localizedCaseInsensitiveContains("logitech") ||
            info.name.localizedCaseInsensitiveContains("c920")
            logger.info("Input device name=\(info.name, privacy: .public) channels=\(info.inputChannels) sampleRate=\(info.nominalSampleRate) logitech=\(isLogitech)")
        } else {
            logger.info("Could not query input device details (non-fatal, proceeding with defaults)")
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

    /// UID→AudioTransportTag for EVERY audio object currently attached,
    /// regardless of channel layout. Used by settings-time fallback
    /// classification; deliberately bypasses the zero-input-channel drop so
    /// A2DP-idle Bluetooth headsets are visible here while staying out of the
    /// recording path.
    static func presentDeviceTransportTags() -> [String: String] {
        let ids = (try? allDeviceIDs()) ?? []
        var tags: [String: String] = [:]
        for id in ids {
            guard let uid = try? getCFString(id, selector: kAudioDevicePropertyDeviceUID),
                  tags[uid] == nil else { continue }
            let transportType = try? getUInt32(id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
            tags[uid] = AudioTransportTag.label(forTransportType: transportType)
        }
        return tags
    }

    /// Sibling UIDs that may denote the same physical headset. The stored
    /// priority UID is captured from the HFP-live input object ("<base>:input");
    /// while parked in A2DP the surviving object can carry "<base>" or
    /// "<base>:output", so exact-key presence lookups miss and an idle headset
    /// renders dead OFFLINE instead of TAP TO WAKE. Ordered exact-first so the
    /// known-good path is never perturbed. UIDs whose final colon segment is
    /// not an input/output side (USB webcam-style) are their own single
    /// candidate.
    static func candidateUIDs(forStoredUID uid: String) -> [String] {
        guard let sideColon = uid.range(of: ":", options: .backwards)?.lowerBound,
              uid[sideColon...].hasSuffix(":input") || uid[sideColon...].hasSuffix(":output")
        else { return [uid] }
        let base = String(uid[..<sideColon])
        var candidates = [uid, base, base + ":output", base + ":input"]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Resolves a device UID to its current `AudioDeviceID`; nil when macOS no
    /// longer knows such a device (translate fails or yields the null object).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        // Translate-UID convention: the CFString rides as QUALIFIER data
        // (qualifier size = sizeof a reference), the AudioDeviceID comes back
        // through the out-buffer.
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<UnsafeRawPointer>.size),
            &cfUID,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func allInputDeviceInfos() throws -> [DeviceInfo] {
        let ids = try allDeviceIDs()
        let infos = ids.compactMap { id -> DeviceInfo? in
            do {
                let channels = try getInputChannelCount(id)
                guard channels > 0 else {
                    // Drop-reason diagnostics: Bluetooth headsets idle in A2DP expose
                    // NO input stream (mic not live) even though System Settings
                    // lists them as a selectable input. This is the branch that
                    // fires for them — confirmable via Console.app filter.
                    let transport = try? getUInt32(id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
                    logger.info("Input enumeration: dropped id=\(id, privacy: .public) — 0 input channels (output-only or Bluetooth A2DP-idle) transport=\(transport ?? 0, privacy: .public)")
                    return nil
                }
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
                logger.warning("Input enumeration: dropped id=\(id, privacy: .public) status=\((error as NSError).code, privacy: .public)")
                return nil
            }
        }
        logger.info("Input enumeration: \(ids.count) CoreAudio devices → \(infos.count) usable inputs [\(infos.map { "\($0.name)/\($0.inputChannels)ch" }.joined(separator: ", "), privacy: .public)]")
        return infos
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
                logger.info("Non-fatal invalid property (-10877) for input channels; assuming default (2)")
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

// MARK: - Bluetooth mic wake

/// Engages the HFP/mic side of an idle Bluetooth headset by opening a short
/// capture stream bound to it — precisely what the user's first PTT would
/// force implicitly, but explicit (settings TAP TO WAKE) and off the recording
/// latency path. Best-effort: any failure simply leaves the row offline.
enum BluetoothMicWaker {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "BTMicWake")

    /// Opens the input stream for `holdSeconds` (~0.8 s is enough for macOS to
    /// switch profiles and post device-change notifications).
    @discardableResult
    static func openMicStream(forUID uid: String, holdSeconds: Double = 0.8) async -> Bool {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(returning: openStreamSync(uid: uid, holdSeconds: holdSeconds))
            }
        }
    }

    private static func openStreamSync(uid: String, holdSeconds: Double) -> Bool {
        // Exact-or-sibling resolution (candidateUIDs): the parked A2DP object
        // can enumerate as "<base>"/"<base>:output" while the stored priority
        // UID is the HFP-live "<base>:input" form.
        var resolvedDeviceID = AudioDeviceID(0)
        for candidate in AudioDeviceDebug.candidateUIDs(forStoredUID: uid) {
            if let id = AudioDeviceDebug.deviceID(forUID: candidate) {
                resolvedDeviceID = id
                if candidate != uid {
                    logger.info("BT wake uid=\(uid, privacy: .public) resolved via sibling UID=\(candidate, privacy: .public)")
                }
                break
            }
        }
        guard resolvedDeviceID != 0 else {
            logger.info("BT wake skipped: uid=\(uid, privacy: .public) no longer present")
            return false
        }
        let deviceID = resolvedDeviceID
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            // Bind the I/O unit to the headset's input side; mirrors the
            // technique AudioRecorder.prepare uses when a preferred device is set.
            guard let audioUnit = input.audioUnit else {
                logger.error("BT wake skipped: no audio unit uidPrefix=\(String(uid.prefix(24)), privacy: .public)")
                return false
            }
            var boundDeviceID = deviceID
            let bindStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &boundDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard bindStatus == noErr else {
                logger.error("BT wake bind failed osStatus=\(Int(bindStatus)) uidPrefix=\(String(uid.prefix(24)), privacy: .public)")
                return false
            }

            input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { _, _ in }
            try engine.start()
            Thread.sleep(forTimeInterval: holdSeconds)
            engine.stop()
            input.removeTap(onBus: 0)
            logger.info("BT wake opened mic stream uidPrefix=\(String(uid.prefix(24)), privacy: .public) heldMs=\(Int(holdSeconds * 1000))")
            return true
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            let nsError = error as NSError
            logger.error("BT wake failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) uidPrefix=\(String(uid.prefix(24)), privacy: .public)")
            return false
        }
    }
}
