import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Backup
    //
    // `library.db` is not just a cache any more. Listening history, feedback,
    // favorites, bookmarks, saved playlists, radio configs, labels and the
    // editorial cache all live here, and **none of the first six can be rebuilt
    // from Roon** — a resync restores the track list and nothing else. There was
    // no backup mechanism at all; the only copies on disk were `.bak` files
    // someone made by hand.
    //
    // `VACUUM INTO` is the right tool: it produces a consistent, already-compacted
    // copy from a live WAL database without blocking writers for the duration, and
    // without the "did the -wal file come along?" trap of copying the file.

    /// Where backups live, next to the database itself.
    public static func backupDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    /// Timestamped backup filename. Sorts chronologically as a string, which is
    /// what `prunableBackups` relies on.
    static func backupFilename(at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return "library-\(f.string(from: date)).db"
    }

    /// Write a consistent copy to `url`. The destination must not exist —
    /// `VACUUM INTO` refuses to overwrite, which is a feature: a backup that
    /// silently clobbers a good one is worse than no backup.
    public func backup(to url: URL) async throws {
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    /// Which backups to delete, keeping the `keep` newest. Pure so the retention
    /// rule is testable without touching a disk — the half that has historically
    /// gone wrong is "which ones", not "how to unlink".
    public static func prunableBackups(_ filenames: [String], keep: Int) -> [String] {
        let ours = filenames.filter { $0.hasPrefix("library-") && $0.hasSuffix(".db") }
        guard ours.count > keep, keep >= 0 else { return [] }
        // Newest first: the timestamp format sorts lexicographically.
        let sorted = ours.sorted(by: >)
        return Array(sorted.dropFirst(keep)).sorted()
    }

    /// Run one backup and enforce retention. Returns the file written.
    @discardableResult
    public func runBackup(databaseURL: URL, keep: Int = 7, now: Date = Date()) async throws -> URL {
        let dir = Self.backupDirectory(for: databaseURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(Self.backupFilename(at: now))
        // A second run inside the same second would hit the no-overwrite rule.
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try await backup(to: target)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in Self.prunableBackups(existing, keep: keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return target
    }

    // MARK: - Housekeeping
    //
    // Deliberately narrow. `editorial_cache` is refetchable and has an explicit
    // TTL, and old recommendation batches are historical feed entries. What is
    // NOT touched: `discovery_rejections` (those are the user's own "no" — pruning
    // them would resurface rejected albums), `track_feedback`, `favorites`,
    // `bookmarks`, `listening_history`, `playlists`. Losing any of those is
    // unrecoverable, and no amount of disk saving is worth it.

    public struct HousekeepingReport: Sendable, Equatable {
        public var expiredEditorial = 0
        public var oldBatches = 0
        public var oldBatchItems = 0
    }

    /// Prune expired caches and stale batches, then compact.
    /// - Parameters:
    ///   - editorialTTLDays: matches the 30-day TTL the editorial fetchers use.
    ///   - batchRetentionDays: how long a recommendation batch stays readable.
    @discardableResult
    public func runHousekeeping(editorialTTLDays: Int = 30,
                                batchRetentionDays: Int = 180,
                                now: Date = Date()) async throws -> HousekeepingReport {
        let editorialCutoff = Self.isoFormatter.string(
            from: now.addingTimeInterval(-Double(editorialTTLDays) * 86_400))
        let batchCutoff = Self.isoFormatter.string(
            from: now.addingTimeInterval(-Double(batchRetentionDays) * 86_400))

        // The counts are RETURNED from the write block, not accumulated into a
        // captured `var`: mutating a captured variable inside the @Sendable
        // closure compiles on some toolchains and is a hard error on others (it
        // broke CI on macos-14 while passing locally on Swift 6.3).
        let counts = try await pool.write { db -> (editorial: Int, items: Int, batches: Int) in
            try db.execute(sql: "DELETE FROM editorial_cache WHERE fetched_at < ?",
                           arguments: [editorialCutoff])
            let editorial = db.changesCount

            // Items first: they reference the batch.
            try db.execute(sql: """
                DELETE FROM recommendation_items
                 WHERE batch_id IN (SELECT id FROM recommendation_batches WHERE created_at < ?)
                """, arguments: [batchCutoff])
            let items = db.changesCount

            try db.execute(sql: "DELETE FROM recommendation_batches WHERE created_at < ?",
                           arguments: [batchCutoff])
            return (editorial, items, db.changesCount)
        }
        var report = HousekeepingReport()
        report.expiredEditorial = counts.editorial
        report.oldBatchItems = counts.items
        report.oldBatches = counts.batches
        // VACUUM cannot run inside a transaction, hence its own write.
        try await pool.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        return report
    }

    /// Whether the most recent discovery batch ran degraded (schema v45). nil when
    /// no batch has run. Read by the health check.
    public func lastBatchDegraded() async throws -> Bool? {
        try await pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT degraded FROM recommendation_batches ORDER BY created_at DESC LIMIT 1
                """)
        }
    }

    /// Rows in `track_audio_features` — the numerator of the coverage check.
    public func audioFeatureCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0
        }
    }
}
