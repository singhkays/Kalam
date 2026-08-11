# K-10 Implementation Plan — Non-Blocking Audio Render Thread (`AudioCaptureExchange`)

> **For agentic workers:** execute task-by-task; checkboxes track progress. Read `app/docs/IMPROVEMENT_PLAN.md` protocol first (status legend, claim → verify → ✅). Re-verify every line number and re-read each file right before editing — the shared-repo tree drifts (sibling sessions commit on the same `main`). Run all commands from the repo root `/Volumes/My Shared Files/GitHub/Kalam`. Do not `git add -A`; stage only your hunks. The tree is intentionally RED between the Task 1 and Task 2 commits (TDD) — do not merge or reorder tasks.

**Goal:** Eliminate the priority-inversion risk on the real-time audio render thread: the `installTap` callback must never block on a lock/queue that consumer threads (main thread waveform polling, transcription task) hold. Replace the blocking `bufferQueue.sync` in the tap callback with a non-blocking try-lock publish; on contention the buffer is dropped and counted instead of stalling the render thread.

**Architecture:** Extract all capture-side mutable state (buffers, converter, counters) from `AudioRecorder` into a new `AudioCaptureExchange` type that owns one `OSAllocatedUnfairLock` (i.e. `os_unfair_lock`, the sanctioned real-time primitive). The render thread enters through `publish(_:)`, which uses `withLockIfAvailable` (try-lock) — never blocks, drops + counts on contention. All consumer-side operations (`resetForNewSession`, `stopCapture`, `waveform`, `drainConverterRemainder`, `stats`) use blocking exclusive access, which is safe because they run on non-render threads. The audio conversion pipeline (AVAudioConverter + linear-resample fallback, converter rebuild on format change, waveform trimming, `secureZero`) is moved **verbatim** into the exchange — zero behavioral change to what audio ends up in `sampleBuffer`, only *where the lock wait can happen*.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioEngine`/`AVAudioConverter`/`AVAudioPCMBuffer`), `os` (`OSAllocatedUnfairLock`, macOS 13+; app deployment target 14.6 ✓), XCTest (`KalamTests`, module `Kalam_test`), Xcode folder-synchronized groups (new files auto-join targets — no pbxproj edits).

## Global Constraints

- **Never block the audio render thread** — the tap callback path (`process` → `publish`) must contain no blocking primitive: no `DispatchQueue.sync`, no blocking lock, no `wait`. This is the K-10 invariant; the Task 1 RED test pins it.
- **Never log transcript or audio content** — counts/timings only, `privacy: .public` (repo rule). The new `dropped=` field is a count.
- **Audio buffers stay `secureZero()`'d** — stop + deinit zeroing is preserved (moves into `AudioCaptureExchange.stopCapture()`/`deinit`).
- **Conversion behavior is byte-identical** — same AVAudioConverter, same rebuild conditions, same PCM/linear fallback, same waveform capacity (4096). This plan changes *synchronization*, not *audio math*.
- **No new entitlements, no network code, no `Task.detached`.**
- **Do not weaken `prepare()`'s invariant** — `prepare()` runs only while the engine is stopped (it stops the engine at its top), so its converter reset is wrapped in `withExclusiveAccess` defensively; no render callbacks can be in flight.
- **Post-roll semantics unchanged** — `collecting` stays `true` through the post-roll sleep; the stop critical section sets it `false` under the lock, so any publish that completed before the section is captured, and any publish during/after is dropped-or-skipped, never half-appended.
- **Concurrent-session rules (shared VirtIOFS):** `AudioRecorder.swift` is clean at plan time (2026-08-11) but siblings may touch it; re-check `git status` before editing, stage only your files. `IMPROVEMENT_PLAN.md` note must be re-read before adding (a sibling may have inserted one).
- **Line numbers below were verified 2026-08-11** against the current tree (`git log` HEAD = `8971eee`). Re-locate before editing.
- **Test commands (from repo root):**
  - Targeted new tests: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AudioCaptureExchangeTests CODE_SIGNING_ALLOWED=NO`
  - Build: `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Full suite: `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - Engine sanity (unchanged by this plan): `./scripts/test-engine.sh` (expect 41 green)

---

## Current state (verified 2026-08-11)

`Services/AudioRecorder.swift` (417 lines) synchronizes everything on a serial `DispatchQueue`:

```
line 57:   private let bufferQueue = DispatchQueue(label: "Kalam.AudioBuffer")
line 169:  engine.inputNode.installTap(...) { [weak self] (buffer, _) in self?.process(buffer: buffer) }
line 241:  process(buffer:) -> bufferQueue.sync { ... }     // ← RENDER THREAD BLOCKS HERE
line 175:  startCollecting()   -> bufferQueue.sync { collecting = true; reset }
line 194:  stopAndFetchSamples -> bufferQueue.sync { collecting = false; out = sampleBuffer; secureZero; ... }
line 224:  let callbacks = bufferQueue.sync { callbackCount }
line 364:  recentWaveform()    -> bufferQueue.sync { ... }
line 377:  drainConverterRemainder() -> bufferQueue.sync { converter flush loop }
```

Contention windows (who holds the queue while the render thread waits):

1. **The stop path (worst case):** `KalamApp.swift:977` calls `await audio.stopAndFetchSamples(postRollMs:)` from the MainActor-inherited transcription task. Its critical section (`AudioRecorder.swift:194–201`) copies the accumulated `sampleBuffer` (a 92 MB copy for a 10-minute dictation; COW forces a full copy when `secureZero()` mutates it), memsets it, and deallocs — milliseconds to tens of milliseconds — while the render thread is still live (the engine stops only *after* the section, at `:204–213`). Every tap callback in that window blocks the render thread for the whole section. The converter drain (`:377–404`) is a second multi-ms hold.
2. **Waveform polling:** the overlay polls `audio.recentWaveform(sampleCount: 512)` every ~33 ms (~30 Hz) from `DictationOverlayController.swift:200–212` (`KalamApp.swift:144`). Each poll takes the queue; a render callback colliding with a poll stalls for its duration (µs — small, but the same class of bug).
3. **Rapid re-record (K-01 interaction):** a new `startCollecting()` while the previous session's `stopAndFetchSamples` still runs makes the render thread wait on a queue whose holder is mid-stop. The new `AudioCaptureExchange` serializes these on the lock with the same semantics — no change needed, just noted.

Call sites of `AudioRecorder` (all unchanged by this plan): `KalamApp.swift:144` (waveform provider), `:919` (`startCollecting`), `:977` (`stopAndFetchSamples`), `:1109` (`cancelCapture`). `KalamTests` has **no** existing references to `AudioRecorder` (verified 2026-08-11) — the new test seam is safe.

## Decision & rejected alternatives

**Chosen: single `OSAllocatedUnfairLock` + try-lock publish (`AudioCaptureExchange`).**

- The render thread enters through `lock.withLockIfAvailable { ... }` — `os_unfair_lock_trylock` semantics, returns `nil` immediately when a consumer holds the lock. On contention the buffer is **dropped and counted** (`dropCounter`, its own tiny lock because the drop path is exactly the path where the main lock is unavailable) and surfaced in the stop log (`dropped=N`) — the human gate can confirm `N == 0` in normal operation.
- The conversion pipeline stays in the publish critical section (as today) — the render thread still *does* its own conversion work (pre-existing, out of K-10 scope, see Future work), but it **never waits** on another thread.
- Consumer-side operations block on the same lock — safe: they run on the main thread / transcription task / waveform task, never the render thread.
- Why `OSAllocatedUnfairLock` over raw `os_unfair_lock`: same primitive, no manual `UnsafeMutablePointer` memory management, `withLockIfAvailable` gives try-lock for free. macOS 13+; deployment target 14.6 ✓. `State` is `@unchecked Sendable` because it holds `AVAudioConverter` (not `Sendable`) — sound because *all* access is serialized by the lock.

- **Rejected — "keep `DispatchQueue` but with a faster/`async` variant":** any `.sync` from the render thread is the bug; GCD has no try-lock API. QoS elevation does not apply reliably to real-time audio threads.
- **Rejected — `NSLock`:** blocking lock, no try variant worth using here; `os_unfair_lock` is the sanctioned real-time primitive.
- **Rejected — full lock-free SPSC ring with consumer-side conversion:** the "right" long-term shape, but it changes *where and when* conversion happens (downmix fidelity for multi-channel devices like the Logitech C920 seen in `prepare()` logs, converter state ownership, drain cadence machinery) — a behavioral surface far bigger than K-10's scope. Conversion placement is pre-existing behavior; noted as a K-22 candidate in Future work.
- **Rejected — dropping without counting:** the `dropped=` counter is what makes the 🧑 gate ("no audio glitches under contention") falsifiable from the log.
- **Rejected — `ManagedAtomic` (swift-atomics) for counters:** new package dependency for a diagnostic counter; overkill.
- **Rejected — make the callback skip work when `collecting == false` without the lock:** a plain cross-thread `Bool` read is a data race in Swift 6 terms; the lock already covers this.

---

## Task 1: Test seam + RED contention test (against current code)

**Files:**
- Modify: `app/Kalam/Services/AudioRecorder.swift:240` (`private func process` → `func process`; one-line seam)
- Create: `app/KalamTests/AudioCaptureExchangeTests.swift` (RED test + helpers only; unit tests arrive in Task 3)

**Interfaces:**
- Produces: `AudioRecorder.process(buffer:) -> Bool` as an **internal** method (render-thread entry, test seam); test-file helpers `makeSyntheticBuffer(sampleRate:frames:)` and `StallMeter`.
- Consumes: existing `AudioRecorder.startCollecting()`, `stopAndFetchSamples(postRollMs:)`, `process(buffer:)` — all present in current code.

- [ ] **Step 1: Make `process` internal (seam)**

In `app/Kalam/Services/AudioRecorder.swift`, change line 240:

```swift
    private func process(buffer: AVAudioPCMBuffer) {
```
to:
```swift
    /// Render-thread entry point (installTap callback). Never blocks — the
    /// publish path try-locks and drops (and counts) on contention (K-10).
    /// Internal for testability (KalamTests drives it with synthetic buffers).
    @discardableResult
    func process(buffer: AVAudioPCMBuffer) -> Bool {
```

- [ ] **Step 2: Write the RED test**

Create `app/KalamTests/AudioCaptureExchangeTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import Kalam_test

/// K-10 regression pin. The render-thread publish path (`process`) must never
/// block behind a consumer holding the capture state. RED on the pre-fix code:
/// `process` does `bufferQueue.sync`, so the producer iteration colliding with
/// the (multi-ms) stop critical section stalls for its full duration. GREEN
/// after Task 2: `publish` try-locks and drops instead.
///
/// Timing-based by necessity (the "never blocks" property is a latency bound),
/// but the margins are wide: the preload makes the stop section ~8–20 ms on any
/// hardware, while the bound (5 ms) is ~100× the post-fix publish (~50 µs).
final class AudioCaptureExchangeTests: XCTestCase {

    func testProducerDoesNotStallWhileStopRuns() async throws {
        let recorder = AudioRecorder()
        // Sets collecting = true without needing a microphone: engine.start()
        // fails without TCC permission, logs a warning, and startCollecting
        // continues to install the tap + reset state.
        recorder.startCollecting()

        // Preload ~480 s of 48 kHz audio so the stop critical section (COW copy
        // + secureZero + dealloc of ~92 MB) is long enough to measure reliably.
        recorder.process(buffer: makeSyntheticBuffer(frames: AVAudioFrameCount(48_000 * 480)))

        // Producer hammering the render-thread entry; signals after its first
        // iteration so the consumer's stop section provably overlaps the loop.
        let producerStarted = DispatchSemaphore(value: 0)
        let producerDone = DispatchGroup()
        let meter = StallMeter()
        producerDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.process(buffer: makeSyntheticBuffer(frames: 1024)) // warm-up
            producerStarted.signal()
            for _ in 0..<10_000 {
                let start = CFAbsoluteTimeGetCurrent()
                recorder.process(buffer: makeSyntheticBuffer(frames: 1024))
                meter.record(CFAbsoluteTimeGetCurrent() - start)
            }
            producerDone.leave()
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 5), .success)
        let samples = await recorder.stopAndFetchSamples(postRollMs: 0)
        XCTAssertEqual(producerDone.wait(timeout: .now() + 30), .success)

        let maxStall = meter.max
        XCTAssertLessThan(
            maxStall, 0.005,
            "K-10: render-thread publish stalled \(Int(maxStall * 1000)) ms — must never block on the capture lock"
        )
        // The preload must be fully captured (480 s × 16 kHz = 7,680,000 samples;
        // the resampler tail adds a little, and a live mic adds more — lower
        // bound only, to stay deterministic).
        XCTAssertGreaterThanOrEqual(samples.count, 7_680_000, "preload must be fully captured")
    }
}

// MARK: - Helpers

/// Deterministic non-silent PCM buffer at the given format (sine wave).
private func makeSyntheticBuffer(sampleRate: Double = 48_000, channels: Int = 1, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] {
        for i in 0..<Int(frames) {
            channel[i] = sin(Float(i) * 0.01)
        }
    }
    return buffer
}

/// Swift-6-safe max-of-durations accumulator (mutating a captured var across
/// threads is a compile error in Swift 6).
private final class StallMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _max: TimeInterval = 0
    func record(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _max = max(_max, value)
    }
    var max: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _max
    }
}
```

- [ ] **Step 3: Run it — verify it FAILS (RED)**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AudioCaptureExchangeTests CODE_SIGNING_ALLOWED=NO
```

Expected: `testProducerDoesNotStallWhileStopRuns` fails with `XCTAssertLessThan failed: ("0.0XX" is less than "0.005") is not true` — the colliding producer iteration stalls for the full stop critical section. (If the machine is extremely fast and the stall lands under 5 ms, double the preload to `48_000 * 960` and re-run; the section scales linearly with payload.)

- [ ] **Step 4: Commit the RED test**

```bash
git add app/Kalam/Services/AudioRecorder.swift app/KalamTests/AudioCaptureExchangeTests.swift
git commit -m "test(K-10): RED contention test — render-thread publish must never block"
```

Note: the tree is intentionally red until Task 2's commit.

---

## Task 2: Extract `AudioCaptureExchange` + rewire `AudioRecorder`

**Files:**
- Create: `app/Kalam/Services/AudioCaptureExchange.swift` (full file below; folder-synced group → auto-joins the app target)
- Modify: `app/Kalam/Services/AudioRecorder.swift` (10 edit sites, exact old→new below)

**Interfaces:**
- Produces: `AudioCaptureExchange` with `publish(_:) -> Bool` (render thread, non-blocking), `withExclusiveAccess`, `resetForNewSession()`, `stopCapture() -> [Float]`, `waveform(sampleCount:) -> [Float]`, `drainConverterRemainder() -> [Float]`, `stats() -> (callbacks: Int, dropped: Int)`; `AudioRecorder.process(buffer:) -> Bool` becomes a one-line wrapper.
- Consumes: existing `AudioRecorder` call sites (`KalamApp.swift:144/919/977/1109`) — signatures unchanged.

- [ ] **Step 1: Create `app/Kalam/Services/AudioCaptureExchange.swift`**

```swift
import Foundation
import os
import OSLog
@preconcurrency import AVFoundation

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

/// Thread-safe exchange between the audio render thread (producer) and Kalam's
/// consumer threads (main thread, transcription task).
///
/// K-10: the render thread must NEVER block. `publish` acquires the lock with a
/// try-lock (`os_unfair_lock_trylock` behind `OSAllocatedUnfairLock.withLockIfAvailable`):
/// when a consumer holds the lock, the buffer is dropped and counted instead of
/// stalling the render thread (priority-inversion risk). All consumer-side
/// operations may block; they run on non-render threads.
///
/// All state is only ever touched inside `lock` (or `dropCounter`), which is why
/// the `@unchecked Sendable` conformances are sound: `AVAudioConverter` is not
/// `Sendable`, so `State` cannot be a plain `Sendable` struct.
final class AudioCaptureExchange: @unchecked Sendable {

    struct State: @unchecked Sendable {
        var collecting = false
        var callbackCount = 0
        var sampleBuffer: [Float] = []
        var recentWaveformSamples: [Float] = []
        var converter: AVAudioConverter?
        var converterInputSampleRate: Double = 0
        var converterInputChannelCount: AVAudioChannelCount = 0
    }

    private let logger = Logger(subsystem: "singhkays.Kalam", category: "AudioCaptureExchange")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    /// Drop counter for buffers lost to lock contention. Guarded by its own lock
    /// because the drop path is exactly the path where `lock` is unavailable.
    private let dropCounter = OSAllocatedUnfairLock(initialState: 0)

    let recentWaveformCapacity = 4096
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Render thread (never blocks)

    /// Render-thread entry point. Never blocks: try-locks and drops (and counts)
    /// the buffer when a consumer currently holds the lock.
    /// - Returns: `false` only for a contention drop. Buffers arriving after
    ///   `collecting == false` are skipped but return `true` (not a drop).
    @discardableResult
    func publish(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let processed = lock.withLockIfAvailable({ state -> Bool in
            guard state.collecting else { return true }
            state.callbackCount += 1
            processLocked(buffer, into: &state)
            return true
        }) else {
            dropCounter.withLockIfAvailable { $0 += 1 }
            return false
        }
        return processed
    }

    // MARK: - Consumer side (may block)

    func withExclusiveAccess<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    func resetForNewSession() {
        lock.withLock { state in
            state.collecting = true
            state.callbackCount = 0
            state.sampleBuffer.removeAll(keepingCapacity: true)
            state.recentWaveformSamples.removeAll(keepingCapacity: true)
            // Do not reset the converter here; keep across sessions until
            // stop/drain to preserve internal filter state.
        }
    }

    func stopCapture() -> [Float] {
        lock.withLock { state in
            state.collecting = false
            let out = state.sampleBuffer
            state.sampleBuffer.secureZero()
            state.sampleBuffer.removeAll(keepingCapacity: false)
            state.recentWaveformSamples.secureZero()
            state.recentWaveformSamples.removeAll(keepingCapacity: false)
            return out
        }
    }

    func waveform(sampleCount: Int) -> [Float] {
        lock.withLock { state in
            guard !state.recentWaveformSamples.isEmpty else { return [] }
            let count = max(8, sampleCount)
            if state.recentWaveformSamples.count <= count {
                return state.recentWaveformSamples
            }
            return Array(state.recentWaveformSamples.suffix(count))
        }
    }

    func stats() -> (callbacks: Int, dropped: Int) {
        let callbacks = lock.withLock { $0.callbackCount }
        let dropped = dropCounter.withLock { $0 }
        return (callbacks, dropped)
    }

    /// Drain residual converter frames at stream end (~10–30 ms of audio).
    func drainConverterRemainder() -> [Float] {
        lock.withLock { state in
            var leftovers: [Float] = []
            guard let converter = state.converter else { return [] }
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: 2048) else { break }
                out.frameLength = 0
                let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
                if status == .haveData {
                    if let ch = out.floatChannelData?[0] {
                        let frames = Int(out.frameLength)
                        leftovers.append(contentsOf: UnsafeBufferPointer(start: ch, count: frames))
                    }
                    continue
                }
                break
            }
            converter.reset()
            return leftovers
        }
    }

    // MARK: - Conversion (moved verbatim from AudioRecorder.process; runs under the lock)

    private func processLocked(_ buffer: AVAudioPCMBuffer, into state: inout State) {
        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        let needsConverterRebuild =
            state.converter == nil
            || state.converterInputSampleRate != inputFormat.sampleRate
            || state.converterInputChannelCount != inputFormat.channelCount

        if needsConverterRebuild {
            guard let rebuilt = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                logger.warning("Failed to create AVAudioConverter inputSampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
                return
            }
            state.converter = rebuilt
            state.converterInputSampleRate = inputFormat.sampleRate
            state.converterInputChannelCount = inputFormat.channelCount
        }
        guard let converter = state.converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64.0)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            logger.warning("Failed to create output buffer")
            return
        }

        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)

        if status == .error {
            if let e = convError {
                logger.warning("Conversion error; using PCM fallback errorSummary=\(privacySafeErrorSummary(e), privacy: .public)")
            } else {
                logger.warning("Conversion error unknown; using PCM fallback")
            }
            appendPCMBufferFallback(buffer, into: &state)
            return
        }

        let frames = Int(outBuffer.frameLength)
        if frames > 0 {
            guard let channel = outBuffer.floatChannelData?[0] else {
                logger.warning("No float channel data available; using PCM fallback")
                appendPCMBufferFallback(buffer, into: &state)
                return
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
            state.sampleBuffer.append(contentsOf: samples)
            state.recentWaveformSamples.append(contentsOf: samples)
            let overflow = state.recentWaveformSamples.count - recentWaveformCapacity
            if overflow > 0 {
                state.recentWaveformSamples.removeFirst(overflow)
            }
        } else {
            appendPCMBufferFallback(buffer, into: &state)
        }
    }

    private func appendPCMBufferFallback(_ buffer: AVAudioPCMBuffer, into state: inout State) {
        let mono = extractMonoFloatSamples(from: buffer)
        guard !mono.isEmpty else { return }
        let resampled = resampleLinear(mono, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        guard !resampled.isEmpty else { return }
        state.sampleBuffer.append(contentsOf: resampled)
        state.recentWaveformSamples.append(contentsOf: resampled)
        let overflow = state.recentWaveformSamples.count - recentWaveformCapacity
        if overflow > 0 {
            state.recentWaveformSamples.removeFirst(overflow)
        }
    }

    private func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: frames))

        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int16.max) }

        case .pcmFormatInt32:
            guard let channel = buffer.int32ChannelData?[0] else { return [] }
            return (0..<frames).map { Float(channel[$0]) / Float(Int32.max) }

        default:
            return []
        }
    }

    private func resampleLinear(_ input: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard inRate > 0, outRate > 0 else { return [] }
        guard abs(inRate - outRate) > 0.001 else { return input }

        let outputCount = Int(Double(input.count) * outRate / inRate)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let scale = inRate / outRate
        for i in 0..<outputCount {
            let src = Double(i) * scale
            let lo = Int(src)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(src - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }

    deinit {
        lock.withLock { state in
            state.sampleBuffer.secureZero()
            state.recentWaveformSamples.secureZero()
        }
    }
}
```

- [ ] **Step 2: Rewire `AudioRecorder` — apply these 8 edits**

Edit 1 — replace lines 50–61 (stored state + queue) with:

```swift
    private var isPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioDeviceID?

    // K-10: all capture state (buffers, converter, counters) lives behind
    // AudioCaptureExchange; the render thread publishes non-blockingly
    // (try-lock), consumers use exclusive access.
    private let exchange = AudioCaptureExchange()
```

(Removed: `callbackCount`, `targetFormat`, `bufferQueue`, `collecting`, `sampleBuffer`, `recentWaveformSamples`, `recentWaveformCapacity` — all moved into `AudioCaptureExchange`.)

Edit 2 — in `prepare()` (currently lines 105–107), wrap the converter reset:

```swift
        exchange.withExclusiveAccess { state in
            state.converter = nil
            state.converterInputSampleRate = 0
            state.converterInputChannelCount = 0
        }
```

Edit 3 — in `startCollecting()`, replace the `bufferQueue.sync { ... }` block (lines 175–181) with:

```swift
        exchange.resetForNewSession()
```

Edit 4 — in `stopAndFetchSamples()`, replace the `var out: [Float] = []` + `bufferQueue.sync { ... }` block (lines 193–201) with:

```swift
        var out = exchange.stopCapture()
```

Edit 5 — in `stopAndFetchSamples()`, replace the stats read + log (lines 224–225) with:

```swift
        let (callbacks, dropped) = exchange.stats()
        logger.info("Stopped collecting samples=\(out.count, privacy: .public) durationMs=\(durationMs, privacy: .public) callbacks=\(callbacks, privacy: .public) dropped=\(dropped, privacy: .public)")
```

Edit 6 — replace `process` + the three fallback helpers (lines 240–361: `process`, `appendPCMBufferFallback`, `extractMonoFloatSamples`, `resampleLinear`) with the wrapper (from Task 1):

```swift
    /// Render-thread entry point (installTap callback). Never blocks — the
    /// publish path try-locks and drops (and counts) on contention (K-10).
    /// Internal for testability (KalamTests drives it with synthetic buffers).
    @discardableResult
    func process(buffer: AVAudioPCMBuffer) -> Bool {
        exchange.publish(buffer)
    }
```

Edit 7 — replace the `recentWaveform` body (lines 363–372) with:

```swift
    func recentWaveform(sampleCount: Int = 512) -> [Float] {
        exchange.waveform(sampleCount: sampleCount)
    }
```

Edit 8 — replace the `drainConverterRemainder` body (lines 375–404) with:

```swift
    private func drainConverterRemainder() -> [Float] {
        exchange.drainConverterRemainder()
    }
```

Edit 9 — in `deinit` (lines 413–414), delete the two `secureZero()` lines (the exchange's deinit zeros the buffers) and keep the engine stop/tap removal/log:

```swift
    deinit {
        if isPrepared {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        logger.info("AudioRecorder deinitialized; engine stopped and tap removed")
    }
```

(`privacySafeErrorSummary` stays in `AudioRecorder.swift` — still used by the engine-start warning at line 160. The exchange has its own file-private copy.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` (grep the output — a trailing blank line is normal). If a compile error points at a leftover `bufferQueue`/`sampleBuffer`/`converter` reference in `AudioRecorder.swift`, it is a missed edit site — re-grep: `search_files pattern='bufferQueue|sampleBuffer|recentWaveformSamples|callbackCount|targetFormat' path=app/Kalam/Services/AudioRecorder.swift` should return **zero** matches (except the `exchange.` calls and the doc comment).

- [ ] **Step 4: Run the Task 1 test — verify it now PASSES (GREEN)**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AudioCaptureExchangeTests CODE_SIGNING_ALLOWED=NO
```

Expected: `testProducerDoesNotStallWhileStopRuns` passes — producer iterations are now µs (try-lock), contention buffers dropped, preload fully captured.

- [ ] **Step 5: Commit**

```bash
git add app/Kalam/Services/AudioCaptureExchange.swift app/Kalam/Services/AudioRecorder.swift
git commit -m "fix(K-10): non-blocking render-thread publish via AudioCaptureExchange (os_unfair_lock try-lock)"
```

---

## Task 3: `AudioCaptureExchange` unit pins

**Files:**
- Modify: `app/KalamTests/AudioCaptureExchangeTests.swift` (append the tests below to the class)

**Interfaces:**
- Consumes: `AudioCaptureExchange` from Task 2 — `publish(_:) -> Bool`, `resetForNewSession()`, `stopCapture() -> [Float]`, `waveform(sampleCount:) -> [Float]`, `stats() -> (callbacks: Int, dropped: Int)`, `drainConverterRemainder() -> [Float]`. These tests are GREEN-on-arrival (the exchange is new code — there is no pre-fix version to be RED against; the Task 1 test is the RED that motivated the refactor).

- [ ] **Step 1: Append the unit tests**

```swift
    // MARK: - AudioCaptureExchange unit pins (GREEN-on-arrival; K-10)

    func testPublishAndDrainPreserveOrderAndContent() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        for _ in 0..<3 {
            XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        }
        let drained = exchange.stopCapture()
        // 3 × 1024 frames at 16 kHz (ratio 1:1) → ~3072 output frames.
        XCTAssertEqual(drained.count, 3072, accuracy: 8)
        XCTAssertFalse(drained.allSatisfy { $0 == 0 }, "content must not be silent")
    }

    func testPublishIsNonBlockingWhileConsumerHoldsLock() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        let lockAcquired = expectation(description: "consumer holds the lock")
        let hog = Thread {
            exchange.withExclusiveAccess { _ in
                lockAcquired.fulfill()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        hog.start()
        wait(for: [lockAcquired], timeout: 2)

        let start = CFAbsoluteTimeGetCurrent()
        let accepted = exchange.publish(makeSyntheticBuffer(frames: 1024))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(accepted, "publish must drop while the lock is held")
        XCTAssertLessThan(elapsed, 0.05, "publish must never block (stalled \(Int(elapsed * 1000)) ms)")
        let stats = exchange.stats()
        XCTAssertEqual(stats.dropped, 1)
        XCTAssertEqual(stats.callbacks, 0)
    }

    func testPublishAfterStopIsSkippedNotDropped() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        _ = exchange.stopCapture()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(frames: 1024)), "post-stop publishes are skipped, not dropped")
        XCTAssertEqual(exchange.stats().dropped, 0)
        XCTAssertEqual(exchange.stopCapture().count, 0)
    }

    func testStopCaptureIncludesPublishInFlight() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        let drained = exchange.stopCapture()
        XCTAssertEqual(drained.count, 1024, accuracy: 4)
        // A publish after stop is skipped: nothing more to drain.
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 1024)))
        XCTAssertEqual(exchange.stopCapture().count, 0)
    }

    func testConverterRebuildsWhenSampleRateChanges() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 48_000)))   // 1 s @48 kHz → ~16 k out
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 44_100, frames: 44_100)))   // 1 s @44.1 kHz → ~16 k out
        let drained = exchange.stopCapture()
        // 1 s + 1 s of 16 kHz mono; converter priming allows a small tolerance.
        XCTAssertEqual(drained.count, 32_000, accuracy: 256)
    }

    func testDrainConverterRemainderFlushesTail() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 48_000, frames: 4_800))) // 0.1 s
        _ = exchange.stopCapture()
        let tail = exchange.drainConverterRemainder()
        XCTAssertFalse(tail.isEmpty, "resampler tail must be flushed at stream end")
    }

    func testWaveformReturnsRecentSamples() {
        let exchange = AudioCaptureExchange()
        exchange.resetForNewSession()
        XCTAssertTrue(exchange.publish(makeSyntheticBuffer(sampleRate: 16_000, frames: 4096)))
        let wave = exchange.waveform(sampleCount: 512)
        XCTAssertEqual(wave.count, 512)
        XCTAssertFalse(wave.allSatisfy { $0 == 0 })
    }
```

- [ ] **Step 2: Run the full new test class**

```bash
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AudioCaptureExchangeTests CODE_SIGNING_ALLOWED=NO
```

Expected: 8 tests green (1 RED/GREEN integration + 7 pins). If `testConverterRebuildsWhenSampleRateChanges` is off by more than the tolerance, re-check the converter's output length empirically (log `drained.count` once) and widen `accuracy` with a comment — do not loosen the ordering/no-loss tests.

- [ ] **Step 3: Commit**

```bash
git add app/KalamTests/AudioCaptureExchangeTests.swift
git commit -m "test(K-10): AudioCaptureExchange unit pins — drops, ordering, rebuild, tail"
```

---

## Task 4: Docs sync + full verification + tracker

- [ ] **Step 1: Check for stale queue references in docs**

```bash
rg -n "bufferQueue|AudioBuffer|priority inversion" app/docs/DEVELOPER_GUIDE.md AGENTS.md app/docs/IMPROVEMENT_PLAN.md
```

If `DEVELOPER_GUIDE.md` mentions the serial `bufferQueue`/`DispatchQueue` synchronization in the AudioRecorder section, update the sentence to describe the try-lock exchange (`AudioCaptureExchange`, non-blocking render-thread publish). No other doc change is expected — the public `AudioRecorder` surface is unchanged.

- [ ] **Step 2: Full verification**

```bash
./scripts/test-engine.sh                      # sanity — expect 41 green (engine untouched)
xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: engine 41/41; build green; full Xcode suite green (existing suite untouched — no `AudioRecorder` references in `KalamTests` before this plan; the 8 new tests are additive). Flag any sibling-uncommitted failures per the `kalam-app-development` skill (prove with `git show HEAD:<file>` before attributing).

- [ ] **Step 3: Tracker — flip to `🔄` note update (✅ only after the 🧑 gates)**

`app/docs/IMPROVEMENT_PLAN.md`: K-10 row status is already `🔄` from plan authoring. When the 🧑 gates in the next section pass, flip the row to `✅` and append to the Resolved changelog:

```markdown
- **K-10 (2026-08-11)** — Render-thread publish no longer blocks: `AudioRecorder`'s serial `bufferQueue.sync` replaced by `AudioCaptureExchange` (single `OSAllocatedUnfairLock`, try-lock publish via `withLockIfAvailable`, contention drops counted in the stop log as `dropped=`). Conversion/drain/`secureZero` moved verbatim into the exchange. Verified: Task 1 RED reproduced the multi-ms stall; post-fix stall < 5 ms bound (µs actual); 8 new `AudioCaptureExchangeTests` green; full Xcode suite + engine 41/41 green; 🧑 manual smoke passed (rapid re-record, long dictation, `dropped=0`). Plan: `app/docs/dev-design/2026-08-11-k10-audio-thread-lock.md`.
```

- [ ] **Step 4: Commit**

```bash
git add app/docs/DEVELOPER_GUIDE.md app/docs/IMPROVEMENT_PLAN.md   # only the files you actually changed
git commit -m "docs(K-10): mark implementation executed; automated verification green, manual smoke pending"
```

(If a sibling's uncommitted hunks merge into `IMPROVEMENT_PLAN.md`, commit only the clean new files and leave the tracker edit unstaged, flagging it in your reply — per the shared-mount workflow.)

---

## 🧑 Human verification gates (required before `✅`)

1. **Rapid re-record (the K-10 contention scenario):** hold PTT, release, and immediately re-press while the transcription of the first segment is still running (this is when `stopAndFetchSamples`' critical section runs on the MainActor while the new session's render thread is live). Dictate ~10 words each time, 5–10 repetitions. **Expected:** no clicks, dropouts, or stutter; each transcript complete; Console (`log stream --predicate 'subsystem == "singhkays.Kalam"'`) shows `Stopped collecting ... dropped=0` (occasional `dropped=1` under extreme pressure is acceptable but should be the exception).
2. **Long continuous dictation (~60 s)** with the waveform animating: no waveform stutter, no audio dropout at any point (the ~30 Hz waveform poll previously contended with the render thread; now it cannot stall it).
3. **Stereo device sanity (fidelity regression check):** if the default input is the Logitech C920 (per `prepare()`'s device log), dictate once and confirm transcription quality is unchanged — the conversion path is byte-identical, this is a no-change check.
4. **Normal-operation drop hygiene:** after a day of typical use, spot-check the log for `dropped=` — the value must be `0` in ordinary use; any consistent nonzero count is a new finding (ring-capacity/contention finding, next K-ID).

---

## Out of scope / future work

- **Moving conversion off the render thread** (K-22 candidate if glitches persist): the publish critical section still runs `AVAudioConverter.convert` on the render thread (~tens of µs per 1024-frame buffer — pre-existing, fits the ~21 ms budget, and is *self*-inflicted work, not waiting). The full fix is a bounded lock-free SPSC ring of raw samples with a consumer-side conversion/drain loop. Deliberately not part of K-10 (behavioral surface: downmix fidelity, converter ownership, drain cadence).
- **`prepare()` converter reset locking** is defensive-only (prepare runs with the engine stopped); no behavioral change.
- **Drop hygiene telemetry:** if `dropped=` ever trends nonzero in production, surface a count in the overlay/settings rather than only the log.

## Test commands summary

| Command (from repo root) | Purpose |
|---|---|
| `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing:KalamTests/AudioCaptureExchangeTests CODE_SIGNING_ALLOWED=NO` | New K-10 tests (8) |
| `xcodebuild test -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Full suite |
| `xcodebuild build -project app/Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Build |
| `./scripts/test-engine.sh` | Engine sanity (41) |
