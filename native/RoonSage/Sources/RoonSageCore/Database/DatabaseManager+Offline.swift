import Foundation
import GRDB

/// Bookkeeping for tracks pinned to this device.
///
/// The FILE on disk is the source of truth for playback — `LocalAudioCache`
/// answers "can I play this offline" without touching SQLite. This table exists
/// so a Downloads screen can list what you have with titles, artwork and sizes
/// instead of a directory of hashed filenames.
extension DatabaseManager {

    public struct OfflineTrack: Sendable, Identifiable, Equatable {
        public let matchKey: String
        public let variant: String
        public let title: String
        public let artist: String?
        public let album: String?
        public let imageKey: String?
        public let bytes: Int
        /// The stored file's NAME inside the downloads directory — never an
        /// absolute path. The app's container carries a UUID that changes on
        /// reinstall, so a full path written here would point nowhere on the
        /// next launch. Resolve with `LocalAudioCache.downloadURL(forFilename:)`.
        public let localPath: String?
        public var id: String { matchKey }

        /// The file on THIS device, if it is still there.
        public var localFileURL: URL? {
            localPath.flatMap { LocalAudioCache.downloadURL(forFilename: $0) }
        }
    }

    public func recordOfflineTrack(matchKey: String, variant: String, title: String,
                                   artist: String?, album: String?, imageKey: String?,
                                   bytes: Int, localPath: String? = nil) async {
        guard !matchKey.isEmpty else { return }
        try? await pool.write { db in
            try db.execute(sql: """
                INSERT INTO offline_tracks
                    (match_key, variant, title, artist, album, image_key, bytes, added_at, local_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(match_key) DO UPDATE SET
                    variant = excluded.variant, title = excluded.title,
                    artist = excluded.artist, album = excluded.album,
                    image_key = excluded.image_key, bytes = excluded.bytes,
                    local_path = excluded.local_path
                """, arguments: [matchKey, variant, title, artist, album,
                                 imageKey, bytes, ISO8601DateFormatter().string(from: Date()),
                                 localPath])
        }
    }

    /// Just the keys — what the UI needs to mark rows as available offline.
    public func offlineTrackKeys() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT match_key FROM offline_tracks")
        }
    }

    /// The full list for a Downloads screen, newest first.
    public func offlineTracks() async throws -> [OfflineTrack] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, variant, title, artist, album, image_key, bytes, local_path
                FROM offline_tracks ORDER BY added_at DESC
                """).map {
                OfflineTrack(matchKey: $0["match_key"], variant: $0["variant"],
                             title: $0["title"], artist: $0["artist"], album: $0["album"],
                             imageKey: $0["image_key"], bytes: $0["bytes"] ?? 0,
                             localPath: $0["local_path"])
            }
        }
    }

    /// Which variant is actually stored for this track — the delete path must
    /// remove the file that EXISTS, not the one the current transcode policy
    /// would ask for. Download on Wi-Fi ("orig"), remove on cellular (AAC), and
    /// a variant-guessing delete silently leaves the file behind.
    public func offlineVariant(matchKey: String) async -> String? {
        try? await pool.read { db in
            try String.fetchOne(db, sql: "SELECT variant FROM offline_tracks WHERE match_key = ?",
                                arguments: [matchKey])
        }
    }

    public func deleteOfflineTrack(matchKey: String) async {
        try? await pool.write { db in
            try db.execute(sql: "DELETE FROM offline_tracks WHERE match_key = ?", arguments: [matchKey])
        }
    }

    public func deleteAllOfflineTracks() async {
        try? await pool.write { db in try db.execute(sql: "DELETE FROM offline_tracks") }
    }

    /// Every library track on one of `albums`, where an album is the
    /// `(album, artist)` NAME pair — the content key `FavoriteKind.albumKey`
    /// produces, not a Roon `album_key`.
    ///
    /// Name-matched deliberately: a star survives a resync precisely because it
    /// is not tied to an item key, so the tracks behind it have to be found the
    /// same way. A nil artist on the favourite matches any artist on the album,
    /// which is how a starred compilation resolves.
    public func tracksForFavoriteAlbums(_ albums: [(album: String, artist: String?)]) async throws
        -> [TrackRecord] {
        guard !albums.isEmpty else { return [] }
        return try await pool.read { db in
            var out: [TrackRecord] = []
            var seen = Set<String>()
            for entry in albums {
                let album = entry.album.lowercased()
                guard !album.isEmpty else { continue }
                let rows: [TrackRecord]
                if let artist = entry.artist, !artist.isEmpty {
                    rows = try TrackRecord.fetchAll(db, sql: """
                        SELECT * FROM tracks
                        WHERE LOWER(album) = ? AND LOWER(artist) = ?
                        ORDER BY rowid
                        """, arguments: [album, artist.lowercased()])
                } else {
                    rows = try TrackRecord.fetchAll(db, sql: """
                        SELECT * FROM tracks WHERE LOWER(album) = ? ORDER BY rowid
                        """, arguments: [album])
                }
                for r in rows where seen.insert(r.id).inserted { out.append(r) }
            }
            return out
        }
    }
}
