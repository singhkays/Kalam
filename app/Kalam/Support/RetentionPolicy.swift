import Foundation
import OSLog

/// Retention policy for opt-in recordings (Task 6 / K-57).
/// - TTL 7 days; sweep timer every 6 h (Jot precedent).
/// - Purge removes whole session folders atomically.
/// - Injected clock for headless tests.
final class RetentionPolicy {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "RetentionPolicy")

    static let ttlSeconds: TimeInterval = 7 * 24 * 3600 // 7 days
    static let sweepIntervalSeconds: TimeInterval = 6 * 3600 // 6 h

    private let fileManager: FileManager
    private let now: () -> Date
    private var timer: Timer?

    init(fileManager: FileManager = .default, now: @escaping () -> Date = { Date() }) {
        self.fileManager = fileManager
        self.now = now
    }

    /// Starts the 6 h sweep timer (call on MainActor). Does nothing if already running.
    @MainActor
    func startSweeper() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.sweepIntervalSeconds, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        Self.logger.info("Retention sweep timer started interval=\(Self.sweepIntervalSeconds, privacy: .public)s")
    }

    @MainActor
    func stopSweeper() {
        timer?.invalidate()
        timer = nil
    }

    /// Purges session folders older than TTL. Returns URLs removed.
    @discardableResult
    func sweep() -> [URL] {
        let cutoff = now().addingTimeInterval(-Self.ttlSeconds)
        let folders = FileLayout.listSessionFolders()
        var removed: [URL] = []
        for folder in folders {
            guard let attrs = try? fileManager.attributesOfItem(atPath: folder.path),
                  let modDate = attrs[.modificationDate] as? Date ?? attrs[.creationDate] as? Date else {
                // If we can't stat, skip (don't delete)
                continue
            }
            if modDate < cutoff {
                do {
                    try fileManager.removeItem(at: folder)
                    removed.append(folder)
                    Self.logger.info("Retention purge removed folder=\(folder.lastPathComponent, privacy: .public) ageDays=\(Int(self.now().timeIntervalSince(modDate)/86400), privacy: .public)")
                } catch {
                    Self.logger.warning("Retention purge failed folder=\(folder.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !removed.isEmpty {
            Self.logger.info("Retention sweep removed count=\(removed.count, privacy: .public)")
        }
        return removed
    }

    /// For tests: sweep with injected now and custom TTL.
    func sweep(now: Date, ttl: TimeInterval = ttlSeconds) -> [URL] {
        let cutoff = now.addingTimeInterval(-ttl)
        let folders = FileLayout.listSessionFolders()
        var removed: [URL] = []
        for folder in folders {
            guard let attrs = try? fileManager.attributesOfItem(atPath: folder.path),
                  let modDate = attrs[.modificationDate] as? Date ?? attrs[.creationDate] as? Date else { continue }
            if modDate < cutoff {
                do {
                    try fileManager.removeItem(at: folder)
                    removed.append(folder)
                } catch {}
            }
        }
        return removed
    }
}
