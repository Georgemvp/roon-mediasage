import AVFoundation
import Foundation

public struct TrackMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
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
                if let raw = (item.key as? String)?.uppercased() ?? item.identifier?.rawValue.uppercased() {
                    if raw.contains("ARTIST"), m.artist == nil { m.artist = value }
                    else if raw.contains("ALBUM"), m.album == nil { m.album = value }
                    else if raw.contains("TITLE"), m.title == nil { m.title = value }
                    else if raw.contains("GENRE"), m.genre == nil { m.genre = value }
                    else if (raw.contains("DATE") || raw.contains("YEAR")), m.year == nil,
                            let y = saneYear(value) { m.year = y }
                }
            }
        }

        apply(asset.commonMetadata)
        apply(asset.metadata)
        return m
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
