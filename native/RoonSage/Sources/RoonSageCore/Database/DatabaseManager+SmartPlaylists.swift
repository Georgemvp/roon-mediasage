import Foundation
import GRDB

extension DatabaseManager {

    /// Run a compiled smart playlist against the library.
    ///
    /// One query. Everything the rules can express in SQL is expressed in SQL —
    /// on a 66.000-row library, fetching rows to filter them in Swift means
    /// reading the whole table to keep forty of them.
    ///
    /// The play-stat join is a sub-select rather than a column on `tracks`
    /// because `listening_history` has no match key: it stores what was playing
    /// (title/artist text), and the v18 expression index is what makes the
    /// LOWER() join fast. Same shape as `playStatsByMatchKey`, including the
    /// `COUNT(DISTINCT h.id)` — several `tracks` rows can share one match key
    /// (soundtrack + compilation + a duplicate album), and `COUNT(*)` would
    /// multiply every play by the number of duplicates.
    ///
    /// Result rows carry `matchKey`, so the caller can rank them by embedding
    /// when the rules asked for sonic similarity.
    public func smartPlaylistTracks(_ rules: SmartPlaylistRules) async throws -> [LibraryTrackRow] {
        try await pool.read { db in
            // The genre expansion is the one part the compiler cannot do on its
            // own: walking the taxonomy down from "electronic" to "techno"
            // needs the database.
            let expanded = try rules.genre.map { try Self.expandGenres(db, $0) } ?? []
            // A genre rule naming only genres this library has never seen would
            // otherwise compile to no clause at all and return everything —
            // silently turning a narrow rule into "the whole library".
            if let requested = rules.genre, !requested.isEmpty, expanded.isEmpty { return [] }

            let compiled = SmartPlaylistEngine.compile(rules, expandedGenres: expanded)
            let whereClause = compiled.whereClauses.isEmpty
                ? "" : "WHERE " + compiled.whereClauses.joined(separator: " AND ")
            let playStatsJoin = compiled.needsPlayStats ? """
                LEFT JOIN (
                    SELECT t2.match_key AS mk,
                           COUNT(DISTINCT h.id) AS plays,
                           MAX(h.played_at) AS last_played
                    FROM listening_history h
                    JOIN tracks t2 ON LOWER(t2.title) = LOWER(h.title)
                                  AND LOWER(t2.artist) = LOWER(h.artist)
                    WHERE t2.match_key IS NOT NULL AND t2.match_key <> ''
                    GROUP BY t2.match_key
                ) ps ON ps.mk = t.match_key
                """ : ""

            var args: [DatabaseValue] = compiled.arguments
            args.append(compiled.limit.databaseValue)
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key,
                       t.match_key AS mk, f.bpm, f.camelot, f.tags
                FROM tracks t
                LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                \(playStatsJoin)
                \(whereClause)
                GROUP BY t.match_key
                ORDER BY t.artist, t.year, t.title
                LIMIT ?
                """, arguments: StatementArguments(args))
            return rows.map { Self.smartPlaylistRow($0) }
        }
    }

    /// Duplicates the projection mapping of `DatabaseManager+Discovery`'s
    /// `libraryTrackRow` because that one is `private` to its file. Both read
    /// the same aliases, so a change to the projection has to touch both — the
    /// alternative was widening a private helper for one caller.
    private static func smartPlaylistRow(_ r: Row) -> LibraryTrackRow {
        var tags: [String] = []
        if let t = r["tags"] as String?, let data = t.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            tags = arr.compactMap { $0 as? String }
        }
        return LibraryTrackRow(
            id: r["id"] ?? "", title: r["title"] ?? "", artist: r["artist"], album: r["album"],
            year: r["year"], isLive: (r["is_live"] as Bool?) ?? false,
            imageKey: r["image_key"], bpm: r["bpm"], camelot: r["camelot"], tags: tags,
            matchKey: r["mk"])
    }

    // MARK: - Recaps

    /// One recap period's most-played tracks, resolved to current library rows.
    ///
    /// Ranked by plays in the window, then by recency inside a tie, so a week
    /// where everything was played twice still reads as a sequence rather than
    /// as alphabetical order.
    public func recapTracks(from: Date, to: Date, limit: Int = 30) async throws -> [TrackRecord] {
        try await pool.read { db in
            let start = Self.isoFormatter.string(from: from)
            let end = Self.isoFormatter.string(from: to)
            return try TrackRecord.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                JOIN (
                    SELECT LOWER(title) AS lt, LOWER(artist) AS la,
                           COUNT(*) AS plays, MAX(played_at) AS last_play
                    FROM listening_history
                    WHERE artist IS NOT NULL AND played_at >= ? AND played_at < ?
                    GROUP BY LOWER(title), LOWER(artist)
                ) h ON LOWER(t.title) = h.lt AND LOWER(t.artist) = h.la
                GROUP BY LOWER(t.title), LOWER(t.artist)
                ORDER BY h.plays DESC, h.last_play DESC
                LIMIT ?
                """, arguments: [start, end, limit])
        }
    }

    /// How many plays fall inside a window — used to skip generating a recap
    /// for a week nobody listened in, which would otherwise be an empty
    /// playlist claiming to be a summary.
    public func listenCount(from: Date, to: Date) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM listening_history WHERE played_at >= ? AND played_at < ?
                """, arguments: [Self.isoFormatter.string(from: from),
                                 Self.isoFormatter.string(from: to)]) ?? 0
        }
    }
}
