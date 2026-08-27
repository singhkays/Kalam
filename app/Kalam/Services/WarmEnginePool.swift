import Foundation
import AVFoundation
import CoreAudio
import OSLog

// MARK: - WarmEnginePool (Task 1: device-warm prepared graph)

/// Holds ONE spare `AVAudioEngine` graph keyed by the current input-device UID.
/// The spare is `construct + prepare()` ONLY — never `start()` / tap-install while
/// idle (mic-indicator invariant). Permission-gated, coalesced 250 ms trailing
/// debounce on invalidate/rebuild, and `take` hands ownership to the recording
/// session then schedules a refill.
protocol WarmEnginePoolCancellable {
    func cancel()
}
extension DispatchWorkItem: WarmEnginePoolCancellable {}

typealias WarmEnginePoolScheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> WarmEnginePoolCancellable

final class WarmEnginePool: @unchecked Sendable {
    struct PreparedGraph {
        let deviceUID: String?
        let engine: AVAudioEngine
    }

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "WarmEnginePool")
    private let debounceInterval: TimeInterval
    private let permissionCheck: () -> Bool
    private let currentDeviceProvider: () -> String?
    private let engineFactory: (String?) throws -> AVAudioEngine
    private let scheduler: WarmEnginePoolScheduler

    private let lock = NSLock()
    private var _spare: PreparedGraph?
    private var pendingRebuild: WarmEnginePoolCancellable?

    private var spare: PreparedGraph? {
        get { lock.lock(); defer { lock.unlock() }; return _spare }
        set { lock.lock(); _spare = newValue; lock.unlock() }
    }

    // MARK: - Init

    convenience init() {
        self.init(
            debounceInterval: 0.25,
            permissionCheck: {
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            },
            currentDeviceProvider: {
                let config = MicrophonePriorityConfiguration.load()
                let normalized = MicrophoneDeviceService.normalize(config: config)
                let candidates = MicrophoneDeviceService.mergedPriorityList(config: normalized)
                    .filter(\.isAvailable)
                return candidates.first?.uid
            },
            engineFactory: { uid in
                try WarmEnginePool.defaultEngineFactory(for: uid)
            },
            scheduler: { delay, work in
                let item = DispatchWorkItem(block: work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return item
            }
        )
    }

    init(
        debounceInterval: TimeInterval = 0.25,
        permissionCheck: @escaping () -> Bool,
        currentDeviceProvider: @escaping () -> String?,
        engineFactory: @escaping (String?) throws -> AVAudioEngine,
        scheduler: @escaping WarmEnginePoolScheduler
    ) {
        self.debounceInterval = debounceInterval
        self.permissionCheck = permissionCheck
        self.currentDeviceProvider = currentDeviceProvider
        self.engineFactory = engineFactory
        self.scheduler = scheduler
    }

    // MARK: - Public API

    /// Permission-gated prewarm for a specific UID. Synchronous on the caller
    /// (MainActor) for test determinism; production factory does `prepare()` only.
    func prewarm(for deviceUID: String?) {
        guard permissionCheck() else {
            logger.debug("WarmEnginePool prewarm skipped: mic permission not authorized")
            return
        }
        let target = deviceUID ?? currentDeviceProvider()
        if let s = spare, s.deviceUID == target {
            logger.debug("WarmEnginePool prewarm skipped: already fresh for uid=\(target ?? "nil", privacy: .public)")
            return
        }
        do {
            let engine = try engineFactory(target)
            if engine.isRunning {
                logger.warning("WarmEnginePool factory returned RUNNING engine — stopping (invariant violation)")
                engine.stop()
            }
            spare = PreparedGraph(deviceUID: target, engine: engine)
            logger.info("WarmEnginePool spare READY uid=\(target ?? "nil", privacy: .public)")
        } catch {
            logger.warning("WarmEnginePool prewarm failed errorSummary=\((error as NSError).domain)#\((error as NSError).code, privacy: .public)")
        }
    }

    func prewarmNext() {
        prewarm(for: currentDeviceProvider())
    }

    func isFresh(for deviceUID: String?) -> Bool {
        spare?.deviceUID == deviceUID
    }

    @discardableResult
    func take(for deviceUID: String?) -> PreparedGraph? {
        guard let s = spare else { return nil }
        guard s.deviceUID == deviceUID else {
            logger.debug("WarmEnginePool take stale: spare uid=\(s.deviceUID ?? "nil", privacy: .public) requested=\(deviceUID ?? "nil", privacy: .public) — nil")
            return nil
        }
        spare = nil
        logger.info("WarmEnginePool take consumed uid=\(deviceUID ?? "nil", privacy: .public) — scheduling refill")
        scheduleRebuild()
        return s
    }

    // AudioDeviceID overloads — resolve UID via candidate list
    func take(for deviceID: AudioDeviceID?) -> PreparedGraph? {
        let uid: String? = WarmEnginePool.uid(for: deviceID, provider: currentDeviceProvider)
        return take(for: uid)
    }

    func isFresh(for deviceID: AudioDeviceID?) -> Bool {
        let uid: String? = WarmEnginePool.uid(for: deviceID, provider: currentDeviceProvider)
        return isFresh(for: uid)
    }

    func invalidate(reason: String) {
        let hadSpare = spare != nil
        spare = nil
        lock.lock()
        pendingRebuild?.cancel()
        pendingRebuild = nil
        lock.unlock()
        logger.info("WarmEnginePool invalidated reason=\(reason, privacy: .public) hadSpare=\(hadSpare, privacy: .public)")
        scheduleRebuild()
    }

    // MARK: - Internals

    private func scheduleRebuild() {
        lock.lock()
        pendingRebuild?.cancel()
        lock.unlock()
        let c = scheduler(debounceInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingRebuild = nil
            self.lock.unlock()
            guard self.permissionCheck() else {
                self.logger.debug("WarmEnginePool rebuild skipped: not authorized")
                return
            }
            let target = self.currentDeviceProvider()
            if self.spare?.deviceUID == target { return }
            do {
                let engine = try self.engineFactory(target)
                if engine.isRunning { engine.stop() }
                self.spare = PreparedGraph(deviceUID: target, engine: engine)
                self.logger.info("WarmEnginePool rebuilt spare uid=\(target ?? "nil", privacy: .public)")
            } catch {
                self.logger.warning("WarmEnginePool rebuild failed errorSummary=\((error as NSError).domain)#\((error as NSError).code, privacy: .public)")
            }
        }
        lock.lock()
        pendingRebuild = c
        lock.unlock()
    }

    // MARK: - UID mapping helper

    private static func uid(for deviceID: AudioDeviceID?, provider: () -> String?) -> String? {
        guard let deviceID else { return nil }
        let config = MicrophonePriorityConfiguration.load()
        let normalized = MicrophoneDeviceService.normalize(config: config)
        let candidates = MicrophoneDeviceService.mergedPriorityList(config: normalized)
        if let match = candidates.first(where: { $0.deviceID == deviceID }) {
            return match.uid
        }
        return provider()
    }

    // MARK: - Default engine factory (construct + prepare ONLY)

    static func defaultEngineFactory(for deviceUID: String?) throws -> AVAudioEngine {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.micPermissionDenied
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let deviceID = AudioDeviceDebug.deviceID(forUID: uid), let audioUnit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw AudioRecorderError.engineStartFailed(NSError(domain: "Kalam.AudioRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Warm pool: bind failed OSStatus \(status)"]))
            }
        }
        let bound: AudioDeviceID? = {
            if let uid = deviceUID, let did = AudioDeviceDebug.deviceID(forUID: uid) { return did }
            var def = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &def)
            return st == noErr ? def : nil
        }()
        if let bound, let applied = AudioRecorder.shrinkDeviceRingBuffer(deviceID: bound) {
            Logger(subsystem: "singhkays.Kalam", category: "WarmEnginePool").info("Warm pool ring applied frames=\(applied, privacy: .public)")
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }
        engine.prepare()
        assert(!engine.isRunning, "engine must not be running after prepare")
        return engine
    }

    // MARK: - Test hooks

    var spareForTesting: PreparedGraph? { spare }
    var hasPendingRebuildForTesting: Bool { lock.lock(); defer { lock.unlock() }; return pendingRebuild != nil }
    func setSpareForTesting(_ graph: PreparedGraph?) { spare = graph }
    func cancelPendingForTesting() { lock.lock(); pendingRebuild?.cancel(); pendingRebuild = nil; lock.unlock() }
}
