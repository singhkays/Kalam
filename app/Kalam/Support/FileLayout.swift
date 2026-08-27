import Foundation

/// File layout for opt-in retention (Task 6 / K-57).
/// - Base root: `~/Library/Application Support/Kalam/recordings/`
/// - Per-session folder: `<ISO8601>-<uuid>/`  (e.g. `2026-08-27T23-00-00Z-550e8400-.../`)
/// - Inside: `audio.caf` + `meta.json`
/// Folders are the source of truth; GRDB deferred.
enum FileLayout {
    /// Test override for recordings root (injected by unit tests to avoid touching real Application Support).
    nonisolated(unsafe) static var testRootOverride: URL?

    /// Base URL for recordings. Created on demand.
    static var recordingsRoot: URL {
        if let override = testRootOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Kalam/recordings", isDirectory: true)
    }

    /// Per-session folder URL for the given session ID and timestamp.
    static func sessionFolder(sessionID: UUID, timestamp: Date = Date()) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Use colons replaced for filesystem safety (macOS allows colons but they are path separator in HFS)
        let iso = formatter.string(from: timestamp).replacingOccurrences(of: ":", with: "-")
        return recordingsRoot.appendingPathComponent("\(iso)-\(sessionID.uuidString)", isDirectory: true)
    }

    static func audioURL(for sessionFolder: URL) -> URL {
        sessionFolder.appendingPathComponent("audio.caf", isDirectory: false)
    }

    static func metaURL(for sessionFolder: URL) -> URL {
        sessionFolder.appendingPathComponent("meta.json", isDirectory: false)
    }

    /// Creates the session folder (including root) if needed.
    @discardableResult
    static func ensureSessionFolder(_ folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Estimated duration helper analogous to Jot's `estimatedDuration(ofCAF:)`.
    /// Reads CAF header if present, else estimates from file size (Float32 mono 16kHz).
    /// Returns nil if file missing or unreadable.
    static func estimatedDuration(ofCAF url: URL, sampleRate: Double = 16_000) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return nil }
        // Rough estimate: header ~ 64 bytes, data is Float32 (4 bytes) mono
        let headerEstimate: UInt64 = 64
        guard size > headerEstimate else { return 0 }
        let dataBytes = size - headerEstimate
        let sampleCount = Double(dataBytes) / Double(MemoryLayout<Float>.size)
        return sampleCount / sampleRate
    }

    /// Lists all session folders sorted newest-first by name (ISO8601 prefix sorts chronologically).
    static func listSessionFolders() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
    }
}
