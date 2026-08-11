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
        public var id: String { matchKey }
    }

    public func recordOfflineTrack(matchKey: String, variant: String, title: String,
                                   artist: String?, album: String?, imageKey: String?,
                                   bytes: Int) async {
        guard !matchKey.isEmpty else { return }
        try? await pool.write { db in
            try db.execute(sql: """
                INSERT INTO offline_tracks
                    (match_key, variant, title, artist, album, image_key, bytes, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(match_key) DO UPDATE SET
                    variant = excluded.variant, title = excluded.title,
                    artist = excluded.artist, album = excluded.album,
                    image_key = excluded.image_key, bytes = excluded.bytes
                """, arguments: [matchKey, variant, title, artist, album,
                                 imageKey, bytes, ISO8601DateFormatter().string(from: Date())])
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
                SELECT match_key, variant, title, artist, album, image_key, bytes
                FROM offline_tracks ORDER BY added_at DESC
                """).map {
                OfflineTrack(matchKey: $0["match_key"], variant: $0["variant"],
                             title: $0["title"], artist: $0["artist"], album: $0["album"],
                             imageKey: $0["image_key"], bytes: $0["bytes"] ?? 0)
            }
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
}
