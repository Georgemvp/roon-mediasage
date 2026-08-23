import AudioAnalysis
import Foundation
import GRDB

/// The library's third source: Plex.
///
/// Structured exactly like `DatabaseManager+LocalLibrary` (same prefix/source
/// scoping, same prune brake, same Roon displacement) — read that one first; the
/// differences are what matter here:
///
/// 1. **The id is Plex's, not ours.** `plex::<ratingKey>` needs no album
///    fingerprint: Plex already hands out a stable per-track id that survives
///    rescans. The `local::` id has to carry the album because `match_key` is
///    album-free and would collapse the same recording on two albums onto one
///    row; a ratingKey has no such problem.
/// 2. **The row knows its file.** Plex reports the absolute path, so these rows
///    populate `tracks.file_path` and join to `track_features.file_path`
///    exactly, instead of through the fuzzy `match_key` bridge.
/// 3. **Album grouping is a real key.** `parentRatingKey`, not an
///    `album|artist` string.
///
/// Measured against the real installs on 2026-08-23: 58.308 of Plex's 65.738
/// tracks join exactly to an analysed file; Plex additionally has 7.430 files the
/// analyser never walked, while 8.038 analyser rows point at files that no
/// longer exist. Plex is the more accurate picture of the disk.
extension DatabaseManager {

    /// Id prefix for a Plex-sourced library row.
    public static let plexKeyPrefix = "plex::"

    /// `tracks.source` value for a Plex row. The Roon walk scopes its deletes to
    /// `source = 'roon'` and the analyser ingest to `source = 'local'`, so these
    /// survive both.
    public static let plexSource = "plex"

    /// One Plex track offered to the library.
    public struct PlexTrackRow: Sendable, Equatable {
        public var ratingKey: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var albumRatingKey: String?
        public var year: Int?
        /// Absolute path on the server's disk, NFC-normalised.
        public var filePath: String?
        /// Plex-relative artwork path.
        public var thumb: String?

        public init(ratingKey: String, title: String, artist: String?, album: String?,
                    albumRatingKey: String?, year: Int?, filePath: String?, thumb: String?) {
            self.ratingKey = ratingKey
            self.title = title
            self.artist = artist
            self.album = album
            self.albumRatingKey = albumRatingKey
            self.year = year
            self.filePath = filePath
            self.thumb = thumb
        }
    }

    public struct PlexIngestResult: Sendable, Equatable {
        public var offered: Int
        public var inserted: Int
        public var refreshed: Int
        /// Roon rows displaced because Plex now owns that recording.
        public var reclaimed: Int
        /// Plex rows dropped because Plex no longer offers that ratingKey.
        public var pruned: Int
        public var total: Int

        public init(offered: Int, inserted: Int, refreshed: Int, reclaimed: Int,
                    pruned: Int = 0, total: Int) {
            self.offered = offered; self.inserted = inserted; self.refreshed = refreshed
            self.reclaimed = reclaimed; self.pruned = pruned; self.total = total
        }
    }

    /// Stable library id for a Plex row.
    public static func plexTrackID(ratingKey: String) -> String {
        plexKeyPrefix + ratingKey
    }

    /// Artwork key for a Plex row: `plex::<ratingKey>|<matchKey>`.
    ///
    /// It carries BOTH ids on purpose, because the two ways to fetch a cover live
    /// on different devices:
    ///   • a device signed in to Plex resolves it from Plex directly (which is the
    ///     only option in standalone mode — there is no analyser to ask);
    ///   • a device with a RoonSage server but no Plex sign-in resolves it from
    ///     the analyser's `/artwork?match_key=`, exactly as before.
    /// Storing only one of the two would leave one of those devices without covers,
    /// and a library without covers reads as broken.
    public static func plexImageKey(ratingKey: String, matchKey: String) -> String {
        plexKeyPrefix + ratingKey + "|" + matchKey
    }

    /// Inverse of `plexImageKey`. nil when this is not a Plex artwork key.
    public static func parsePlexImageKey(_ key: String) -> (ratingKey: String, matchKey: String)? {
        guard key.hasPrefix(plexKeyPrefix) else { return nil }
        let body = key.dropFirst(plexKeyPrefix.count)
        guard let sep = body.firstIndex(of: "|") else { return nil }
        let rk = String(body[..<sep])
        let mk = String(body[body.index(after: sep)...])
        return rk.isEmpty ? nil : (rk, mk)
    }

    /// Album grouping key. Prefers Plex's own album id; falls back to the same
    /// `album|artist` fingerprint the other two sources use so a track whose
    /// album Plex could not key still groups instead of becoming its own album.
    public static func plexAlbumKey(albumRatingKey: String?, album: String?, artist: String?) -> String {
        if let albumRatingKey, !albumRatingKey.isEmpty { return plexKeyPrefix + albumRatingKey }
        return plexKeyPrefix + localAlbumFingerprint(album: album, artist: artist)
    }

    /// Make Plex's catalogue part of the library: every offered track becomes a
    /// `source='plex'` row, and the Roon rows they now own are displaced.
    ///
    /// Call this **after** `reconcileFeatureMatches(apply: true)`, for the same
    /// reason `ingestLocalTracks` does: reconcile rewrites `tracks.match_key` for
    /// confident fuzzy matches, so running first would mint a Plex row for a
    /// recording Roon does have under a slightly different spelling.
    @discardableResult
    public func ingestPlexTracks(_ rows: [PlexTrackRow]) async throws -> PlexIngestResult {
        let offered = rows.count
        return try await pool.write { db in
            let existing = Set(try String.fetchAll(
                db, sql: "SELECT id FROM tracks WHERE source = ?", arguments: [Self.plexSource]))

            var candidates: [PlexTrackRow] = []
            candidates.reserveCapacity(rows.count)
            var seen = Set<String>()
            for r in rows {
                let key = r.ratingKey.trimmingCharacters(in: .whitespaces)
                // No ratingKey = nothing to key on; no title = nothing to show.
                guard !key.isEmpty, !r.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                // Plex pages can overlap when the library is written to mid-walk,
                // so the same ratingKey can arrive twice — which would collide on
                // the primary key inside one multi-row INSERT.
                guard seen.insert(key).inserted else { continue }
                var row = r
                row.ratingKey = key
                // Normalise here as well as in PlexClient: a caller building rows
                // from anywhere else must not be able to store a decomposed path.
                row.filePath = r.filePath.map(PlexClient.normalizedPath)
                candidates.append(row)
            }
            let candidateIDs = Set(candidates.map { Self.plexTrackID(ratingKey: $0.ratingKey) })
            let inserted = candidateIDs.subtracting(existing).count

            // Rows Plex no longer offers. Same brake as the Roon walk and the
            // analyser ingest: a payload that shrank by more than half is a
            // truncated read (a paused server, a section mid-rescan), not a
            // library that halved.
            var pruned = 0
            let stale = existing.subtracting(candidateIDs)
            if !stale.isEmpty, candidates.count * 2 >= existing.count {
                let ids = Array(stale)
                let chunk = Self.rowsPerChunk(columns: 1)
                var start = 0
                while start < ids.count {
                    let slice = ids[start..<min(start + chunk, ids.count)]
                    let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM tracks WHERE source = ? AND id IN (\(placeholders))",
                        arguments: StatementArguments([Self.plexSource] + slice.map { $0 as DatabaseValueConvertible }))
                    pruned += db.changesCount
                    start += slice.count
                }
            }

            // Backdate first-seen before inserting, so importing a 65k-track Plex
            // library does not announce all of it as "new today" in "op deze dag".
            // Same reasoning (and same INSERT OR IGNORE) as ingestLocalTracks.
            if !candidates.isEmpty {
                let backdate = try String.fetchOne(db, sql: "SELECT MIN(first_seen) FROM track_first_seen")
                    ?? Self.isoFormatter.string(from: Date())
                let fsChunk = Self.rowsPerChunk(columns: 2)
                var fsStart = 0
                while fsStart < candidates.count {
                    let slice = candidates[fsStart..<min(fsStart + fsChunk, candidates.count)]
                    var args: [DatabaseValueConvertible] = []
                    var placeholders: [String] = []
                    for c in slice {
                        let mk = Self.plexMatchKey(c)
                        guard !mk.isEmpty else { continue }
                        placeholders.append("(?,?)")
                        args.append(mk); args.append(backdate)
                    }
                    if !placeholders.isEmpty {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO track_first_seen (match_key, first_seen) VALUES \(placeholders.joined(separator: ","))",
                            arguments: StatementArguments(args))
                    }
                    fsStart += slice.count
                }
            }

            let chunk = Self.rowsPerChunk(columns: 12)
            var start = 0
            while start < candidates.count {
                let slice = candidates[start..<min(start + chunk, candidates.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 12)
                for c in slice {
                    let albumKey = Self.plexAlbumKey(albumRatingKey: c.albumRatingKey,
                                                     album: c.album, artist: c.artist)
                    args.append(contentsOf: [
                        Self.plexTrackID(ratingKey: c.ratingKey),
                        c.title,
                        c.artist,
                        c.album,
                        albumKey,
                        c.year,
                        TrackIdentity.looksLive(title: c.title, context: c.album),
                        // match_key stays: every existing feature/radio/DJ query
                        // joins on it, and the exact file_path join is an
                        // addition, not a replacement.
                        Self.plexMatchKey(c),
                        // Both ids, so either resolution path works — see
                        // `plexImageKey`. A standalone device has no analyser to
                        // ask, so a key that only pointed at `/artwork` would
                        // leave it with a library of blank covers.
                        Self.plexImageKey(ratingKey: c.ratingKey, matchKey: Self.plexMatchKey(c)),
                        albumKey,       // album_fp
                        Self.plexSource,
                        c.filePath,
                    ] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO tracks
                      (id, title, artist, album, album_key, year, is_live, match_key,
                       image_key, album_fp, source, file_path)
                    VALUES \(placeholders)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, artist=excluded.artist, album=excluded.album,
                      album_key=excluded.album_key, year=COALESCE(excluded.year, year),
                      is_live=excluded.is_live,
                      match_key=excluded.match_key, image_key=excluded.image_key,
                      album_fp=excluded.album_fp, source=excluded.source,
                      file_path=COALESCE(excluded.file_path, file_path)
                """, arguments: StatementArguments(args))
                start += slice.count
            }

            // Displace the Roon rows Plex now owns, genres first — identical to
            // the analyser ingest, and for the same reason: `track_genres` is
            // keyed on the ROW with ON DELETE CASCADE, so deleting the Roon row
            // without moving them drops the only genre some tracks have.
            //
            // Only `source='roon'` is displaced, never `source='local'`. The two
            // synthetic sources describe the same files; deciding which of them
            // wins is a separate call, not a side effect of an import.
            var reclaimed = 0
            if !candidates.isEmpty, candidates.count * 2 >= existing.count {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO track_genres (track_id, genre)
                    SELECT p.id, g.genre
                    FROM track_genres g
                    JOIN tracks r ON r.id = g.track_id AND r.source = 'roon'
                    JOIN tracks p ON p.source = ? AND p.match_key = r.match_key
                    """, arguments: [Self.plexSource])
                try db.execute(sql: """
                    DELETE FROM tracks WHERE source = 'roon' AND match_key IN
                      (SELECT match_key FROM tracks
                       WHERE source = ? AND match_key IS NOT NULL AND match_key != '')
                    """, arguments: [Self.plexSource])
                reclaimed = db.changesCount
            }

            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tracks WHERE source = ?",
                arguments: [Self.plexSource]) ?? 0
            return PlexIngestResult(
                offered: offered,
                inserted: inserted,
                refreshed: candidates.count - inserted,
                reclaimed: reclaimed,
                pruned: pruned,
                total: total)
        }
    }

    /// Content key for a Plex row — the same `TrackIdentity` key the analyser and
    /// the Roon walk produce, so all three sources remain joinable on it.
    static func plexMatchKey(_ r: PlexTrackRow) -> String {
        TrackIdentity.matchKey(artist: r.artist ?? "", album: r.album ?? "", title: r.title)
    }

    /// How many library rows come from Plex — for the Settings diagnostic and the tests.
    public func plexTrackCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE source = ?",
                             arguments: [Self.plexSource]) ?? 0
        }
    }

    /// Plex rows whose `file_path` matches an analysed file exactly — the
    /// measurement that justifies this whole source. Returns (joined, total).
    public func plexFeatureJoinCoverage(analysedPaths: Set<String>) async throws -> (joined: Int, total: Int) {
        try await pool.read { db in
            let paths = try String.fetchAll(
                db, sql: "SELECT file_path FROM tracks WHERE source = ? AND file_path IS NOT NULL",
                arguments: [Self.plexSource])
            let joined = paths.reduce(into: 0) { acc, p in
                if analysedPaths.contains(p) { acc += 1 }
            }
            return (joined, paths.count)
        }
    }
}
