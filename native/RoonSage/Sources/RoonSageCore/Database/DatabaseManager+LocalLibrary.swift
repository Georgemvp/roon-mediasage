import AudioAnalysis
import Foundation
import GRDB

/// The library's second source: on-disk tracks the Roon walk never produced a
/// row for.
///
/// Measured on the real library (2026-08-23): the analyser holds 66.378 analysed
/// files, `track_audio_features` holds 64.038 of them — and **19.537 of those
/// have no `tracks` row**. Since `analyzedTrackIdentities()` joins
/// `tracks → track_audio_features`, every one of those analyses is invisible to
/// the library, the stations, the DJ sets and Music Map. The data was already
/// synced; only the library row was missing.
///
/// A local row is deliberately second-class: it is written **only** where the
/// Roon walk *and* the fuzzy reconcile produced nothing, and it is dropped again
/// the moment a Roon row claims the same `match_key`. Roon stays the primary
/// catalogue; this fills its gaps.
///
/// Playback needs no new code. `LocalPlayability.matchKey(for:)` recomputes the
/// key from artist/album/title, and these rows are built from the very tags the
/// analyser keyed on — so the recomputed key equals the stored one and the row
/// streams straight from the analyser's `/audio`. On a Roon zone the
/// `local::` id goes through the same synthetic-key branch as `import::`:
/// resolved by a fresh search at playback time.
extension DatabaseManager {

    /// Id prefix for a library row sourced from the analyser rather than Roon.
    /// Mirrors `importKeyPrefix` / `qobuz_search::`: a synthetic key that carries
    /// its own resolution strategy.
    public static let localKeyPrefix = "local::"

    /// `tracks.source` value for an analyser-sourced row. The Roon walk scopes
    /// all of its deletes to `source = 'roon'`, so these survive a resync.
    public static let localSource = "local"

    /// One analysed on-disk track offered to the library.
    public struct LocalTrackRow: Sendable, Equatable {
        public var matchKey: String
        public var artist: String?
        public var title: String
        public var album: String?
        public var year: Int?

        public init(matchKey: String, artist: String?, title: String, album: String?, year: Int?) {
            self.matchKey = matchKey
            self.artist = artist
            self.title = title
            self.album = album
            self.year = year
        }
    }

    public struct LocalIngestResult: Sendable, Equatable {
        /// Analysed rows the analyser offered.
        public var offered: Int
        /// Rows written as new local library rows.
        public var inserted: Int
        /// Existing local rows refreshed from newer file tags.
        public var refreshed: Int
        /// Local rows dropped because a Roon row now carries the same key.
        public var reclaimed: Int
        /// Local rows in the library after this pass.
        public var total: Int

        public init(offered: Int, inserted: Int, refreshed: Int, reclaimed: Int, total: Int) {
            self.offered = offered; self.inserted = inserted; self.refreshed = refreshed
            self.reclaimed = reclaimed; self.total = total
        }
    }

    /// Album grouping for a local row. Mirrors the fallback the library-share
    /// importer already uses (`album + "|" + artist`) so both synthetic sources
    /// group albums the same way — `COUNT(DISTINCT album_key)` and `playAlbum`'s
    /// `WHERE album_key = ?` both depend on it being stable and non-null.
    public static func localAlbumKey(album: String?, artist: String?) -> String {
        let al = (album ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let ar = (artist ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if al.isEmpty && ar.isEmpty { return localKeyPrefix + "unknown" }
        return localKeyPrefix + al + "|" + ar
    }

    /// Merge the analyser's on-disk tracks into the library as `source='local'`
    /// rows, for every key Roon doesn't already cover.
    ///
    /// Call this **after** `reconcileFeatureMatches(apply: true)`: reconcile
    /// rewrites `tracks.match_key` for confident fuzzy matches, so running first
    /// would create a local row for a track Roon does have, just under a slightly
    /// different spelling.
    @discardableResult
    public func ingestLocalTracks(_ rows: [LocalTrackRow]) async throws -> LocalIngestResult {
        let offered = rows.count
        return try await pool.write { db in
            // Roon caught up on a key we filled in earlier: drop our row rather
            // than show the same track twice. Done first, so a Roon row that
            // arrived this sync also blocks a re-insert below.
            try db.execute(sql: """
                DELETE FROM tracks WHERE source = ? AND match_key IN
                  (SELECT match_key FROM tracks
                   WHERE source = 'roon' AND match_key IS NOT NULL AND match_key != '')
                """, arguments: [Self.localSource])
            let reclaimed = db.changesCount

            let roonKeys = Set(try String.fetchAll(db, sql: """
                SELECT match_key FROM tracks
                WHERE source = 'roon' AND match_key IS NOT NULL AND match_key != ''
                """))
            let existingLocal = Set(try String.fetchAll(
                db, sql: "SELECT match_key FROM tracks WHERE source = ? AND match_key IS NOT NULL",
                arguments: [Self.localSource]))

            var candidates: [LocalTrackRow] = []
            candidates.reserveCapacity(rows.count)
            var seen = Set<String>()
            for r in rows {
                let key = r.matchKey.trimmingCharacters(in: .whitespaces)
                // A row without a key can't be joined to its own features, and a
                // row without a title can't be shown — neither is a library row.
                guard !key.isEmpty, !r.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard !roonKeys.contains(key) else { continue }
                // The analyser's export is keyed by match_key, but two rows can
                // still normalise onto one key; `id` is the primary key, so the
                // second would silently overwrite the first mid-statement.
                guard seen.insert(key).inserted else { continue }
                var row = r
                row.matchKey = key
                candidates.append(row)
            }
            let inserted = candidates.reduce(into: 0) { $0 += existingLocal.contains($1.matchKey) ? 0 : 1 }

            // Backdate first-seen BEFORE inserting. `trg_tracks_first_seen` stamps
            // every new row with `now`, which would announce 19.5k tracks as "new
            // today" in "op deze dag" and the new-in-library views. These files
            // were always there; only their library row is new. INSERT OR IGNORE
            // means an existing (older, real) stamp always wins.
            if !candidates.isEmpty {
                let backdate = try String.fetchOne(db, sql: "SELECT MIN(first_seen) FROM track_first_seen")
                    ?? Self.isoFormatter.string(from: Date())
                let fsChunk = Self.rowsPerChunk(columns: 2)
                var fsStart = 0
                while fsStart < candidates.count {
                    let slice = candidates[fsStart..<min(fsStart + fsChunk, candidates.count)]
                    let placeholders = slice.map { _ in "(?,?)" }.joined(separator: ",")
                    var args: [DatabaseValueConvertible] = []
                    args.reserveCapacity(slice.count * 2)
                    for c in slice { args.append(c.matchKey); args.append(backdate) }
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO track_first_seen (match_key, first_seen) VALUES \(placeholders)",
                        arguments: StatementArguments(args))
                    fsStart += slice.count
                }
            }

            let chunk = Self.rowsPerChunk(columns: 11)
            var start = 0
            while start < candidates.count {
                let slice = candidates[start..<min(start + chunk, candidates.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 11)
                for c in slice {
                    let albumKey = Self.localAlbumKey(album: c.album, artist: c.artist)
                    args.append(contentsOf: [
                        Self.localKeyPrefix + c.matchKey,
                        c.title,
                        c.artist,
                        c.album,
                        albumKey,
                        c.year,
                        TrackIdentity.looksLive(title: c.title, context: c.album),
                        c.matchKey,
                        nil,            // image_key — no Roon artwork; see fase 2 of STANDALONE_LIBRARY_PLAN
                        albumKey,       // album_fp — album grouping for the library share export
                        Self.localSource,
                    ] as [DatabaseValueConvertible?])
                }
                // Upsert, so a re-tagged file refreshes its row instead of
                // needing a library rebuild. `source` is re-asserted: a row that
                // is being written from the analyser IS a local row.
                try db.execute(sql: """
                    INSERT INTO tracks
                      (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp, source)
                    VALUES \(placeholders)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, artist=excluded.artist, album=excluded.album,
                      album_key=excluded.album_key, year=excluded.year, is_live=excluded.is_live,
                      match_key=excluded.match_key, album_fp=excluded.album_fp,
                      source=excluded.source
                """, arguments: StatementArguments(args))
                start += slice.count
            }

            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tracks WHERE source = ?",
                arguments: [Self.localSource]) ?? 0
            return LocalIngestResult(
                offered: offered,
                inserted: inserted,
                refreshed: candidates.count - inserted,
                reclaimed: reclaimed,
                total: total)
        }
    }

    /// How many library rows come from the analyser rather than Roon — for the
    /// Settings diagnostic and the tests.
    public func localTrackCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE source = ?",
                             arguments: [Self.localSource]) ?? 0
        }
    }
}
