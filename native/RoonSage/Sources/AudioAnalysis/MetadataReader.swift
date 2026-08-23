import AVFoundation
import Foundation

public struct TrackMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?

    // Hard identity, straight out of the file's tags. Unlike artist/title these
    // are exact: two files with the same ISRC are the same recording, whatever
    // their spelling. Measured on a 385-file sample of the real library
    // (2026-08-23): ISRC in 80% of files, a MusicBrainz recording/release-track
    // id in 24%. 41% of files carried an ISRC that nothing was reading.
    public var isrc: String?
    public var recordingMBID: String?
    public var releaseTrackMBID: String?
    public var albumMBID: String?
    public var artistMBID: String?

    /// Empty metadata — what an unreadable or missing file yields. Public so the
    /// identity backfill can stamp such a row as "read, nothing there" instead of
    /// retrying it on every launch.
    public init() {}
}

/// Reads embedded tags (Vorbis comments / ID3 / iTunes) via AVFoundation.
public struct MetadataReader {

    /// Broken tags produce years like 4018 or 0; a bad year is worse than none
    /// (a 4018 tag once minted a ghost "decade:4010" radio on Qobuz). Accept
    /// only plausible values.
    static func saneYear(_ v: String?) -> Int? {
        guard let v, let y = Int(v.prefix(4)), (1900...2035).contains(y) else { return nil }
        return y
    }

    /// ISRC is exactly 12 alphanumerics (CC-XXX-YY-NNNNN); taggers write it with
    /// and without the dashes. Normalise to the bare form so two spellings of the
    /// same code compare equal, and reject anything that isn't one — a malformed
    /// identifier is worse than none, because it joins rows that aren't the same
    /// recording.
    public static func normalisedISRC(_ v: String?) -> String? {
        guard let v else { return nil }
        let bare = v.uppercased().filter { $0.isLetter || $0.isNumber }
        guard bare.count == 12 else { return nil }
        // Country code is alphabetic, the rest alphanumeric.
        guard bare.prefix(2).allSatisfy({ $0.isLetter }) else { return nil }
        return bare
    }

    /// A MusicBrainz id is a canonical 8-4-4-4-12 UUID. Lowercased so the same id
    /// from two taggers is one string; anything else is rejected rather than
    /// stored as a half-identity.
    public static func normalisedMBID(_ v: String?) -> String? {
        guard let v else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return looksLikeMBID(trimmed) ? trimmed : nil
    }

    /// Shape test only — used both to accept an id and to refuse to store one as
    /// a human-readable name.
    public static func looksLikeMBID(_ v: String) -> Bool {
        let parts = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "-",
                                                                                         omittingEmptySubsequences: false)
        guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy { c in c.isHexDigit } }
    }

    /// Route one raw Vorbis/ID3 tag into the metadata. Split out of `read` so the
    /// routing is testable without a tagged audio file on disk — this is exactly
    /// where the MBID-as-artist bug lived, and a bug you can't write a test
    /// against comes back.
    ///
    /// `raw` is the uppercased tag name as AVFoundation hands it over.
    static func applyRawTag(_ raw: String, _ value: String, into m: inout TrackMetadata) {
        // Squash punctuation so a Vorbis comment (MUSICBRAINZ_RELEASETRACKID) and
        // an ID3 TXXX description ("MusicBrainz Release Track Id") are one key.
        let squashed = raw.filter { $0.isLetter || $0.isNumber }

        // Identity FIRST, and it never falls through to the name matching below.
        // That fall-through was a real bug: MUSICBRAINZ_ARTISTID contains
        // "ARTIST" and MUSICBRAINZ_ALBUMID contains "ALBUM", so in a file whose
        // MB tag was enumerated before its plain tag the UUID was stored as the
        // artist and album NAME. 412 tracks in the real library were keyed on a
        // UUID that way (measured 2026-08-23) — invisible to every join, and
        // shown to the user as an artist called "300c4c73-33ac-…".
        if squashed == "ISRC" {
            if m.isrc == nil { m.isrc = normalisedISRC(value) }
            return
        }
        if squashed.hasPrefix("MUSICBRAINZ") {
            let id = normalisedMBID(value)
            switch squashed {
            case "MUSICBRAINZRELEASETRACKID": m.releaseTrackMBID = m.releaseTrackMBID ?? id
            case "MUSICBRAINZTRACKID", "MUSICBRAINZRECORDINGID": m.recordingMBID = m.recordingMBID ?? id
            case "MUSICBRAINZALBUMID", "MUSICBRAINZRELEASEID": m.albumMBID = m.albumMBID ?? id
            case "MUSICBRAINZARTISTID", "MUSICBRAINZALBUMARTISTID": m.artistMBID = m.artistMBID ?? id
            default: break   // release-group, work, disc-id … not used
            }
            return
        }

        // Belt and braces for tag schemes we haven't seen: a bare UUID is an
        // identifier, never a name a human typed.
        if raw.contains("ARTIST"), m.artist == nil, !looksLikeMBID(value) { m.artist = value }
        else if raw.contains("ALBUM"), m.album == nil, !looksLikeMBID(value) { m.album = value }
        else if raw.contains("TITLE"), m.title == nil, !looksLikeMBID(value) { m.title = value }
        else if raw.contains("GENRE"), m.genre == nil { m.genre = value }
        else if raw.contains("DATE") || raw.contains("YEAR"), m.year == nil,
                let y = saneYear(value) { m.year = y }
    }

    public static func read(url: URL) -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var m = TrackMetadata()

        func apply(_ items: [AVMetadataItem]) {
            for item in items {
                let value = item.stringValue
                if let key = item.commonKey {
                    switch key {
                    case .commonKeyTitle:       m.title  = m.title  ?? value
                    case .commonKeyArtist,
                         .commonKeyAuthor:      m.artist = m.artist ?? value
                    case .commonKeyAlbumName:   m.album  = m.album  ?? value
                    case .commonKeyType:        m.genre  = m.genre  ?? value
                    case .commonKeyCreationDate:
                        if let y = saneYear(value) { m.year = m.year ?? y }
                    default: break
                    }
                }
                // Vorbis/ID3 raw keys (FLAC etc. surface here, not commonMetadata).
                if let raw = (item.key as? String)?.uppercased() ?? item.identifier?.rawValue.uppercased(),
                   let value {
                    applyRawTag(raw, value, into: &m)
                }
            }
        }

        apply(asset.commonMetadata)
        apply(asset.metadata)
        return m
    }

    /// Lyrics carried inside the audio file itself.
    ///
    /// `synced` wins over `plain` for a karaoke view, but both are returned:
    /// a file can hold a `SYLT` frame with only the chorus timed and a full
    /// `USLT` transcription beside it, and throwing one away to keep the other
    /// loses words either way.
    public struct EmbeddedLyrics: Sendable, Equatable {
        public var plain: String?
        public var synced: [LRCParser.Line]?
        /// Where it came from — "sylt", "uslt", "lrc-tag" — for the coverage
        /// readout and for telling a tagger's output from LRCLIB's.
        public var source: String
        public var isEmpty: Bool { (plain?.isEmpty ?? true) && (synced?.isEmpty ?? true) }
    }

    /// Read embedded lyrics: ID3 `SYLT` (synchronised) first, then any of the
    /// unsynchronised carriers — ID3 `USLT`, the iTunes `©lyr` atom, and the
    /// Vorbis comments FLAC taggers actually write (`LYRICS`,
    /// `UNSYNCEDLYRICS`, `SYNCEDLYRICS`).
    ///
    /// A Vorbis `LYRICS` comment routinely holds a whole LRC document rather
    /// than plain text — that is how most FLAC taggers store timed lyrics,
    /// since Vorbis has no SYLT equivalent. So an unsynchronised carrier whose
    /// text parses as LRC is promoted to `synced`, and the words are kept as
    /// `plain` as well.
    ///
    /// Returns `nil` when the file carries nothing (distinct from an empty
    /// `EmbeddedLyrics`, which never happens here) so the caller can record a
    /// negative and stop re-reading the file.
    public static func lyrics(url: URL) -> EmbeddedLyrics? {
        let asset = AVURLAsset(url: url)
        var syncedFromSYLT: [LRCParser.Line]?
        var rawText: String?
        var textSource = "uslt"

        func scan(_ items: [AVMetadataItem]) {
            for item in items {
                let raw = ((item.key as? String) ?? item.identifier?.rawValue ?? "").uppercased()
                // Squash punctuation so `UNSYNCED_LYRICS`, `UNSYNCEDLYRICS` and
                // an ID3 identifier like `ID3/SYLT` compare as one key — the
                // same normalisation `applyRawTag` uses for identity tags.
                let squashed = raw.filter { $0.isLetter || $0.isNumber }

                if syncedFromSYLT == nil, squashed.contains("SYLT"),
                   let data = item.dataValue, let lines = SYLTParser.parse(data) {
                    syncedFromSYLT = lines
                    continue
                }
                guard rawText == nil, let value = item.stringValue,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // "LYRICIST" and "ORIGINALLYRICIST" are credits, not words —
                // they contain "LYRIC" and would otherwise be stored as the
                // song's lyrics.
                guard !squashed.contains("LYRICIST") else { continue }
                if squashed.contains("USLT") { rawText = value; textSource = "uslt" }
                else if squashed.contains("SYNCEDLYRICS") { rawText = value; textSource = "lrc-tag" }
                else if squashed.contains("LYRIC") { rawText = value; textSource = "lrc-tag" }
            }
        }

        scan(asset.commonMetadata)
        scan(asset.metadata)

        var synced = syncedFromSYLT
        var plain: String?
        var source = syncedFromSYLT != nil ? "sylt" : textSource

        if let rawText {
            let parsed = LRCParser.parse(rawText)
            if !parsed.isEmpty {
                if synced == nil { synced = parsed; source = "lrc-tag" }
                plain = LRCParser.plainText(rawText)
            } else {
                plain = rawText
            }
        }

        let result = EmbeddedLyrics(plain: plain, synced: synced, source: source)
        return result.isEmpty ? nil : result
    }

    /// Embedded cover art, if the file carries any.
    ///
    /// Roon-sourced library rows get their artwork from the Roon Core's image
    /// API by `image_key`. Analyser-sourced rows have no such key — Roon never
    /// saw them — so their artwork has to come out of the file itself (or a
    /// sidecar next to it; see `ArtworkProvider`).
    ///
    /// Same two-pass shape as `read`: `commonMetadata` covers ID3/iTunes, while
    /// FLAC's `METADATA_BLOCK_PICTURE` surfaces only in `metadata` under a raw
    /// key. Returns the first non-empty payload — files with both a front and a
    /// back cover list the front first.
    public static func artwork(url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        func pick(_ items: [AVMetadataItem]) -> Data? {
            for item in items {
                if item.commonKey == .commonKeyArtwork, let d = item.dataValue, !d.isEmpty { return d }
                let raw = ((item.key as? String) ?? item.identifier?.rawValue ?? "").uppercased()
                if raw.contains("PICTURE") || raw.contains("COVER") || raw.contains("APIC"),
                   let d = item.dataValue, !d.isEmpty { return d }
            }
            return nil
        }
        return pick(asset.commonMetadata) ?? pick(asset.metadata)
    }
}
