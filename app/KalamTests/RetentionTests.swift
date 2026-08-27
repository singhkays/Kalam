import XCTest
@testable import Kalam_test
import Foundation

@MainActor
final class RetentionTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KalamRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        FileLayout.testRootOverride = tempRoot
        UserDefaults.standard.removeObject(forKey: "retention.enabled")
    }

    override func tearDown() {
        FileLayout.testRootOverride = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        UserDefaults.standard.removeObject(forKey: "retention.enabled")
        super.tearDown()
    }

    func testFileLayoutSessionFolderNaming() {
        let id = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let date = ISO8601DateFormatter().date(from: "2026-08-27T23:00:00Z")!
        let folder = FileLayout.sessionFolder(sessionID: id, timestamp: date)
        XCTAssertTrue(folder.path.lowercased().contains("550e8400"), "folder should contain UUID — got \(folder.path)")
        XCTAssertTrue(folder.path.hasPrefix(tempRoot.path), "must use test override — got \(folder.path) vs \(tempRoot.path)")
        XCTAssertEqual(FileLayout.audioURL(for: folder).lastPathComponent, "audio.caf")
        XCTAssertEqual(FileLayout.metaURL(for: folder).lastPathComponent, "meta.json")
    }

    func testCAFStreamWriterStreamingHeader() throws {
        let folder = tempRoot.appendingPathComponent("sess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("audio.caf")
        let writer = try CAFStreamWriter(url: url, sampleRate: 16_000, channels: 1)
        // Append incrementally, never rewrite header per tick
        try writer.append([0.1, 0.2, 0.3])
        try writer.append([0.4, 0.5])
        try writer.close()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as! UInt64
        XCTAssertGreaterThan(size, 64, "CAF header + data should exist")
        // File should be readable even without final header rewrite (streaming)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: "caff".data(using: .ascii)!), "must start with caff")
    }

    func testRetentionToggleOffDoesZeroWrites() {
        UserDefaults.standard.set(false, forKey: "retention.enabled")
        let recorder = AudioRecorder()
        let folder = recorder.beginRetentionIfEnabled(sessionID: UUID())
        XCTAssertNil(folder, "when OFF, beginRetention must return nil")
        // No folder should have been created under recordingsRoot
        let contents = (try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(contents.isEmpty, "OFF path must create zero files — found \(contents)")
        recorder.endRetention(markComplete: true) // no-op
    }

    func testRetentionToggleOnCreatesFolderAndMeta() throws {
        UserDefaults.standard.set(true, forKey: "retention.enabled")
        let recorder = AudioRecorder()
        let id = UUID()
        let folder = recorder.beginRetentionIfEnabled(sessionID: id, deviceUID: "test-uid")
        XCTAssertNotNil(folder, "when ON, folder should be created")
        XCTAssertNotNil(recorder.retentionFolderForTesting)
        // Meta should exist with isComplete false
        let metaURL = FileLayout.metaURL(for: folder!)
        let data = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(SessionMeta.self, from: data)
        XCTAssertEqual(meta.sessionID, id)
        XCTAssertEqual(meta.isComplete, false)
        XCTAssertEqual(meta.deviceUID, "test-uid")
        // Write some samples via the sink (simulate audio)
        // We do this by directly appending via the writer (the sink is via AudioCaptureExchange, hard to trigger here)
        // Instead, verify that the writer exists and can be closed
        recorder.endRetention(markComplete: true)
        let data2 = try Data(contentsOf: metaURL)
        let meta2 = try JSONDecoder().decode(SessionMeta.self, from: data2)
        XCTAssertEqual(meta2.isComplete, true, "endRetention markComplete must flip isComplete")
        // Writer closed, no leak
        XCTAssertNil(recorder.retentionFolderForTesting)
    }

    func testRetentionPolicySweepRemovesOldFolders() throws {
        UserDefaults.standard.set(true, forKey: "retention.enabled")
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Create 3 folders with different ages
        let oldID = UUID()
        let oldDate = now.addingTimeInterval(-8 * 86400) // 8 days ago → should be purged (TTL 7)
        let recentID = UUID()
        let recentDate = now.addingTimeInterval(-1 * 86400) // 1 day ago → keep
        let borderID = UUID()
        let borderDate = now.addingTimeInterval(-7 * 86400 + 3600) // 6d23h → keep

        for (id, date) in [(oldID, oldDate), (recentID, recentDate), (borderID, borderDate)] {
            let folder = FileLayout.sessionFolder(sessionID: id, timestamp: date)
            try FileLayout.ensureSessionFolder(folder)
            // Set modification date to simulate age
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
            // Also need a file inside so folder is not empty
            try Data().write(to: folder.appendingPathComponent("audio.caf"))
            let meta = SessionMeta(sessionID: id, deviceUID: nil, deviceName: nil, sampleRate: 16_000, timestamp: date, segmentEstimateMs: nil, isComplete: true)
            try JSONEncoder().encode(meta).write(to: FileLayout.metaURL(for: folder))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
        }

        let policy = RetentionPolicy(now: { now })
        let removed = policy.sweep(now: now, ttl: RetentionPolicy.ttlSeconds)
        XCTAssertEqual(removed.count, 1, "only the 8-day folder should be purged")
        XCTAssertTrue(removed.first?.lastPathComponent.contains(oldID.uuidString) == true)
        let remaining = FileLayout.listSessionFolders()
        XCTAssertEqual(remaining.count, 2)
    }

    func testRecoveryScannerNewestFirstOrdering() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let ids = (0..<5).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            let date = now.addingTimeInterval(TimeInterval(i * 3600)) // each hour newer
            let folder = FileLayout.sessionFolder(sessionID: id, timestamp: date)
            try FileLayout.ensureSessionFolder(folder)
            let meta = SessionMeta(sessionID: id, deviceUID: nil, deviceName: nil, sampleRate: 16_000, timestamp: date, segmentEstimateMs: 1000, isComplete: i % 2 == 0)
            try JSONEncoder().encode(meta).write(to: FileLayout.metaURL(for: folder))
            try Data([0, 1, 2]).write(to: FileLayout.audioURL(for: folder))
        }
        let sessions = RecoveryScanner.reindex()
        XCTAssertEqual(sessions.count, 5)
        // Newest first by timestamp
        for i in 0..<sessions.count-1 {
            XCTAssertGreaterThanOrEqual(sessions[i].meta.timestamp, sessions[i+1].meta.timestamp)
        }
        let newestInterrupted = RecoveryScanner.newestInterrupted()
        XCTAssertNotNil(newestInterrupted)
        XCTAssertEqual(newestInterrupted?.meta.isComplete, false)
        // The newest interrupted should be the newest session where isComplete false
        let expectedNewestFalse = sessions.first(where: { !$0.meta.isComplete })
        XCTAssertEqual(newestInterrupted?.meta.sessionID, expectedNewestFalse?.meta.sessionID)
    }

    func testEstimatedDuration() throws {
        let folder = tempRoot.appendingPathComponent("dur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("audio.caf")
        // Write 1 second of Float32 mono 16kHz via CAFStreamWriter
        let writer = try CAFStreamWriter(url: url, sampleRate: 16_000, channels: 1)
        let oneSec = [Float](repeating: 0.1, count: 16_000)
        try writer.append(oneSec)
        try writer.close()
        let dur = FileLayout.estimatedDuration(ofCAF: url, sampleRate: 16_000)
        XCTAssertNotNil(dur)
        XCTAssertEqual(dur!, 1.0, accuracy: 0.05)
    }
}
