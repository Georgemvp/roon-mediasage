import AudioAnalysis
import CLAPEngine
import Foundation

/// Lyrics that live on the music volume — the offline half of the lyrics story.
///
/// `LyricsService` in the app fetches from LRCLIB, which is excellent and also
/// a network call to a third party for every track. Most of a well-tagged
/// library already carries its own words: a `.lrc` sidecar written by a tagger,
/// an ID3 `SYLT`/`USLT` frame, or a Vorbis `LYRICS` comment holding a whole LRC
/// document. The analyser is the only process with the volume mounted, so it is
/// the only one that can read them.
///
/// Same shape as `ArtworkProvider`: keyed by match key, path resolved
/// server-side from the analyser's own DB, sidecar names matched against a real
/// directory listing because the volume is not guaranteed case-insensitive.
public enum LyricsProvider {

    /// Resolved lyrics for one track.
    public struct Resolved: Sendable, Equatable {
        public var plain: String?
        public var synced: [LRCParser.Line]?
        /// "lrc-sidecar", "sylt", "uslt", "lrc-tag" — kept so the coverage
        /// readout can say where a library's lyrics actually come from.
        public var source: String
        public var hasContent: Bool { !(plain?.isEmpty ?? true) || !(synced?.isEmpty ?? true) }
    }

    /// Lyrics for a match key, or `nil` when the track has no on-disk file and
    /// neither the file nor its folder carries any words.
    public static func lyrics(matchKey: String, store: FeatureStore) -> Resolved? {
        guard let path = store.filePath(forMatchKey: matchKey) else { return nil }
        return lyrics(forFileAt: URL(fileURLWithPath: path))
    }

    /// Sidecar first, embedded second.
    ///
    /// A `.lrc` next to the file is deliberately preferred over a `SYLT` frame:
    /// the sidecar is what the user (or their tagger) most recently wrote, and
    /// it is the file they can edit. An embedded frame is whatever shipped with
    /// the rip. When the sidecar has no words at all we fall through rather
    /// than record an empty win.
    public static func lyrics(forFileAt url: URL) -> Resolved? {
        if let sidecar = sidecarLyrics(besideFile: url), sidecar.hasContent { return sidecar }
        guard let embedded = MetadataReader.lyrics(url: url) else { return nil }
        let resolved = Resolved(plain: embedded.plain, synced: embedded.synced, source: embedded.source)
        return resolved.hasContent ? resolved : nil
    }

    /// The `.lrc` file beside the track: `Song.lrc` for `Song.flac`, or a
    /// case-variant of it.
    static func sidecarLyrics(besideFile url: URL) -> Resolved? {
        guard let match = sidecarURL(besideFile: url),
              let raw = try? String(contentsOf: match, encoding: .utf8) else { return nil }
        let synced = LRCParser.parse(raw)
        if synced.isEmpty {
            // A sidecar with no timestamps is still lyrics — plenty of taggers
            // write a plain .lrc. Refusing it because it doesn't parse as timed
            // would throw away words we are holding.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Resolved(plain: trimmed, synced: nil, source: "lrc-sidecar")
        }
        return Resolved(plain: LRCParser.plainText(raw), synced: synced, source: "lrc-sidecar")
    }

    /// Split out from `sidecarLyrics` so the name matching is testable without a
    /// real music library — the same split `ArtworkProvider` makes.
    static func sidecarURL(besideFile url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        guard !base.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for entry in entries {
            let entryURL = URL(fileURLWithPath: entry)
            guard entryURL.pathExtension.lowercased() == "lrc",
                  entryURL.deletingPathExtension().lastPathComponent.lowercased() == base else { continue }
            return dir.appendingPathComponent(entry)
        }
        return nil
    }

    /// The `/lyrics` response body, in exactly the shape `RoonSageCore.Lyrics`
    /// decodes: `plain`, `synced[{time,text}]`, `isInstrumental`.
    ///
    /// Hand-encoded rather than shared with a Codable type, because the type it
    /// has to match lives in `RoonSageCore` — which this module cannot import.
    /// The keys are the contract; `LyricsEndpointShapeTests` holds them to it.
    public static func jsonBody(_ resolved: Resolved?) -> Data {
        guard let resolved, resolved.hasContent else { return Data("null".utf8) }
        var obj: [String: Any] = ["isInstrumental": false]
        if let plain = resolved.plain, !plain.isEmpty { obj["plain"] = plain }
        if let synced = resolved.synced, !synced.isEmpty {
            obj["synced"] = synced.map { ["time": $0.time, "text": $0.text] as [String: Any] }
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
    }
}
