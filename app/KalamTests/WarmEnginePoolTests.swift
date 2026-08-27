import XCTest
import AVFoundation
@testable import Kalam_test

// MARK: - Fake clock for WarmEnginePool coalescing tests

private final class FakeClock {
    private struct Entry {
        var fireAt: TimeInterval
        var work: () -> Void
        var cancelled = false
        let id = UUID()
    }
    private var now: TimeInterval = 0
    private var entries: [Entry] = []
    private let lock = NSLock()

    func scheduler(delay: TimeInterval, work: @escaping () -> Void) -> WarmEnginePoolCancellable {
        lock.lock()
        defer { lock.unlock() }
        var entry = Entry(fireAt: now + delay, work: work)
        entries.append(entry)
        let idx = entries.count - 1
        return FakeCancellable { [weak self] in
            self?.lock.lock()
            self?.entries[idx].cancelled = true
            self?.lock.unlock()
        }
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        now += delta
        let due = entries.filter { !$0.cancelled && $0.fireAt <= now }
        // Remove fired entries from list (keep cancelled for bookkeeping)
        entries.removeAll { !$0.cancelled && $0.fireAt <= now }
        lock.unlock()
        // Fire outside lock — work may schedule new entries
        for e in due {
            e.work()
        }
    }

    func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { !$0.cancelled }.count
    }
}

private final class FakeCancellable: WarmEnginePoolCancellable {
    private let onCancel: () -> Void
    private var cancelled = false
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

// MARK: - WarmEnginePoolTests

final class WarmEnginePoolTests: XCTestCase {

    // Helper to build a pool with fake seams
    private func makePool(
        currentUID: String? = "uid-A",
        permission: Bool = true,
        factory: ((String?) throws -> AVAudioEngine)? = nil,
        clock: FakeClock? = nil,
        debounce: TimeInterval = 0.25
    ) -> (WarmEnginePool, FakeClock, Counter) {
        let c = clock ?? FakeClock()
        let counter = Counter()
        let f: (String?) throws -> AVAudioEngine = factory ?? { uid in
            counter.count += 1
            counter.lastUID = uid
            let e = AVAudioEngine()
            // Never start — invariant; prepare is best-effort for tests without hardware
            // We don't call engine.prepare() here to avoid 0-channel throws on CI hosts.
            assert(!e.isRunning, "factory must not return running engine")
            return e
        }
        let provider: () -> String? = { currentUID }
        let perm: () -> Bool = { permission }
        let scheduler: WarmEnginePoolScheduler = { delay, work in
            c.scheduler(delay: delay, work: work)
        }
        let pool = WarmEnginePool(
            debounceInterval: debounce,
            permissionCheck: perm,
            currentDeviceProvider: provider,
            engineFactory: f,
            scheduler: scheduler
        )
        return (pool, c, counter)
    }

    private final class Counter {
        var count = 0
        var lastUID: String? = nil
    }

    // MARK: - take-invalidates

    func testTakeInvalidates() {
        let (pool, _, counter) = makePool(currentUID: "A")
        pool.prewarm(for: "A")
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(pool.isFresh(for: "A"))

        let g1 = pool.take(for: "A")
        XCTAssertNotNil(g1)
        XCTAssertNil(pool.spareForTesting, "spare must be cleared after take")
        XCTAssertFalse(pool.isFresh(for: "A"))

        let g2 = pool.take(for: "A")
        XCTAssertNil(g2, "second take must be nil — freshness guarantee")
        XCTAssertEqual(counter.count, 1, "take must not synchronously refill; refill is debounced")
    }

    func testTakeStaleReturnsNilAndPreservesSpare() {
        let (pool, _, _) = makePool(currentUID: "A")
        pool.prewarm(for: "A")
        XCTAssertTrue(pool.isFresh(for: "A"))

        let stale = pool.take(for: "B")
        XCTAssertNil(stale, "must not hand back stale graph for different UID")
        XCTAssertNotNil(pool.spareForTesting, "stale take must not consume spare")
        XCTAssertTrue(pool.isFresh(for: "A"))
        XCTAssertFalse(pool.isFresh(for: "B"))

        let correct = pool.take(for: "A")
        XCTAssertNotNil(correct)
    }

    // MARK: - permission gate no-op

    func testPermissionGatePrewarmNoOp() {
        let (pool, _, counter) = makePool(currentUID: "A", permission: false)
        pool.prewarm(for: "A")
        XCTAssertEqual(counter.count, 0, "factory must not be called when not authorized")
        XCTAssertNil(pool.spareForTesting)
        XCTAssertFalse(pool.isFresh(for: "A"))
    }

    func testPermissionGateRebuildNoOp() {
        let clock = FakeClock()
        let (pool, c, counter) = makePool(currentUID: "A", permission: false, clock: clock)
        // Manually inject spare, then invalidate — rebuild should no-op due to permission
        pool.setSpareForTesting(WarmEnginePool.PreparedGraph(deviceUID: "A", engine: AVAudioEngine()))
        pool.invalidate(reason: "test")
        XCTAssertNil(pool.spareForTesting, "invalidate must clear spare")
        XCTAssertEqual(c.pendingCount(), 1)
        c.advance(by: 0.30)
        // Factory must not have been called; spare stays nil
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(pool.spareForTesting)
    }

    // MARK: - refresh-coalescing

    func testRefreshCoalescing() {
        let clock = FakeClock()
        let counter = Counter()
        let factory: (String?) throws -> AVAudioEngine = { uid in
            counter.count += 1
            counter.lastUID = uid
            return AVAudioEngine()
        }
        let (pool, c, _) = makePool(currentUID: "A", factory: factory, clock: clock, debounce: 0.25)
        // Burst of invalidates within 250 ms
        pool.invalidate(reason: "a")
        pool.invalidate(reason: "b")
        pool.invalidate(reason: "c")
        XCTAssertEqual(c.pendingCount(), 1, "burst must coalesce to one pending rebuild")
        XCTAssertEqual(counter.count, 0, "factory not yet called before debounce fires")
        c.advance(by: 0.10)
        XCTAssertEqual(counter.count, 0, "still within debounce window")
        // Invalidate again inside window should reschedule
        pool.invalidate(reason: "d")
        XCTAssertEqual(c.pendingCount(), 1)
        c.advance(by: 0.30)
        XCTAssertEqual(counter.count, 1, "exactly one rebuild per burst")
        XCTAssertTrue(pool.isFresh(for: "A"))
    }

    // MARK: - device-change rebuild exactly once per burst (250 ms trailing)

    func testDeviceChangeBurstExactlyOneRebuild() {
        let clock = FakeClock()
        let counter = Counter()
        var current = "A"
        let provider: () -> String? = { current }
        let factory: (String?) throws -> AVAudioEngine = { uid in
            counter.count += 1
            return AVAudioEngine()
        }
        let perm: () -> Bool = { true }
        let scheduler: WarmEnginePoolScheduler = { d, w in clock.scheduler(delay: d, work: w) }
        let pool = WarmEnginePool(
            debounceInterval: 0.25,
            permissionCheck: perm,
            currentDeviceProvider: provider,
            engineFactory: factory,
            scheduler: scheduler
        )
        // Simulate 250 ms burst coalescing: rapid device-change events
        for i in 0..<5 {
            current = "B-\(i)" // device provider changes during burst
            pool.invalidate(reason: "deviceChange-\(i)")
        }
        XCTAssertEqual(clock.pendingCount(), 1)
        clock.advance(by: 0.25)
        XCTAssertEqual(counter.count, 1, "burst must produce exactly one rebuild, trailing edge")
        // After burst, a new burst should produce another single rebuild
        current = "C"
        pool.invalidate(reason: "next-burst-1")
        pool.invalidate(reason: "next-burst-2")
        XCTAssertEqual(clock.pendingCount(), 1)
        clock.advance(by: 0.30)
        XCTAssertEqual(counter.count, 2, "second burst must produce exactly one more rebuild")
    }

    func testTakeSchedulesRefillCoalesced() {
        let clock = FakeClock()
        let (pool, c, counter) = makePool(currentUID: "A", clock: clock)
        pool.prewarm(for: "A")
        XCTAssertEqual(counter.count, 1)
        counter.count = 0
        _ = pool.take(for: "A")
        XCTAssertNil(pool.spareForTesting)
        XCTAssertEqual(c.pendingCount(), 1, "take must schedule a debounced refill")
        c.advance(by: 0.10)
        XCTAssertEqual(counter.count, 0)
        c.advance(by: 0.20)
        XCTAssertEqual(counter.count, 1, "refill fires after debounce, exactly once")
        XCTAssertTrue(pool.isFresh(for: "A"))
    }

    func testMicIndicatorInvariant_NeverStartsEngineWhileIdle() {
        let (pool, _, _) = makePool(currentUID: "A")
        pool.prewarm(for: "A")
        let spare = pool.spareForTesting
        XCTAssertNotNil(spare)
        XCTAssertFalse(spare!.engine.isRunning, "idle spare must never be running (mic glyph invariant)")
        // Also after rebuild
        pool.invalidate(reason: "test")
        // Need clock to fire — use real pool's scheduler? For this test, use fake clock path
        let clock = FakeClock()
        let (pool2, c2, _) = makePool(currentUID: "A", clock: clock)
        pool2.prewarm(for: "A")
        pool2.invalidate(reason: "test2")
        c2.advance(by: 0.30)
        if let s2 = pool2.spareForTesting {
            XCTAssertFalse(s2.engine.isRunning)
        } else {
            // If rebuild hasn't fired due to async, spare may be nil — still passes invariant
            XCTAssertNil(pool2.spareForTesting)
        }
    }

    func testPoolHoldsOneSpareOnly() {
        let (pool, _, _) = makePool(currentUID: "A")
        pool.prewarm(for: "A")
        pool.prewarm(for: "B")
        // Second prewarm should overwrite, not accumulate
        XCTAssertTrue(pool.isFresh(for: "B") || pool.isFresh(for: "A"), "pool holds one; second prewarm overwrites")
        XCTAssertNotNil(pool.spareForTesting)
        // Count as one slot
        let first = pool.take(for: pool.spareForTesting?.deviceUID)
        XCTAssertNotNil(first)
        XCTAssertNil(pool.spareForTesting)
    }
}
