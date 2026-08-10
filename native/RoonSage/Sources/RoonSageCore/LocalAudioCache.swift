import CryptoKit
import Foundation

/// On-disk cache of audio the on-device player has already streamed — the
/// cheapest of the three offline tiers (see `native/docs/JELLYFIN_AUDIT.md` J1).
/// Without it, stepping back a track, repeating an album or replaying anything
/// from today re-fetches the whole file over the network.
///
/// Deliberately NOT keyed on the `/audio` URL: that URL carries a rotating
/// token and its host differs between LAN and ZeroTier, so URL-keying would
/// miss constantly and store the same track many times over. The key is the
/// library match key plus the transcode profile, which is what actually
/// determines the bytes.
///
/// Pure `Data`/filesystem so it lives in Core and is unit-testable — same shape
/// as `DiskImageCache`, and nonisolated so the fill can run off the main actor.
public enum LocalAudioCache {

    /// Public so the settings screen can bind `@AppStorage` to the same key this
    /// type reads, instead of repeating the string literal.
    public static let enabledKey = "local_audio_cache_enabled"
    public static let limitKey = "local_audio_cache_limit_mb"

    /// Whether to keep a copy of what we stream. On by default: the common case
    /// is listening at home, where the extra fetch is free and the payoff is
    /// instant replays.
    public static var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Cache ceiling in megabytes (default 2 GB — a few hundred FLAC tracks).
    public static var limitMB: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: limitKey)
            return v > 0 ? v : 2048
        }
        set { UserDefaults.standard.set(newValue, forKey: limitKey) }
    }

    /// Cache directory under Caches/ (the OS may evict it under disk pressure —
    /// fine, it re-streams). Overridable in tests.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static let defaultDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("RoonSageAudioCache", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func directory() -> URL? {
        if let directoryOverride {
            try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        return defaultDir
    }

    /// Stable name for the transcode profile, so an AAC copy and the original
    /// FLAC of the same track never collide in the cache.
    public static func variant(for queryItems: [URLQueryItem]) -> String {
        guard !queryItems.isEmpty else { return "orig" }
        return queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    /// Stable filename for a (match key, variant) pair — hashed because match
    /// keys are free text ("artist|title") and would not survive as paths.
    static func filename(forKey key: String, variant: String) -> String {
        let digest = SHA256.hash(data: Data("\(key)|\(variant)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(forKey key: String, variant: String) -> URL? {
        directory()?.appendingPathComponent(filename(forKey: key, variant: variant))
    }

    /// The local file for this track, or nil on a miss. Touches the modification
    /// date on a hit so pruning keeps what you actually listen to (LRU-ish).
    public static func cachedFile(forKey key: String, variant: String) -> URL? {
        guard !key.isEmpty, let f = fileURL(forKey: key, variant: variant),
              FileManager.default.fileExists(atPath: f.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return f
    }

    public static func store(_ data: Data, forKey key: String, variant: String) {
        guard !data.isEmpty, !key.isEmpty,
              let f = fileURL(forKey: key, variant: variant) else { return }
        try? data.write(to: f, options: .atomic)
    }

    /// Evict least-recently-used files until the cache is under the limit.
    /// Cheap to call once per session; safe off the main thread.
    public static func prune(limitBytes: Int? = nil) {
        let limit = limitBytes ?? (limitMB * 1024 * 1024)
        guard let dir = directory() else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            entries.append((f, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limit else { return }

        for e in entries.sorted(by: { $0.date < $1.date }) {
            if total <= limit { break }
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }

    /// Total bytes on disk — for the settings screen ("cache: 1,2 GB").
    public static func sizeBytes() -> Int {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Drop everything — the settings screen's "leeg de cache".
    public static func clear() {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
