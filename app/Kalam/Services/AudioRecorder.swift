import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import OSLog

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

// MARK: - Secure Memory Zeroing
extension Array where Element == Float {
    mutating func secureZero() {
        self.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                memset(baseAddress, 0, buffer.count * MemoryLayout<Float>.size)
            }
        }
    }
}

// MARK: - Audio Recorder (AVAudioEngine + resample to 16kHz mono Float32)

enum AudioRecorderError: LocalizedError {
    case micPermissionDenied
    case invalidInputFormat
    case converterCreationFailed
    case engineStartFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone permission denied."
        case .invalidInputFormat:
            return "Invalid input format."
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter."
        case .engineStartFailed(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        }
    }
}

/// Decides whether `prepare()` must rebuild the audio graph. Extracted from
/// `AudioRecorder.prepare` so the early-return logic is headless-testable
/// (microphone recovery after sleep or device change; the test host cannot touch `engine.inputNode`).
enum AudioPrepareDecision {
    static func shouldReconfigure(
        isPrepared: Bool,
        lastDeviceID: AudioDeviceID?,
        preferredDeviceID: AudioDeviceID?,
        invalidated: Bool
    ) -> Bool {
        !(isPrepared && lastDeviceID == preferredDeviceID && !invalidated)
    }

    /// Task-1: pool-aware variant — when the pool already holds a fresh graph
    /// for `preferredDeviceID`, `prepare()` can adopt it instead of rebuilding.
    static func shouldReconfigure(
        isPrepared: Bool,
        lastDeviceID: AudioDeviceID?,
        preferredDeviceID: AudioDeviceID?,
        invalidated: Bool,
        poolIsFreshForPreferred: Bool
    ) -> Bool {
        if poolIsFreshForPreferred { return false }
        return shouldReconfigure(isPrepared: isPrepared, lastDeviceID: lastDeviceID, preferredDeviceID: preferredDeviceID, invalidated: invalidated)
    }
}

/// Snapshot of a finished capture session. Counts and peak level only —
/// never audio content. Consumed by `CaptureHealthGuard` (see
/// SpeechQualityGuard.swift) to refuse pasting unusable bytes.
struct CaptureStats: Sendable, Equatable {
    var sampleCount: Int
    var durationMs: Int
    var callbacks: Int
    var dropped: Int
    var nonZeroCount: Int
    var maxAmplitude: Float

    static let empty = CaptureStats(
        sampleCount: 0, durationMs: 0, callbacks: 0,
        dropped: 0, nonZeroCount: 0, maxAmplitude: 0)
}

/// Mid-hold stall watchdog state (Bluetooth-dropout hardening). Polls the
/// published tap-callback count; reports `.warn` once when no new audio
/// arrives for `stallThresholdMs`, and `.recovered` when the stream resumes
/// after a warning (so the caller can heal the indicator). Pure; the
/// polling loop lives in AppDelegate.
enum MicStallEvent: Sendable, Equatable {
    case ok
    case warn
    case recovered
}

struct MicStallMonitor: Sendable {
    /// Covers the worst observed Bluetooth engine start (~450 ms) plus
    /// converter priming with wide margin; the first poll only baselines.
    static let graceMs = 2500
    static let pollIntervalMs = 1000
    /// Two consecutive stalled polls (matches the ~2.4 s systematic AirPods
    /// stall: warns ~4.5 s into a dead hold instead of wasting all of it).
    static let stallThresholdMs = 2000

    private(set) var lastCount: Int?
    private(set) var stalledMs = 0
    private(set) var warned = false

    /// Returns the single action for this poll. Warns at most once per
    /// stall episode; a resume re-arms the next episode.
    mutating func observe(count: Int) -> MicStallEvent {
        defer { lastCount = count }
        guard let last = lastCount else { return .ok }
        if count != last {
            stalledMs = 0
            if warned {
                warned = false
                return .recovered
            }
            return .ok
        }
        stalledMs += Self.pollIntervalMs
        if !warned, stalledMs >= Self.stallThresholdMs {
            warned = true
            return .warn
        }
        return .ok
    }
}

// MARK: - Bounded engine start (main-thread freeze hardening)

/// Resume-at-most-once guard shared by the two racing branches of a bounded
/// start (engine attempt vs deadline timer). `@unchecked Sendable` because the
/// lock provides the synchronization.
final class BoundedStartResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once per instance; losers of the race must not
    /// touch the continuation.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Pure policy behind the bounded engine start (2026-09-09 audio-start
/// hardening design plan). Framework-free so the deadline and outcome
/// classification are headless-testable.
///
/// Background: `AVAudioEngine.start()` used to run synchronously on the main
/// thread. When the HAL wedges mid-start (USB device churn: `error 35` /
/// `no such object` cascade, `AVAudioIONodeImpl err = 1852797029`), the call
/// parks indefinitely instead of throwing — freezing the entire app, overlay
/// timer included, and making quit impossible. The start now runs off-main
/// under a hard deadline owned here.
enum AudioStartPolicy {
    /// Hard deadline for the entire bounded start, including the one recovery
    /// re-prepare + retry that lives inside `startCollecting`. 2000 ms covers
    /// the worst observed Bluetooth start (~450 ms — see
    /// `MicStallMonitor.graceMs`) with wide margin while keeping the perceived
    /// hang under ~2 s. A wedged HAL never returns, so this is the only bound.
    /// Revisit only with a measured `toEngineMs` distribution that approaches
    /// the margin.
    static let timeoutMs: Int = 2000

    /// Poll cadence while waiting for a still-in-flight previous attempt to
    /// clear the engine (supersede path). Short enough that a superseding
    /// press feels immediate; cheap by construction.
    static let inFlightWaitPollMs: Int = 25

    /// Outcomes of a bounded start attempt.
    /// - `started`: engine live, tap installed, session may commit.
    /// - `failed`: the attempt threw (device gone, permission, bind error…).
    /// - `timedOut`: the deadline elapsed first — the attempt may still be
    ///   parked inside CoreAudio and will self-clean when/if it returns.
    /// - `superseded`: the press was abandoned while in flight (key-up, Esc,
    ///   second press, device change, wake, quit). Never surfaces a toast.
    enum Outcome: Equatable, Sendable {
        case started
        case timedOut
        case failed
        case superseded
    }

    /// Single classification point for a completed or abandoned attempt.
    /// Precedence: abandonment wins (the session is no longer wanted — even a
    /// technically-successful start must self-clean, never commit), then a
    /// thrown error, then the deadline as fallback.
    static func classify(elapsedMs: Int, didThrow: Bool, wasAbandoned: Bool) -> Outcome {
        if wasAbandoned { return .superseded }
        if didThrow { return .failed }
        if elapsedMs >= timeoutMs { return .timedOut }
        return .started
    }

    /// An abandoned attempt must ALWAYS self-clean (engine stop + graph
    /// invalidation): an engine that started late must never be left running
    /// with no committed session behind it.
    static func shouldSelfClean(wasAbandoned: Bool) -> Bool { wasAbandoned }
}

final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioRecorder")
    private var engine = AVAudioEngine()
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?
    private var preparedStateInvalidated = false

    // Bounded-start flight state (main-thread freeze hardening). Lock-guarded.
    // Invariant: while `_isStartInFlight` is true, the engineOpQueue block owns
    // ALL engine access; main-thread callers (prepare, finishStop, refresh)
    // must check `isStartInFlight` and defer instead of touching the engine.
    private let startFlightLock = NSLock()
    private var _isStartInFlight = false
    private var _abandonCurrentStart = false

    /// Serial home for the off-main engine start. One block at a time; the
    /// in-flight guard keeps main from entering concurrently, so engine state
    /// is never touched from two contexts at once.
    private let engineOpQueue = DispatchQueue(label: "singhkays.Kalam.audio.engineops", qos: .userInitiated)

    // render-thread audio lock fix: all capture state (buffers, converter, counters) lives behind
    // AudioCaptureExchange; the render thread publishes non-blockingly
    // (try-lock), consumers use exclusive access.
    private let exchange = AudioCaptureExchange()
    /// Generation of the capture session this recorder most recently started.
    private var currentCaptureGeneration = 0

    /// Task 0 latency instrumentation: per-session engine-start / first-buffer
    /// stamps + mic-transport tag (see `SessionTimingMarks`). Timings only,
    /// never content. Read by KalamApp's gated latency log lines.
    private let timingMarks = SessionTimingMarks()
    
    // Tap buffer size reduced to lower tail latency at key-up
    private let tapBufferSizeFrames: AVAudioFrameCount = 1024

    /// Last SNR-aware post-roll SNR (dB) read back from the waveform ring at
    /// key-up. Written only in the SNR-aware stop path; read by KalamApp's
    /// latency summary to tag `roomSNR=` without re-estimating.
    private var _lastPostRollSNR: Float = 0
    private let lastSNRlock = NSLock()
    var lastPostRollSNR: Float {
        lastSNRlock.lock(); defer { lastSNRlock.unlock() }; return _lastPostRollSNR
    }
    private func setLastPostRollSNR(_ v: Float) {
        lastSNRlock.lock(); _lastPostRollSNR = v; lastSNRlock.unlock()
    }

    /// Snapshot of the most recently finished capture session. Counts and
    /// levels only — never content. Read by KalamApp's capture-pathology
    /// gate (Bluetooth-dropout hardening) to refuse pasting garbage.
    private var _lastCaptureStats = CaptureStats.empty
    private let lastCaptureStatsLock = NSLock()
    var lastCaptureStats: CaptureStats {
        lastCaptureStatsLock.lock(); defer { lastCaptureStatsLock.unlock() }; return _lastCaptureStats
    }
    private func setLastCaptureStats(_ v: CaptureStats) {
        lastCaptureStatsLock.lock(); _lastCaptureStats = v; lastCaptureStatsLock.unlock()
    }

    // MARK: Task 6 (K-57) — opt-in retention, default OFF, byte-identical when OFF
    private var retentionWriter: CAFStreamWriter?
    private var retentionFolder: URL?
    private var retentionSessionID: UUID?
    private let retentionLock = NSLock()

    /// Starts per-session retention if the toggle is ON. Creates
    /// `<timestamp>-<uuid>/audio.caf` (streaming CAF, -1 header) + `meta.json`
    /// (isComplete=false). When OFF, no-ops and returns nil (zero disk writes).
    /// Must be called on MainActor before `startCollecting` for the same session.
    @discardableResult
    func beginRetentionIfEnabled(sessionID: UUID, timestamp: Date = Date(), deviceUID: String? = nil) -> URL? {
        guard UserDefaults.standard.bool(forKey: "retention.enabled") else { return nil }
        retentionLock.lock()
        // If a previous session's writer is still open (rapid re-record), close it as incomplete
        // (it was superseded, not crash, but marking incomplete is safe — it will be swept as interrupted).
        if let prevWriter = retentionWriter, let prevFolder = retentionFolder {
            // Close outside the lock to avoid deadlock with sink, but we already hold lock.
            // Capture and clear first, then close after unlock.
            retentionWriter = nil
            retentionFolder = nil
            retentionSessionID = nil
            retentionLock.unlock()
            exchange.setRetentionSink(nil)
            try? prevWriter.close()
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Retention superseded close prev folder=\(prevFolder.lastPathComponent, privacy: .public)") }
            retentionLock.lock()
        }
        defer { retentionLock.unlock() }
        let folder = FileLayout.sessionFolder(sessionID: sessionID, timestamp: timestamp)
        do {
            try FileLayout.ensureSessionFolder(folder)
            let audioURL = FileLayout.audioURL(for: folder)
            let writer = try CAFStreamWriter(url: audioURL, sampleRate: 16_000, channels: 1)
            retentionWriter = writer
            retentionFolder = folder
            retentionSessionID = sessionID
            // Stream converted chunks via exchange sink (utility queue, never blocks render thread)
            // Capture writer directly to avoid Sendable capture of self.
            let capturedWriter = writer
            exchange.setRetentionSink { @Sendable chunk in
                try? capturedWriter.append(chunk)
            }
            let meta = SessionMeta(sessionID: sessionID, deviceUID: deviceUID, deviceName: nil, sampleRate: 16_000, timestamp: timestamp, segmentEstimateMs: nil, isComplete: false)
            let data = try JSONEncoder().encode(meta)
            try data.write(to: FileLayout.metaURL(for: folder), options: .atomic)
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Retention begin folder=\(folder.lastPathComponent, privacy: .public) session=\(sessionID.uuidString.prefix(8), privacy: .public)") }
            return folder
        } catch {
            logger.warning("Retention begin failed error=\(error.localizedDescription, privacy: .public)")
            retentionWriter = nil
            retentionFolder = nil
            retentionSessionID = nil
            exchange.setRetentionSink(nil)
            return nil
        }
    }

    /// Ends retention for the current session, optionally marking complete.
    /// Closes the CAF writer (no header rewrite needed for streaming CAF).
    func endRetention(markComplete: Bool) {
        retentionLock.lock()
        let folder = retentionFolder
        let writer = retentionWriter
        retentionWriter = nil
        retentionFolder = nil
        retentionSessionID = nil
        retentionLock.unlock()
        exchange.setRetentionSink(nil)
        if let folder, markComplete {
            let metaURL = FileLayout.metaURL(for: folder)
            if let data = try? Data(contentsOf: metaURL),
               var meta = try? JSONDecoder().decode(SessionMeta.self, from: data) {
                meta.isComplete = true
                if let out = try? JSONEncoder().encode(meta) {
                    try? out.write(to: metaURL, options: .atomic)
                }
            }
        }
        if let writer {
            try? writer.close()
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Retention end markComplete=\(markComplete, privacy: .public) folder=\(folder?.lastPathComponent ?? "nil", privacy: .public)") }
        }
    }

    /// Test seam: current retention folder if enabled.
    var retentionFolderForTesting: URL? {
        retentionLock.lock(); defer { retentionLock.unlock() }; return retentionFolder
    }

    /// The generation of the capture session this recorder most recently
    /// started. Callers capture this synchronously at stop-decision time and
    /// pass it into `stopAndFetchSamples` — the stop must never adopt a newer
    /// session's id (rapid re-record).
    var captureGeneration: Int { currentCaptureGeneration }

    /// Immutable copy of the current session's timing stamps. Safe from any
    /// thread (interior locking); intended for the stage-timing log lines.
    var lastSessionTiming: SessionTimingSnapshot { timingMarks.snapshot() }

    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    func prepare(preferredInputDeviceID: AudioDeviceID?) throws {
        try prepare(preferredInputDeviceID: preferredInputDeviceID, warmPool: nil)
    }

    func prepare(preferredInputDeviceID: AudioDeviceID?, warmPool: WarmEnginePool?) throws {
        // Task-1: consult pool freshness first — a fresh spare can be adopted
        // without rebuilding the graph inline (device-change win).
        if let pool = warmPool, pool.isFresh(for: preferredInputDeviceID) {
            if let graph = pool.take(for: preferredInputDeviceID) {
                if engine.isRunning {
                    engine.stop()
                }
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                    tapInstalled = false
                }
                exchange.withExclusiveAccess { state in
                    state.converter = nil
                    state.converterInputSampleRate = 0
                    state.converterInputChannelCount = 0
                }
                engine = graph.engine
                isPrepared = true
                preparedInputDeviceID = preferredInputDeviceID
                preparedStateInvalidated = false
                timingMarks.setTransportTag(AudioTransportTag.label(forDeviceID: preferredInputDeviceID))
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Adopted warm pool graph for deviceID=\(preferredInputDeviceID.map { String($0) } ?? "nil", privacy: .public)") }
                return
            }
        }
        if !AudioPrepareDecision.shouldReconfigure(
            isPrepared: isPrepared,
            lastDeviceID: preparedInputDeviceID,
            preferredDeviceID: preferredInputDeviceID,
            invalidated: preparedStateInvalidated
        ) {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio graph already prepared; skipping reconfigure") }
            return
        }
        preparedStateInvalidated = false

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw AudioRecorderError.micPermissionDenied
        @unknown default:
            throw AudioRecorderError.micPermissionDenied
        }

        if engine.isRunning {
            engine.stop()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        exchange.withExclusiveAccess { state in
            state.converter = nil
            state.converterInputSampleRate = 0
            state.converterInputChannelCount = 0
        }
        
        // Log current default input device details (to confirm e.g. Logitech C920)
        AudioDeviceDebug.logDefaultInputDeviceSummary()
        
        let input = engine.inputNode
        if let preferredInputDeviceID, let audioUnit = input.audioUnit {
            var id = preferredInputDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioRecorderError.engineStartFailed(
                    NSError(
                        domain: "Kalam.AudioRecorder",
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to bind input device (OSStatus \(status))"]
                    )
                )
            }
        }

        // K-49 lever (a): best-effort device-ring shrink on whichever device
        // the graph is bound to (preferred or system default input).
        let boundDeviceID: AudioDeviceID?
        if preferredInputDeviceID != nil {
            var bound = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioOutputUnitProperty_CurrentDevice,
                mScope: kAudioUnitScope_Global,
                mElement: 0)
            let inputAU = input.audioUnit
            let qStatus = inputAU.map {
                AudioUnitGetProperty($0, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &size)
            }
            boundDeviceID = (qStatus == noErr) ? bound : nil
            if boundDeviceID == nil {
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Device ring shrink skipped: bound-device query failed osStatus=\(qStatus.map { Int($0) } ?? -1, privacy: .public)") }
            }
        } else {
            var def = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let qStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &def)
            boundDeviceID = (qStatus == noErr) ? def : nil
            if boundDeviceID == nil {
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Device ring shrink skipped: default-input query failed osStatus=\(Int(qStatus), privacy: .public)") }
            }
        }
        // Task 0: classify the bound device's transport once per graph build
        // (built-in / usb / bluetooth) so baseline logs are route-filterable.
        timingMarks.setTransportTag(AudioTransportTag.label(forDeviceID: boundDeviceID))
        if let boundDeviceID {
            if let applied = Self.shrinkDeviceRingBuffer(deviceID: boundDeviceID) {
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Device ring buffer applied frames=\(applied, privacy: .public)") }
            } else {
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Device ring buffer shrink failed (set or read-back); leaving device default") }
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }
        
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Input format sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)") }
        
        // Prepare engine but don't start it yet - we'll start it when recording begins
        engine.prepare()
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio engine prepared tapBufferSize=\(self.tapBufferSizeFrames, privacy: .public)") }
        isPrepared = true
        preparedInputDeviceID = preferredInputDeviceID
    }

    /// Forces the next `prepare()` call to fully rebuild the audio graph
    /// (engine stop, tap removal, device re-bind). Called on CoreAudio device
    /// changes and system wake (microphone recovery after sleep or device change) — without it, prepare() early-returns
    /// on an unchanged device ID and stays bound to a stale device.
    func invalidatePreparedState() {
        preparedStateInvalidated = true
    }

    /// K-49 lever (a): shrink the device-level HAL ring so less un-drained
    /// audio sits in the driver at key-up. Best-effort: devices may clamp or
    /// refuse; the APPLIED value is returned after read-back, or nil when the
    /// set failed. Never fatal — recording proceeds either way.
    static func shrinkDeviceRingBuffer(deviceID: AudioDeviceID, requestedFrames: UInt32 = 512) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var requested = requestedFrames
        let setStatus = AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &requested)
        guard setStatus == noErr else { return nil }
        var applied: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let getStatus = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, &applied)
        guard getStatus == noErr else { return nil }
        return applied
    }

    var isPreparedForTesting: Bool { isPrepared }
    var preparedDeviceIDForTesting: AudioDeviceID? { preparedInputDeviceID }
    var isPreparedStateInvalidatedForTesting: Bool { preparedStateInvalidated }
    
    func startCollecting() throws {
        // microphone recovery after sleep or device change: reset capture state BEFORE touching the engine — the old
        // order (reset at the end) left stale state when engine.start()
        // failed, and the failure was silently swallowed.
        exchange.resetForNewSession()
        currentCaptureGeneration = exchange.currentGeneration()
        timingMarks.beginSession()

        if !engine.isRunning {
            do {
                try engine.start()
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio engine started for recording") }
                let liveOutputFormat = engine.inputNode.outputFormat(forBus: 0)
                let liveInputBusFormat = engine.inputNode.inputFormat(forBus: 0)
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Live input output format sampleRate=\(liveOutputFormat.sampleRate, privacy: .public) channels=\(liveOutputFormat.channelCount, privacy: .public)") }
                if KalamDiagnosticFlags.verboseAudio { logger.debug("Live input bus format sampleRate=\(liveInputBusFormat.sampleRate, privacy: .public) channels=\(liveInputBusFormat.channelCount, privacy: .public)") }
            } catch {
                // One recovery attempt: invalidate the stale graph binding
                // (sleep/wake, dock reconnect) and retry from a fresh prepare.
                logger.warning("Audio engine start failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public); attempting re-prepare")
                invalidatePreparedState()
                do {
                    try prepare(preferredInputDeviceID: preparedInputDeviceID)
                    try engine.start()
                    if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio engine started after re-prepare") }
                } catch {
                    throw AudioRecorderError.engineStartFailed(error)
                }
            }
        }
        // Single success point covers primary start, recovery re-start and an
        // already-running engine alike; latest-wins semantics in the marks box.
        timingMarks.markEngineStart()

        if !tapInstalled {
            // For input node taps, AVAudioEngine expects the input bus hardware format.
            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Installing tap sampleRate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)") }
            engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSizeFrames, format: tapFormat) { [weak self] (buffer, _) in
                self?.process(buffer: buffer)
            }
            tapInstalled = true

            // K-49 lever (b): pre-build the resample converter so the render
            // thread's first buffer skips construction.
            let prebuilt = exchange.prebuildConverter(
                inputSampleRate: tapFormat.sampleRate,
                inputChannelCount: tapFormat.channelCount
            )
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Converter pre-built ok=\(prebuilt, privacy: .public) inputSampleRate=\(tapFormat.sampleRate, privacy: .public)") }
        }

        if KalamDiagnosticFlags.verboseAudio { logger.debug("Started collecting audio samples") }
    }

    // MARK: Bounded engine start (main thread must never block on the HAL)

    private func setStartInFlight(_ value: Bool) {
        startFlightLock.lock()
        _isStartInFlight = value
        startFlightLock.unlock()
    }

    private func markStartAbandoned() {
        startFlightLock.lock()
        _abandonCurrentStart = true
        startFlightLock.unlock()
    }

    private func consumeStartAbandoned() -> Bool {
        startFlightLock.lock()
        defer { startFlightLock.unlock() }
        let wasAbandoned = _abandonCurrentStart
        _abandonCurrentStart = false
        return wasAbandoned
    }

    /// True while a bounded start is inside the engine (or wedged there).
    /// Main-thread engine access (prepare, finishStop, device refresh) must
    /// check this and defer instead of touching engine state concurrently.
    var isStartInFlight: Bool {
        startFlightLock.lock()
        defer { startFlightLock.unlock() }
        return _isStartInFlight
    }

    /// App-layer abandonment of the pending press (key-up during pending, Esc,
    /// superseding press, device change, wake, quit). The in-flight — possibly
    /// HAL-wedged — attempt can never commit a session after this; if it
    /// eventually returns it self-cleans (engine stop + graph invalidation).
    func abandonPendingStart() {
        markStartAbandoned()
    }

    /// Best-effort liveness probe: can CoreAudio name a default input device?
    /// A failed/unknown answer means the device is already gone (unplug, dock
    /// churn) and the engine start would just park on a dead node — fail
    /// before touching the graph. The query itself can block on a wedged HAL,
    /// which is why it runs off-main inside the bounded window, never on main.
    static func defaultInputDeviceLooksAlive() -> Bool {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    /// Engine stop + graph invalidation after an abandoned attempt. Runs on
    /// engineOpQueue only — the in-flight invariant guarantees exclusivity.
    private func performAbandonCleanup() {
        if engine.isRunning {
            engine.stop()
        }
        invalidatePreparedState()
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Bounded start self-cleaned after abandonment") }
    }

    /// Teardown for a STALE COMMIT: the bounded start succeeded, but the
    /// machine's pending start was rolled back while the engine was starting
    /// (stop/Esc/wake/quit during the window). The engine is live with no
    /// session behind it — stop it and force a fresh graph on the next press.
    /// Queued on engineOpQueue like every engine access.
    func stopEngineFromStaleCommit() {
        engineOpQueue.async { [self] in
            if engine.isRunning {
                engine.stop()
            }
            invalidatePreparedState()
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Stale commit: engine stopped, graph invalidated") }
        }
    }

    /// Runs `startCollecting()` off the main thread under a hard deadline
    /// (`AudioStartPolicy.timeoutMs`). A wedged `engine.start()` can no longer
    /// freeze the app: the deadline branch returns `.timedOut` on time, marks
    /// the attempt abandoned, and the parked attempt self-cleans when/if it
    /// ever returns. While in flight, main-thread engine access is deferred
    /// (see `isStartInFlight`), so engine state is never touched concurrently.
    func startCollectingBounded() async -> AudioStartPolicy.Outcome {
        // Supersede wait: a previous attempt may still hold the engine (a
        // superseded press finishing, or a wedged one never returning). Wait
        // within this attempt's budget instead of failing outright; if the
        // previous attempt is truly wedged, report the deadline, stay safe.
        let waitStart = CFAbsoluteTimeGetCurrent()
        while isStartInFlight {
            let waitedMs = Int((CFAbsoluteTimeGetCurrent() - waitStart) * 1000)
            if waitedMs >= AudioStartPolicy.timeoutMs {
                logger.warning("Bounded start skipped: previous attempt still in flight waitedMs=\(waitedMs, privacy: .public)")
                return .timedOut
            }
            try? await Task.sleep(nanoseconds: UInt64(AudioStartPolicy.inFlightWaitPollMs) * 1_000_000)
            if Task.isCancelled { return .superseded }
        }

        setStartInFlight(true)
        _ = consumeStartAbandoned() // clear any stale flag from a prior attempt
        let began = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { (continuation: CheckedContinuation<AudioStartPolicy.Outcome, Never>) in
            let resumeOnce = BoundedStartResumeOnce()
            engineOpQueue.async { [weak self] in
                guard let self else {
                    if resumeOnce.claim() { continuation.resume(returning: .failed) }
                    return
                }
                var didThrow = false
                do {
                    // Preflight (off-main): a dead default input fails before
                    // the engine graph is touched at all.
                    if !Self.defaultInputDeviceLooksAlive() {
                        throw AudioRecorderError.engineStartFailed(
                            NSError(
                                domain: "Kalam.AudioRecorder",
                                code: -1097,
                                userInfo: [NSLocalizedDescriptionKey: "No live default input device before engine start"]
                            )
                        )
                    }
                    try self.startCollecting()
                } catch {
                    didThrow = true
                }
                let wasAbandoned = self.consumeStartAbandoned()
                let final = AudioStartPolicy.classify(
                    elapsedMs: Int((CFAbsoluteTimeGetCurrent() - began) * 1000),
                    didThrow: didThrow,
                    wasAbandoned: wasAbandoned)
                if AudioStartPolicy.shouldSelfClean(wasAbandoned: wasAbandoned) {
                    self.performAbandonCleanup()
                } else if final == .failed {
                    // Both the primary start and the in-band recovery retry
                    // failed: force a fresh graph on the next press instead of
                    // reusing whatever wedged/failed state is on the engine.
                    self.invalidatePreparedState()
                }
                self.setStartInFlight(false)
                if resumeOnce.claim() { continuation.resume(returning: final) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(AudioStartPolicy.timeoutMs)
            ) { [weak self] in
                // Deadline won: the attempt is abandoned in place. It cannot
                // be interrupted — engine.start() has no cancellation surface —
                // so it parks in CoreAudio and self-cleans on return.
                self?.markStartAbandoned()
                if resumeOnce.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    // Post-roll capture is applied before stopping and fetching samples.
    // Convenience async wrapper (test seam): pins the generation at call time,
    // sleeps the post-roll, then finishes THAT session. Production callers
    // capture the generation before any suspension and call `finishStop`.
    func stopAndFetchSamples(postRollMs: Int = 200) async -> [Float] {
        let generation = currentCaptureGeneration
        let delayMs = max(0, min(500, postRollMs))
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        return finishStop(expectedGeneration: generation)
    }

    /// Synchronous stop critical section. Call on the main thread (production
    /// callers are MainActor-inherited tasks). Contains NO suspension points,
    /// so a newer session cannot start between the staleness check and the
    /// engine stop — a stop that was superseded by a rapid re-record returns
    /// empty WITHOUT touching the newer session's buffers or engine.
    func finishStop(expectedGeneration: Int) -> [Float] {
        guard exchange.currentGeneration() == expectedGeneration else {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Stop superseded by a newer capture session; skipping teardown") }
            setLastCaptureStats(.empty)
            return []
        }

        var out = exchange.stopCapture(expectedGeneration: expectedGeneration)

        // Stop the engine on the main thread to turn off the microphone indicator.
        // Bounded-start guard: while an off-main engine start holds the engine
        // (possibly wedged in the HAL), main must not touch it — the attempt's
        // own self-clean path owns teardown. Production stop paths cannot reach
        // this window (a pending start never committed a session), so this is
        // belt-and-braces for wake/cancel race edges.
        if engine.isRunning && !isStartInFlight {
            let stopStart = CFAbsoluteTimeGetCurrent()
            engine.stop()
            let stopElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio engine stopped stopMs=\(Int(stopElapsed), privacy: .public)") }
        }

        // Drain any residual frames from the converter (resampler tail) and reset it
        let drainedTail = exchange.drainConverterRemainder(expectedGeneration: expectedGeneration)
        if !drainedTail.isEmpty {
            if KalamDiagnosticFlags.verboseAudio { logger.debug("Drained converter tail samples=\(drainedTail.count, privacy: .public) durationMs=\(Int(Double(drainedTail.count) / 16_000.0 * 1000), privacy: .public)") }
        }

        out.append(contentsOf: drainedTail)

        let durationMs = out.isEmpty ? 0 : Int(Double(out.count) / 16_000.0 * 1000)
        let (callbacks, dropped) = exchange.stats()
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Stopped collecting samples=\(out.count, privacy: .public) durationMs=\(durationMs, privacy: .public) callbacks=\(callbacks, privacy: .public) dropped=\(dropped, privacy: .public)") }

        // Debug: Check non-zero and max amplitude
        let nonZeroCount = out.lazy.filter { abs($0) > 0.0001 }.count
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio sample summary nonZeroSamples=\(nonZeroCount, privacy: .public) totalSamples=\(out.count, privacy: .public)") }
        let maxAmplitude = out.map({ abs($0) }).max() ?? 0
        if KalamDiagnosticFlags.verboseAudio { logger.debug("Audio sample maxAmplitude=\(maxAmplitude, privacy: .public)") }
        setLastCaptureStats(CaptureStats(
            sampleCount: out.count, durationMs: durationMs,
            callbacks: callbacks, dropped: dropped,
            nonZeroCount: nonZeroCount, maxAmplitude: maxAmplitude))
        return out
    }

    /// Trailing capture samples for post-roll polling (consumer side; may
    /// block). Reads the waveform ring, which mirrors everything published
    /// this session — capacity 4096 samples (256 ms at 16 kHz) covers the
    /// three 20 ms analysis windows the tail verdict needs.
    func recentCaptureSamples(count: Int) -> [Float] {
        exchange.waveform(sampleCount: count)
    }

    /// Live tap-callback count for the mid-hold stall watchdog. Consumer
    /// side; mirrors `stats().callbacks` without the drop counter.
    func publishedCallbackCount() -> Int {
        exchange.stats().callbacks
    }

    /// Ring read-back helper: estimate room SNR from the recent waveform
    /// ring (256 ms capacity). Best-effort: empty ring → 0 dB. Pure via
    /// `PostRollDecision.estimatedSNR`. Never logs content.
    func estimateRoomSNR() -> Float {
        let cap = exchange.recentWaveformCapacity
        let snapshot = recentCaptureSamples(count: cap)
        // Ring read-back: cap (4096) is 256 ms at 16 kHz — enough windows for
        // stable p05/p95. Falls back to whatever is available early.
        guard !snapshot.isEmpty else { return 0 }
        return PostRollDecision.estimatedSNR(samples: snapshot, sampleRate: 16_000)
    }

    /// K-49: adaptive post-roll with energy-polled early exit. Polls the
    /// trailing buffer every `config.pollIntervalMs`; finishes as soon as the
    /// tail reads silent for `requiredSilentPolls` consecutive polls AND the
    /// minimum elapsed, or at the ceiling, whichever comes first. The
    /// generation was pinned by the CALLER before the first suspension; the
    /// final teardown is the same `finishStop` critical section the fixed
    /// sleep used, so rapid-re-record staleness semantics are unchanged.
    ///
    /// Task 3 (K-54): when `config.extensionPolicy == .snrAware`, the ceiling
    /// and quiet gate extend per estimated room SNR and segment duration.
    /// `segmentEstimateMs` is required for the relative cap; when nil the
    /// policy falls back to the fixed path (backward compat for tests).
    func stopWithEarlyExit(pinnedGeneration: Int, config: PostRollDecision.Config) async -> [Float] {
        return await stopWithEarlyExit(pinnedGeneration: pinnedGeneration, config: config, segmentEstimateMs: nil)
    }

    func stopWithEarlyExit(pinnedGeneration: Int, config: PostRollDecision.Config, segmentEstimateMs: Int?) async -> [Float] {
        // SNR-aware path needs both a policy and a segment estimate to compute
        // the per-segment relative cap. Fall back to the fixed loop otherwise.
        let usesSNRPolicy: Bool = {
            if case .snrAware = config.extensionPolicy, segmentEstimateMs != nil { return true }
            return false
        }()
        if !usesSNRPolicy {
            setLastPostRollSNR(0)
            // Telemetry: the fixed path was previously silent — log the same
            // start/done shape as the SNR-aware path so user-provided logs can
            // distinguish "finished at floor" from "ran to ceiling".
            // Counts/timings only, never audio content.
            if KalamDiagnosticFlags.verboseAudio { logger.debug("PostRoll fixed start minMs=\(config.minMs, privacy: .public) maxMs=\(config.maxMs, privacy: .public) pollMs=\(config.pollIntervalMs, privacy: .public) requiredSilentPolls=\(config.requiredSilentPolls, privacy: .public)") }
            let start = CFAbsoluteTimeGetCurrent()
            var consecutiveSilent = 0
            var pollCount = 0
            while true {
                try? await Task.sleep(nanoseconds: config.minIntervalNanos)
                if Task.isCancelled { break }
                pollCount += 1
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                if PostRollDecision.tailIsSilent(
                    samples: recentCaptureSamples(count: 960),
                    sampleRate: 16_000
                ) {
                    consecutiveSilent += 1
                } else {
                    consecutiveSilent = 0
                }
                if PostRollDecision.shouldFinish(
                    config: config,
                    elapsedMs: elapsedMs,
                    consecutiveSilentPolls: consecutiveSilent
                ) {
                    let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    if KalamDiagnosticFlags.verboseAudio { logger.debug("PostRoll fixed done totalMs=\(totalMs, privacy: .public) polls=\(pollCount, privacy: .public) consecutiveSilent=\(consecutiveSilent, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)") }
                    break
                }
            }
            return finishStop(expectedGeneration: pinnedGeneration)
        }

        // SNR-aware: capture SNR once at key-up from the ring read-back
        // (stable for the stop duration; avoids re-estimating on every poll).
        let snrDb = estimateRoomSNR()
        setLastPostRollSNR(snrDb)
        let segmentMs = segmentEstimateMs ?? 0
        let mode: String = {
            switch config.extensionPolicy {
            case .snrAware(let c):
                return snrDb < c.trustSnrDb ? "snrAware-low" : "snrAware-trusted"
            case .fixed:
                return "fixed"
            }
        }()
        if KalamDiagnosticFlags.verboseAudio { logger.debug("PostRoll SNR-aware start snrDb=\(snrDb, privacy: .public) mode=\(mode, privacy: .public) segmentEstimateMs=\(segmentMs, privacy: .public) minMs=\(config.minMs, privacy: .public) maxMs=\(config.maxMs, privacy: .public) effectiveMaxMs=\(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: segmentMs, snrDb: snrDb), privacy: .public)") }
        let start = CFAbsoluteTimeGetCurrent()
        var consecutiveSilent = 0
        var pollCount = 0
        while true {
            try? await Task.sleep(nanoseconds: config.minIntervalNanos)
            if Task.isCancelled { break }
            pollCount += 1
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let tail = recentCaptureSamples(count: 960)
            let isSilent = PostRollDecision.tailIsSilent(samples: tail, sampleRate: 16_000)
            let isSpeechLike: Bool = {
                switch config.extensionPolicy {
                case .snrAware(let c):
                    return PostRollDecision.tailIsSpeechLike(samples: tail, sampleRate: 16_000, floorMarginDb: c.floorMarginDb)
                case .fixed:
                    return !isSilent
                }
            }()
            if isSilent {
                consecutiveSilent += 1
            } else {
                consecutiveSilent = 0
            }
            if PostRollDecision.shouldFinishExtended(
                config: config,
                segmentEstimateMs: segmentMs,
                snrDb: snrDb,
                elapsedMs: elapsedMs,
                consecutiveSilentPolls: consecutiveSilent,
                tailIsSpeechLike: isSpeechLike
            ) {
                break
            }
        }
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if KalamDiagnosticFlags.verboseAudio { logger.debug("PostRoll SNR-aware done totalMs=\(totalMs, privacy: .public) polls=\(pollCount, privacy: .public) consecutiveSilent=\(consecutiveSilent, privacy: .public) snrDb=\(snrDb, privacy: .public) mode=\(mode, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)") }
        return finishStop(expectedGeneration: pinnedGeneration)
    }

    func cancelCapture() async {
        _ = finishStop(expectedGeneration: currentCaptureGeneration)
    }

    /// Test-only: activate capture state without touching the audio engine
    /// (the test host has no microphone input device, so AVAudioEngine input
    /// graph construction asserts — the app's onboarding guarantees one in
    /// production). Mirrors the state portion of `startCollecting()`.
    func beginCollectingForTesting() {
        exchange.resetForNewSession()
        currentCaptureGeneration = exchange.currentGeneration()
    }
    
    /// Render-thread entry point (installTap callback). Never blocks — the
    /// publish path try-locks and drops (and counts) on contention (render-thread audio lock fix).
    /// Internal for testability (KalamTests drives it with synthetic buffers).
    @discardableResult
    func process(buffer: AVAudioPCMBuffer) -> Bool {
        // Task 0: one-time stamp; steady-state callbacks exit on the nil-check.
        timingMarks.markFirstBufferIfNeeded()
        return exchange.publish(buffer)
    }

    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        exchange.waveform(sampleCount: sampleCount)
    }

    deinit {
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        if KalamDiagnosticFlags.verboseAudio { logger.debug("AudioRecorder deinitialized; engine stopped and tap removed") }
    }
}
