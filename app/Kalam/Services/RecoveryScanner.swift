import Foundation
import OSLog

/// Recovery scanner for opt-in retention (Task 6 / K-57).
/// - Reindexes `~/Library/Application Support/Kalam/recordings/` on launch.
/// - Folders are newest-first (ISO8601 prefix).
/// - `meta.json` is decoded to `SessionMeta`; `audio.caf` is streamed.
/// - Newest interrupted session is auto-transcribed ON-DEVICE; older are surfaced as recovered rows.
/// - No network, no GRDB; folders stay source of truth.

struct SessionMeta: Codable, Equatable {
    var sessionID: UUID
    var deviceUID: String?
    var deviceName: String?
    var sampleRate: Double
    var timestamp: Date
    var segmentEstimateMs: Int?
    var isComplete: Bool // false = interrupted (crash/power loss)

    static func make(sessionID: UUID, deviceUID: String?, sampleRate: Double, timestamp: Date, segmentEstimateMs: Int?) -> SessionMeta {
        SessionMeta(sessionID: sessionID, deviceUID: deviceUID, deviceName: nil, sampleRate: sampleRate, timestamp: timestamp, segmentEstimateMs: segmentEstimateMs, isComplete: false)
    }
}

enum RecoveryScanner {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "RecoveryScanner")

    struct RecoveredSession: Equatable {
        var folder: URL
        var meta: SessionMeta
        var audioURL: URL
        var estimatedDuration: TimeInterval?
    }

    /// Reindexes all session folders, returning newest-first.
    static func reindex() -> [RecoveredSession] {
        let folders = FileLayout.listSessionFolders()
        var sessions: [RecoveredSession] = []
        for folder in folders {
            let metaURL = FileLayout.metaURL(for: folder)
            let audioURL = FileLayout.audioURL(for: folder)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(SessionMeta.self, from: data) else {
                // No meta? Create a minimal one from folder name if possible
                continue
            }
            let duration = FileLayout.estimatedDuration(ofCAF: audioURL, sampleRate: meta.sampleRate)
            sessions.append(RecoveredSession(folder: folder, meta: meta, audioURL: audioURL, estimatedDuration: duration))
        }
        // FileLayout already sorts newest-first by name, but also sort by meta.timestamp as secondary
        return sessions.sorted(by: { $0.meta.timestamp > $1.meta.timestamp })
    }

    /// Returns the newest interrupted session (isComplete == false) if any.
    static func newestInterrupted() -> RecoveredSession? {
        reindex().first(where: { !$0.meta.isComplete })
    }

    /// Marks a session as complete (e.g. after successful auto-transcription).
    static func markComplete(folder: URL) {
        let metaURL = FileLayout.metaURL(for: folder)
        guard var meta = try? Data(contentsOf: metaURL).flatMap({ try? JSONDecoder().decode(SessionMeta.self, from: $0) }) as SessionMeta? else { return }
        // Need to decode properly
        if let data = try? Data(contentsOf: metaURL),
           var m = try? JSONDecoder().decode(SessionMeta.self, from: data) {
            m.isComplete = true
            if let out = try? JSONEncoder().encode(m) {
                try? out.write(to: metaURL)
                logger.info("RecoveryScanner marked complete folder=\(folder.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// For tests: creates a dummy session folder with meta + empty CAF.
    static func createTestSession(sessionID: UUID = UUID(), timestamp: Date = Date(), isComplete: Bool = false) throws -> URL {
        let folder = FileLayout.sessionFolder(sessionID: sessionID, timestamp: timestamp)
        try FileLayout.ensureSessionFolder(folder)
        let meta = SessionMeta(sessionID: sessionID, deviceUID: "test-uid", deviceName: "Test Mic", sampleRate: 16_000, timestamp: timestamp, segmentEstimateMs: 1000, isComplete: isComplete)
        let data = try JSONEncoder().encode(meta)
        try data.write(to: FileLayout.metaURL(for: folder))
        // Create empty CAF
        let audioURL = FileLayout.audioURL(for: folder)
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())
        return folder
    }
}

private extension Data {
    func flatMap<T>(_ transform: (Data) throws -> T?) rethrows -> T? {
        try transform(self)
    }
}
