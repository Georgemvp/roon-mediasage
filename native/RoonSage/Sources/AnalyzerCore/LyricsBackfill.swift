import AudioAnalysis
import Foundation

public struct LyricsProgress: Sendable {
    public var checked: Int      // rows whose file has been looked at
    public var withLyrics: Int   // rows that yielded words
    public var total: Int
}

/// Harvests the lyrics a library already owns — `.lrc` sidecars and embedded
/// `SYLT`/`USLT`/Vorbis frames — into the analyser's store, so `/lyrics` can
/// answer offline and instantly.
///
/// The counterpart to `LyricsService`, which fetches from LRCLIB one track at a
/// time over the network. Anything found here never needs that round trip, and
/// it is also the only source for a track LRCLIB has never heard of.
///
/// Deliberately a backfill rather than a hook in `LibraryWalker`: the walk skips
/// the ~24k already-analysed rows (that is its whole design — see
/// `LibraryWalker.decide`), so a hook there would only ever see newly added
/// files and the existing library would stay lyric-less forever. A backfill
/// covers everything and, being resumable, costs one query once it is done.
///
/// Resumable and idempotent for the same reason as `IdentityBackfill`: a row is
/// stamped `checked_at` even when it yields nothing, so a cancelled run
/// continues where it stopped and a finished one does not re-read the volume.
/// Gentle on the disk — the library lives on an external drive.
public final class LyricsBackfill {
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

    /// Returns how many tracks yielded lyrics this run.
    @discardableResult
    public func run(onProgress: @escaping @Sendable (LyricsProgress) -> Void) async -> Int {
        let total = store.count()
        guard total > 0 else { return 0 }
        var found = 0

        while !cancelled {
            let rows = store.tracksNeedingLyrics(limit: batch)
            if rows.isEmpty { break }
            for row in rows {
                if cancelled { break }
                // A missing file still gets stamped: the volume can be
                // unmounted, and retrying every launch would re-walk the whole
                // library each time it is.
                let resolved = FileManager.default.fileExists(atPath: row.filePath)
                    ? LyricsProvider.lyrics(forFileAt: URL(fileURLWithPath: row.filePath))
                    : nil
                if resolved?.hasContent == true { found += 1 }
                try? store.setLyrics(matchKey: row.matchKey, lyrics: resolved, checkedAt: Self.now())
            }
            let counts = store.lyricsCounts()
            onProgress(LyricsProgress(checked: counts.checked, withLyrics: counts.withLyrics, total: total))
            if throttleNanos > 0 { try? await Task.sleep(nanoseconds: throttleNanos) }
        }
        return found
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
