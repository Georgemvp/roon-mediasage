import Accelerate
import AudioAnalysis
import Foundation

/// Shared post-selection hygiene for embedding-ranked track lists (LMS-style
/// constraint layer). Two problems it solves:
///
///  1. **Near-duplicate recordings.** The same performance shows up multiple
///     times in a large library (album + compilation + remaster). Metadata
///     rarely matches, but the embeddings do: cosine similarity above
///     `nearDuplicateSim` between two *different* tracks almost always means
///     the same recording. A ranked "similar tracks" list should never contain
///     it twice.
///  2. **Metadata duplicates.** Different masters of the same song that DO
///     share a normalized `title|artist` (the cheap check catches what the
///     embedding check can't when one copy has no vector).
public enum SonicSelection {
    /// Cosine similarity above which two tracks count as the same recording.
    /// LMS rejects at embedding distance < 0.05 (= similarity > 0.95).
    public static let nearDuplicateSim: Float = 0.95

    /// Greedy filter over a ranked hit list: keep a hit only if it is not a
    /// near-duplicate (embedding or title|artist) of an already-kept hit.
    /// O(kept·candidates) dot products — call on an oversampled list of a few
    /// hundred, not the full library.
    public static func dropNearDuplicates(
        _ hits: [VectorIndex.Hit], index: VectorIndex, limit: Int,
        threshold: Float = nearDuplicateSim
    ) -> [VectorIndex.Hit] {
        var kept: [VectorIndex.Hit] = []
        var keptVecs: [[Float]] = []
        var keptMetaKeys = Set<String>()
        // Same SONG by different artists. `metaKey` is title|artist, so four
        // covers of "Sultans of Swing" produced four different keys and none of
        // them deduped — and the embedding check can't help, because a jazz cover
        // and a lofi cover genuinely sound different. One per song title is the
        // right call for a playlist: the rare loss (two unrelated songs sharing a
        // title) beats four versions of one.
        var keptTitleKeys = Set<String>()
        kept.reserveCapacity(min(limit, hits.count))
        for h in hits {
            if kept.count >= limit { break }
            let meta = metaKey(h.track)
            if !meta.isEmpty, keptMetaKeys.contains(meta) { continue }
            let songKey = titleKey(h.track)
            if !songKey.isEmpty, keptTitleKeys.contains(songKey) { continue }
            guard let v = index.embedding(forId: h.track.id) else {
                kept.append(h)
                if !meta.isEmpty { keptMetaKeys.insert(meta) }
                if !songKey.isEmpty { keptTitleKeys.insert(songKey) }
                continue
            }
            var isDup = false
            for kv in keptVecs where dot(v, kv) > threshold { isDup = true; break }
            if isDup { continue }
            kept.append(h)
            keptVecs.append(v)
            if !meta.isEmpty { keptMetaKeys.insert(meta) }
            if !songKey.isEmpty { keptTitleKeys.insert(songKey) }
        }
        return kept
    }

    /// The song, independent of who performs it. Edition suffixes are stripped
    /// via `TrackIdentity.cleanTitle`, so "Sultans of Swing (Live)" and
    /// "Sultans of Swing" count as the same song.
    static func titleKey(_ t: DatabaseManager.SonicTrack) -> String {
        TrackIdentity.cleanTitle(t.title).lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func metaKey(_ t: DatabaseManager.SonicTrack) -> String {
        let title = t.title.lowercased().trimmingCharacters(in: .whitespaces)
        let artist = (t.artist ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return "" }
        return "\(title)|\(artist)"
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return d
    }
}
