import Foundation
import AVFoundation
import CoreAudio
import OSLog

// MARK: - WarmEnginePool (Task 1: device-warm prepared graph)

/// Holds ONE spare `AVAudioEngine` graph keyed by input-device UID.
/// The spare follows LAST-USED (owner decision 2026-10-02): the persisted pick
/// from the last successful prepare wins when still available, else top
/// priority. The spare is `construct + prepare()` ONLY — never `start()` /
/// tap-install while idle (mic-indicator invariant). Permission-gated,
/// coalesced 250 ms trailing debounce on invalidate/rebuild, and `take` hands
/// ownership to the recording session then schedules a refill.
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
                // Hot path (prewarm/refill/take): single enumeration, no
                // normalize — normalize enumerates again and spams logs.
                // Last-used first (owner decision 2026-10-02): the persisted
                // pick from the last successful prepare wins when still
                // available, else top priority. First launch (no pick stored
                // yet) behaves exactly as before.
                let config = MicrophonePriorityConfiguration.load()
                let availableUIDs = MicrophoneDeviceService.mergedPriorityList(config: config)
                    .filter(\.isAvailable)
                    .map(\.uid)
                let lastUsed = UserDefaults.standard.string(forKey: GeneralSettingsKeys.selectedInputUID)
                return WarmEnginePool.preferredSpareUID(lastUsedUID: lastUsed, availableUIDs: availableUIDs)
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
            if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool prewarm skipped: mic permission not authorized") }
            return
        }
        let target = deviceUID ?? currentDeviceProvider()
        if let s = spare, s.deviceUID == target {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool prewarm skipped: already fresh for uid=\(target ?? "nil", privacy: .public)") }
            return
        }
        do {
            let engine = try engineFactory(target)
            if engine.isRunning {
                logger.warning("WarmEnginePool factory returned RUNNING engine — stopping (invariant violation)")
                engine.stop()
            }
            spare = PreparedGraph(deviceUID: target, engine: engine)
            if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool spare READY uid=\(target ?? "nil", privacy: .public)") }
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
            if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool take stale: spare uid=\(s.deviceUID ?? "nil", privacy: .public) requested=\(deviceUID ?? "nil", privacy: .public) — nil") }
            return nil
        }
        spare = nil
        if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool take consumed uid=\(deviceUID ?? "nil", privacy: .public) — scheduling refill") }
        scheduleRebuild()
        return s
    }

    /// Single-resolution take for callers that already know the UID (K-61):
    /// one atomic check-and-take with NO device enumeration (the caller
    /// resolved once upstream). A miss — stale spare or empty pool — logs one
    /// verbose line naming both sides (K-60: `isFresh == false` misses were
    /// previously silent) and the caller builds inline.
    @discardableResult
    func takeIfFresh(for uid: String?) -> PreparedGraph? {
        let current = spare
        guard let graph = current, graph.deviceUID == uid else {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool miss: requested uid=\(uid ?? "nil", privacy: .public) spare uid=\(current?.deviceUID ?? "nil", privacy: .public) — inline build") }
            return nil
        }
        spare = nil
        if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool take consumed uid=\(uid ?? "nil", privacy: .public) — scheduling refill") }
        scheduleRebuild()
        return graph
    }

    /// UID resolution for callers without a pre-resolved UID (K-61 fallback
    /// path only — prefer passing the UID down so the hot path enumerates once).
    func resolveUID(for deviceID: AudioDeviceID?) -> String? {
        Self.uid(for: deviceID, provider: currentDeviceProvider)
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
        if KalamDiagnosticFlags.verboseAudio { logger.debug("WarmEnginePool invalidated reason=\(reason, privacy: .public) hadSpare=\(hadSpare, privacy: .public)") }
        scheduleRebuild()
    }

    /// Convergence hook for the last-used policy (owner decision 2026-10-02):
    /// call after a prepare that did NOT adopt the spare. If the spare already
    /// names `uid`, or a refill is already in flight with no spare, this is a
    /// no-op; otherwise it schedules the debounced rebuild, which re-reads the
    /// provider at fire time (by then persisting the just-used pick) and
    /// converges the spare to the just-used device after one miss. Without
    /// this, a miss schedules nothing and the spare never follows a newly
    /// used device (proven live 2026-10-01: second consecutive BT press still
    /// missed, spare still USB).
    func ensureSpare(for uid: String?) {
        if spare?.deviceUID == uid { return }
        lock.lock()
        let pending = pendingRebuild != nil
        lock.unlock()
        if spare == nil && pending { return } // refill in flight — trust it
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
                if KalamDiagnosticFlags.verboseAudio { self.logger.debug("WarmEnginePool rebuild skipped: not authorized") }
                return
            }
            let target = self.currentDeviceProvider()
            if self.spare?.deviceUID == target { return }
            do {
                let engine = try self.engineFactory(target)
                if engine.isRunning { engine.stop() }
                self.spare = PreparedGraph(deviceUID: target, engine: engine)
                if KalamDiagnosticFlags.verboseAudio { self.logger.debug("WarmEnginePool rebuilt spare uid=\(target ?? "nil", privacy: .public)") }
            } catch {
                self.logger.warning("WarmEnginePool rebuild failed errorSummary=\((error as NSError).domain)#\((error as NSError).code, privacy: .public)")
            }
        }
        lock.lock()
        pendingRebuild = c
        lock.unlock()
    }

    // MARK: - UID mapping helper

    /// Spare-keying policy (pure/headless): last-used wins when still
    /// available, else top priority, else nil. Owner decision 2026-10-02 —
    /// switch rarely, stay long: sustained use of a non-top mic converges to
    /// hits after the first dictation persists the pick.
    static func preferredSpareUID(lastUsedUID: String?, availableUIDs: [String]) -> String? {
        if let lastUsedUID, availableUIDs.contains(lastUsedUID) {
            return lastUsedUID
        }
        return availableUIDs.first
    }

    private static func uid(for deviceID: AudioDeviceID?, provider: () -> String?) -> String? {
        guard let deviceID else { return nil }
        let config = MicrophonePriorityConfiguration.load()
        let candidates = MicrophoneDeviceService.mergedPriorityList(config: config)
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
            if KalamDiagnosticFlags.verboseAudio {
                Logger(subsystem: "singhkays.Kalam", category: "WarmEnginePool").debug("Warm pool ring applied frames=\(applied, privacy: .public)")
            }
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
