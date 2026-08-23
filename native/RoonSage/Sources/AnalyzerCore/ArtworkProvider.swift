import AudioAnalysis
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album art for analyser-sourced library rows — the second half of the library's
/// second source.
///
/// Roon rows carry an `image_key` and the client fetches artwork from the Roon
/// Core. The 15.053 rows the analyser contributed have no such key: Roon never
/// indexed those files. Their artwork lives in the file (ID3 `APIC` / FLAC
/// `METADATA_BLOCK_PICTURE`) or in a `cover.jpg`-style sidecar next to it, and
/// the analyser is the only process that can reach either — it is the one with
/// the music volume mounted.
///
/// Everything is keyed by match key, never by path: the client only ever names a
/// track, and the path is resolved server-side from the analyser's own DB. Same
/// rule as `/audio`.
public enum ArtworkProvider {

    /// Sidecar basenames, in preference order. Matched case-insensitively
    /// against the real directory listing, because the music volume is not
    /// guaranteed to be case-insensitive.
    static let sidecarNames = ["cover", "folder", "front", "album", "artwork"]
    static let sidecarExtensions = ["jpg", "jpeg", "png", "webp"]

    public struct Image: Sendable, Equatable {
        public let data: Data
        public let contentType: String
        public init(data: Data, contentType: String) {
            self.data = data
            self.contentType = contentType
        }
    }

    // Rendering costs a metadata parse of a possibly-large FLAC plus a JPEG
    // encode. A library view asks for every visible tile at once and asks again
    // on every scroll back, so without a cache the analyser re-decodes the same
    // covers all day. Bounded by count, not bytes: entries are thumbnails.
    private static let cache: NSCache<NSString, CacheBox> = {
        let c = NSCache<NSString, CacheBox>()
        c.countLimit = 512
        return c
    }()

    private final class CacheBox {
        let image: Image?
        init(_ image: Image?) { self.image = image }
    }

    /// Artwork for a match key, downscaled to `maxPixel` on its long edge.
    /// `nil` when the track has no on-disk file, or the file and its folder
    /// carry no cover at all.
    ///
    /// A miss is cached too (as a nil box): a folder without art would otherwise
    /// be re-listed on every scroll past the same album.
    public static func artwork(matchKey: String, maxPixel: Int, store: FeatureStore) -> Image? {
        let cacheKey = "\(matchKey)|\(maxPixel)" as NSString
        if let box = cache.object(forKey: cacheKey) { return box.image }
        let image = render(matchKey: matchKey, maxPixel: maxPixel, store: store)
        cache.setObject(CacheBox(image), forKey: cacheKey)
        return image
    }

    private static func render(matchKey: String, maxPixel: Int, store: FeatureStore) -> Image? {
        guard let path = store.filePath(forMatchKey: matchKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let raw = MetadataReader.artwork(url: url) ?? sidecarData(besideFile: url) else { return nil }
        if let scaled = downscale(raw, maxPixel: maxPixel) {
            return Image(data: scaled, contentType: "image/jpeg")
        }
        // Undecodable by ImageIO (an exotic embedded format) — hand it over as-is
        // rather than dropping artwork we demonstrably have.
        return Image(data: raw, contentType: sniffContentType(raw))
    }

    /// First `cover.jpg`-style file in the track's own folder.
    static func sidecarData(besideFile url: URL) -> Data? {
        guard let match = sidecarURL(besideFile: url) else { return nil }
        return try? Data(contentsOf: match)
    }

    /// Split out from `sidecarData` so the name matching is testable without
    /// touching a real audio library.
    static func sidecarURL(besideFile url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        // Index the directory once, then walk our preference order — otherwise a
        // folder containing both back.jpg and cover.jpg answers with whichever
        // the filesystem happened to list first.
        var byLowercased: [String: String] = [:]
        for e in entries where byLowercased[e.lowercased()] == nil { byLowercased[e.lowercased()] = e }
        for name in sidecarNames {
            for ext in sidecarExtensions {
                if let real = byLowercased["\(name).\(ext)"] {
                    return dir.appendingPathComponent(real)
                }
            }
        }
        return nil
    }

    /// Downscale to a JPEG thumbnail. Embedded covers are routinely 1500×1500
    /// and over a megabyte; a library grid asks for 200 pt tiles, and the uplink
    /// here is the real bottleneck (39 Mbps). `nil` when ImageIO can't read it.
    static func downscale(_ data: Data, maxPixel: Int) -> Data? {
        guard maxPixel > 0, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Content type from the magic bytes. Only needed on the fallback path where
    /// ImageIO couldn't decode — an embedded cover carries no filename to guess
    /// from, and a wrong type makes the client refuse a perfectly good image.
    static func sniffContentType(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "image/jpeg" }
        if head.count >= 8, head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "image/png" }
        if head.count >= 12, head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46,
           head[8] == 0x57, head[9] == 0x45, head[10] == 0x42, head[11] == 0x50 { return "image/webp" }
        if head.count >= 6, head[0] == 0x47, head[1] == 0x49, head[2] == 0x46 { return "image/gif" }
        return "application/octet-stream"
    }

    /// Drop everything — for tests, and for the analyser's memory-pressure
    /// handler, which already releases the sonic caches.
    public static func clearCache() { cache.removeAllObjects() }
}
