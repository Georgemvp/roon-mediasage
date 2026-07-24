import Foundation
import GRDB

extension DatabaseManager {

    public struct LabelRow: Sendable, Identifiable, Hashable {
        public let id: Int64
        public let name: String
        public let logoURL: String?
        public let albumCount: Int
    }

    // MARK: - Backfill from the dataset-imported label column

    /// (Re)seed the label / album_label tables from `track_audio_features.label`
    /// (populated by the offline dataset import). Idempotent: replaces the
    /// `source='dataset'` rows only, leaves label ids stable (so merges survive)
    /// and re-routes each album through any recorded merge. Returns the number of
    /// album→label links written.
    @discardableResult
    public func rebuildLabelsFromFeatures() async -> Int {
        (try? await pool.write { db -> Int in
            // album_key → most-common non-empty label across its tracks.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.album_key AS ak, f.label AS label
                FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE f.label IS NOT NULL AND TRIM(f.label) <> '' AND t.album_key IS NOT NULL
                """)
            var tally: [String: [String: Int]] = [:]   // albumKey → labelName → count
            for row in rows {
                guard let ak = row["ak"] as String?, let label = (row["label"] as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
                tally[ak, default: [:]][label, default: 0] += 1
            }
            let mergeMap = try Self.mergeRedirects(db)

            try db.execute(sql: "DELETE FROM album_label WHERE source = 'dataset'")
            var written = 0
            for (albumKey, labels) in tally {
                guard let name = labels.max(by: { $0.value < $1.value })?.key else { continue }
                let rawID = try Self.findOrCreateLabel(name: name, db: db)
                let labelID = Self.resolveMerge(rawID, map: mergeMap)
                try db.execute(sql: """
                    INSERT OR IGNORE INTO album_label(album_key, label_id, source) VALUES (?,?, 'dataset')
                    """, arguments: [albumKey, labelID])
                written += 1
            }
            return written
        }) ?? 0
    }

    private static func findOrCreateLabel(name: String, db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM label WHERE LOWER(canonical_name) = LOWER(?)",
                                       arguments: [name]) {
            return id
        }
        try db.execute(sql: "INSERT INTO label(canonical_name) VALUES (?)", arguments: [name])
        return db.lastInsertedRowID
    }

    /// from_label_id → into_label_id for every recorded merge.
    private static func mergeRedirects(_ db: Database) throws -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT from_label_id, into_label_id FROM label_merge") {
            if let f = row["from_label_id"] as Int64?, let t = row["into_label_id"] as Int64? { map[f] = t }
        }
        return map
    }

    /// Follow a chain of merges to the surviving label (guarded against cycles).
    private static func resolveMerge(_ id: Int64, map: [Int64: Int64]) -> Int64 {
        var current = id
        var hops = 0
        while let next = map[current], hops < 32 { current = next; hops += 1 }
        return current
    }

    // MARK: - Queries

    public func labelList(sortedBy sort: LabelSort) async -> [LabelRow] {
        let order = sort == .name ? "l.canonical_name COLLATE NOCASE ASC" : "cnt DESC, l.canonical_name COLLATE NOCASE"
        return (try? await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.id, l.canonical_name AS name, l.logo_url AS logo, COUNT(al.album_key) AS cnt
                FROM label l JOIN album_label al ON al.label_id = l.id
                GROUP BY l.id
                ORDER BY \(order)
                """).map {
                    LabelRow(id: $0["id"], name: $0["name"] as String? ?? "",
                             logoURL: $0["logo"], albumCount: $0["cnt"] as Int? ?? 0)
                }
        }) ?? []
    }

    public func albumsForLabel(_ labelID: Int64) async -> [AlbumResult] {
        (try? await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.album_key, t.album, t.artist, t.year,
                       COUNT(*) AS track_count, MAX(t.image_key) AS image_key
                FROM album_label al JOIN tracks t ON t.album_key = al.album_key
                WHERE al.label_id = ?
                GROUP BY t.album_key
                ORDER BY (t.year IS NULL), t.year DESC, t.album COLLATE NOCASE
                """, arguments: [labelID]).map {
                    AlbumResult(albumKey: $0["album_key"] as String? ?? "",
                                album: $0["album"] as String? ?? "", artist: $0["artist"],
                                year: $0["year"], trackCount: $0["track_count"] as Int? ?? 0,
                                imageKey: $0["image_key"])
                }
        }) ?? []
    }

    // MARK: - Merge / undo (exact restore)

    public func mergeLabels(from: Int64, into: Int64) async {
        guard from != into else { return }
        try? await pool.write { db in
            let fromKeys = try String.fetchAll(db, sql: "SELECT album_key FROM album_label WHERE label_id = ?", arguments: [from])
            let intoKeys = Set(try String.fetchAll(db, sql: "SELECT album_key FROM album_label WHERE label_id = ?", arguments: [into]))
            let addedKeys = fromKeys.filter { !intoKeys.contains($0) }
            // Reassign from → into (keeping into's existing rows), then drop from's.
            try db.execute(sql: """
                INSERT OR IGNORE INTO album_label(album_key, label_id, source)
                SELECT album_key, ?, source FROM album_label WHERE label_id = ?
                """, arguments: [into, from])
            try db.execute(sql: "DELETE FROM album_label WHERE label_id = ?", arguments: [from])
            let now = Self.isoFormatter.string(from: Date())
            try db.execute(sql: """
                INSERT INTO label_merge(from_label_id, into_label_id, merged_at, restored_keys, added_keys)
                VALUES (?,?,?,?,?)
                """, arguments: [from, into, now, Self.encodeKeys(fromKeys), Self.encodeKeys(addedKeys)])
        }
    }

    public func undoLabelMerge(from: Int64) async {
        try? await pool.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT into_label_id, restored_keys, added_keys FROM label_merge
                WHERE from_label_id = ? ORDER BY merged_at DESC LIMIT 1
                """, arguments: [from]) else { return }
            let into = (row["into_label_id"] as Int64?) ?? 0
            for key in Self.decodeKeys(row["restored_keys"]) {
                try db.execute(sql: "INSERT OR IGNORE INTO album_label(album_key, label_id, source) VALUES (?,?, 'dataset')",
                               arguments: [key, from])
            }
            for key in Self.decodeKeys(row["added_keys"]) {
                try db.execute(sql: "DELETE FROM album_label WHERE album_key = ? AND label_id = ?", arguments: [key, into])
            }
            try db.execute(sql: "DELETE FROM label_merge WHERE from_label_id = ? AND into_label_id = ?", arguments: [from, into])
        }
    }

    public func hasMerge(from: Int64) async -> Bool {
        let count = (try? await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM label_merge WHERE from_label_id = ?", arguments: [from]) ?? 0
        }) ?? 0
        return count > 0
    }

    private static func encodeKeys(_ keys: [String]) -> String {
        guard let data = try? JSONEncoder().encode(keys), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decodeKeys(_ value: DatabaseValueConvertible?) -> [String] {
        guard let s = value as? String, let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
