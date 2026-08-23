import AudioAnalysis
import Foundation

public struct IdentityProgress: Sendable {
    public var checked: Int      // rows whose tags have been read
    public var withIdentity: Int // rows carrying an ISRC or a MusicBrainz id
    public var repaired: Int     // rows whose artist/album held a UUID, this run
    public var total: Int
}

/// Reads hard identity — ISRC and MusicBrainz ids — off the tags of tracks that
/// were analysed before `MetadataReader` knew how to look for them.
///
/// Cheap compared to every other backfill in here: no audio is decoded, only the
/// tag block is parsed. Measured on the real library (2026-08-23): 80% of files
/// carry an ISRC in their tags while only 52% of rows had one stored — the rest
/// had been read straight past, because the substring matching that harvested
/// artist/album never looked for it.
///
/// It also repairs the damage that same matching did. `MUSICBRAINZ_ARTISTID`
/// contains "ARTIST" and `MUSICBRAINZ_ALBUMID` contains "ALBUM", so in files
/// where the MusicBrainz tag was enumerated first the UUID was stored as the
/// artist and album NAME — 412 rows, keyed on a UUID, unmatchable by anything.
/// The reader no longer does that, but a stored row stays wrong until someone
/// rewrites it, and the corrected names produce a different `match_key` (the
/// primary key), so the repair has to move the row.
///
/// Resumable and idempotent: a row is stamped `identity_checked_at` even when it
/// yields nothing, so a cancelled run continues and a finished one costs a single
/// query. Gentle on the disk for the same reason as `LoudnessBackfill` — the
/// library lives on an external drive.
public final class IdentityBackfill {
    private let store: FeatureStore
    private let batch: Int
    private let throttleNanos: UInt64
    private var cancelled = false

    public init(store: FeatureStore, batch: Int = 200, throttleMs: UInt64 = 5) {
        self.store = store
        self.batch = max(1, batch)
        self.throttleNanos = throttleMs * 1_000_000
    }

    public func cancel() { cancelled = true }

    @discardableResult
    public func run(onProgress: @escaping @Sendable (IdentityProgress) -> Void) async -> Int {
        let total = store.count()
        guard total > 0 else { return 0 }
        var repaired = 0

        while !cancelled {
            let rows = store.tracksNeedingIdentity(limit: batch)
            if rows.isEmpty { break }
            for row in rows {
                if cancelled { break }
                let url = URL(fileURLWithPath: row.filePath)
                // A missing or unreadable file yields an empty read, and the row is
                // still stamped — it must not be retried on every launch.
                let meta = FileManager.default.fileExists(atPath: row.filePath)
                    ? MetadataReader.read(url: url)
                    : TrackMetadata()

                // Repair BEFORE writing identity: the repair can move the row to a
                // different primary key, and the identity write addresses it by key.
                var key = row.matchKey
                if Self.isMBID(row.artist) || Self.isMBID(row.album) {
                    let artist = Self.isMBID(row.artist) ? meta.artist : row.artist
                    let album = Self.isMBID(row.album) ? meta.album : row.album
                    let newKey = TrackIdentity.matchKey(artist: artist, album: album, title: meta.title)
                    if let outcome = try? store.repairIdentityNames(
                        matchKey: row.matchKey, artist: artist, album: album, newMatchKey: newKey) {
                        repaired += 1
                        if outcome == .droppedDuplicate { continue }   // the row is gone
                        if outcome == .rekeyed { key = newKey }
                    }
                }

                try? store.setIdentity(matchKey: key, isrc: meta.isrc,
                                       recordingMBID: meta.recordingMBID,
                                       releaseTrackMBID: meta.releaseTrackMBID,
                                       albumMBID: meta.albumMBID, artistMBID: meta.artistMBID,
                                       checkedAt: Self.now())
            }
            onProgress(IdentityProgress(checked: store.identityCheckedCount(),
                                        withIdentity: store.hardIdentityCount(),
                                        repaired: repaired, total: total))
            if throttleNanos > 0 { try? await Task.sleep(nanoseconds: throttleNanos) }
        }
        return repaired
    }

    /// A stored name that is really a MusicBrainz id. Shape test only — no real
    /// artist or album is spelled as a bare UUID.
    static func isMBID(_ v: String?) -> Bool {
        guard let v else { return false }
        return MetadataReader.looksLikeMBID(v)
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
