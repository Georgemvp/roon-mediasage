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
    public static let downloadOnCellularKey = "downloads_on_cellular"

    /// Whether a download may run on an expensive path. Off by default: a
    /// download is the largest transfer this app makes, and the whole point of
    /// taking music with you is that you did it before you left.
    public static var downloadOnCellular: Bool {
        get { UserDefaults.standard.bool(forKey: downloadOnCellularKey) }
        set { UserDefaults.standard.set(newValue, forKey: downloadOnCellularKey) }
    }
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

    // MARK: - Pinned downloads
    //
    // Two tiers, one key scheme. The cache above is opportunistic and LRU-pruned;
    // a DOWNLOAD is something you asked for and must survive both pruning and the
    // OS reclaiming Caches/. So pinned files live in Application Support, and
    // `prune()` never looks there.

    nonisolated(unsafe) static var pinnedDirectoryOverride: URL?

    private static let defaultPinnedDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let d = base.appendingPathComponent("RoonSageDownloads", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        // Downloads are the user's copy of their own music: never hand them to
        // iCloud backup, and never let the OS purge them to reclaim space.
        var url = d
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return d
    }()

    static func pinnedDirectory() -> URL? {
        if let pinnedDirectoryOverride {
            try? FileManager.default.createDirectory(
                at: pinnedDirectoryOverride, withIntermediateDirectories: true)
            return pinnedDirectoryOverride
        }
        return defaultPinnedDir
    }

    private static func pinnedURL(forKey key: String, variant: String) -> URL? {
        guard let dir = pinnedDirectory() else { return nil }
        return locate(base: filename(forKey: key, variant: variant), in: dir)
    }

    /// The downloaded file for this track, or nil. Unlike the cache this does NOT
    /// touch the modification date — nothing ages downloads out.
    public static func downloadedFile(forKey key: String, variant: String) -> URL? {
        guard !key.isEmpty else { return nil }
        return pinnedURL(forKey: key, variant: variant)
    }

    public static func storeDownload(_ data: Data, forKey key: String, variant: String) -> Bool {
        guard !data.isEmpty, !key.isEmpty, let dir = pinnedDirectory() else { return false }
        let f = destination(base: filename(forKey: key, variant: variant), in: dir, for: data)
        do { try data.write(to: f, options: .atomic); return true } catch { return false }
    }

    /// Pin a file that is ALREADY on disk, by moving it — for
    /// `URLSessionDownloadTask`, which hands over a temporary file rather than
    /// bytes.
    ///
    /// A move instead of a read-then-write: a FLAC album track is 30–40 MB, and
    /// `Data(contentsOf:)` on the download's temp file would put every one of
    /// them through RAM on a phone. It also has to happen synchronously inside
    /// the delegate callback — URLSession deletes the temp file the moment that
    /// callback returns.
    ///
    /// Returns the stored file's NAME (not its path): the app's container
    /// directory carries a UUID that changes when the app is reinstalled, so an
    /// absolute path recorded in the database would be wrong on the next launch.
    /// Callers resolve it against `pinnedDirectory()`.
    public static func storeDownload(movingFrom temp: URL, forKey key: String, variant: String) -> String? {
        guard !key.isEmpty, let dir = pinnedDirectory() else { return nil }
        // The extension decides whether AVURLAsset will open the file at all
        // (see the note above), and it has to be read from the bytes — the
        // temp file is named by URLSession and has no meaningful extension.
        let base = filename(forKey: key, variant: variant)
        let ext = fileExtension(ofFileAt: temp)
        let dest = ext.map { dir.appendingPathComponent("\(base).\($0)") }
            ?? dir.appendingPathComponent(base)
        let fm = FileManager.default
        // A re-download of the same track replaces the old copy — including one
        // stored under a different extension, which `allPaths` covers.
        for old in allPaths(base: base, in: dir) where fm.fileExists(atPath: old.path) {
            try? fm.removeItem(at: old)
        }
        do {
            try fm.moveItem(at: temp, to: dest)
            return dest.lastPathComponent
        } catch {
            return nil
        }
    }

    /// Resolve a filename recorded by `storeDownload(movingFrom:…)` back to a
    /// URL in the CURRENT container. Nil when the file is gone (a reinstall, or
    /// the user cleared downloads on another device and the row survived).
    public static func downloadURL(forFilename name: String) -> URL? {
        guard !name.isEmpty, let dir = pinnedDirectory() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public static func removeDownload(forKey key: String, variant: String) -> Bool {
        guard let dir = pinnedDirectory() else { return false }
        var removed = false
        for f in allPaths(base: filename(forKey: key, variant: variant), in: dir)
        where FileManager.default.fileExists(atPath: f.path) {
            if (try? FileManager.default.removeItem(at: f)) != nil { removed = true }
        }
        return removed
    }

    public static func downloadsSizeBytes() -> Int {
        guard let dir = pinnedDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    public static func clearDownloads() {
        guard let dir = pinnedDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

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

    // MARK: - File type
    //
    // **The extension is not cosmetic — without it nothing stored here plays.**
    // `filename(forKey:variant:)` is a bare SHA-256 hex string, and `AVURLAsset`
    // derives the media type from the path extension: handed the same bytes it
    // opens `x.m4a` and refuses the extensionless copy with `-12847 "This media
    // format is not supported"`. That is exactly what the on-device player logged
    // for every downloaded track. Streaming never showed it, because an HTTP
    // response carries `Content-Type` and a file on disk carries nothing — so the
    // tier broke precisely and only when the network was gone, which is the one
    // case it exists for.
    //
    // (AVFoundation does have an out-of-band MIME hint, but that key is not
    // declared in any public header — it lives in the .tbd only. An extension is
    // the supported way to say the same thing.)

    /// Extensions we may append, and therefore also the ones a lookup must try.
    static let knownExtensions = ["m4a", "flac", "mp3", "wav", "aiff", "ogg", "opus"]

    /// The extension matching these first bytes, or nil if we don't recognise
    /// them. Better no extension than a wrong one: a wrong type makes
    /// AVFoundation fail in a way that reads like a corrupt file.
    public static func fileExtension(forHeader head: Data) -> String? {
        let b = [UInt8](head)
        guard b.count >= 4 else { return nil }

        func matches(_ ascii: String, at offset: Int) -> Bool {
            let want = [UInt8](ascii.utf8)
            guard b.count >= offset + want.count else { return false }
            return Array(b[offset..<(offset + want.count)]) == want
        }

        if matches("fLaC", at: 0) { return "flac" }
        if matches("ftyp", at: 4) { return "m4a" }    // AAC/ALAC in an MP4 box
        if matches("RIFF", at: 0), matches("WAVE", at: 8) { return "wav" }
        if matches("FORM", at: 0), matches("AIFF", at: 8) { return "aiff" }
        if matches("OggS", at: 0) { return "ogg" }
        if matches("ID3", at: 0) { return "mp3" }
        // Bare MPEG frame sync (11 set bits) — an MP3 with no ID3 tag.
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }
        return nil
    }

    /// Same question, asked of a file already on disk.
    public static func fileExtension(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12) else { return nil }
        return fileExtension(forHeader: head)
    }

    /// Find `base`, `base.m4a`, `base.flac`, … in `dir`.
    ///
    /// A hit on the bare name is a file written before this fix; rename it to the
    /// extension its bytes call for, so it becomes playable without a
    /// re-download. Best-effort — if the rename fails we still return something,
    /// and the caller is no worse off than before.
    private static func locate(base: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        for ext in knownExtensions {
            let candidate = dir.appendingPathComponent("\(base).\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let bare = dir.appendingPathComponent(base)
        guard fm.fileExists(atPath: bare.path) else { return nil }
        guard let ext = fileExtension(ofFileAt: bare) else { return bare }
        let renamed = dir.appendingPathComponent("\(base).\(ext)")
        do { try fm.moveItem(at: bare, to: renamed); return renamed }
        catch { return bare }
    }

    /// Where to write `data` for `base`: with the extension its header calls for.
    private static func destination(base: String, in dir: URL, for data: Data) -> URL {
        guard let ext = fileExtension(forHeader: data.prefix(12)) else {
            return dir.appendingPathComponent(base)
        }
        return dir.appendingPathComponent("\(base).\(ext)")
    }

    /// Every path `base` could occupy — for deletion, which must not leave a
    /// second copy behind under another extension.
    private static func allPaths(base: String, in dir: URL) -> [URL] {
        [dir.appendingPathComponent(base)]
            + knownExtensions.map { dir.appendingPathComponent("\(base).\($0)") }
    }

    /// Stable filename for a (match key, variant) pair — hashed because match
    /// keys are free text ("artist|title") and would not survive as paths.
    static func filename(forKey key: String, variant: String) -> String {
        let digest = SHA256.hash(data: Data("\(key)|\(variant)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(forKey key: String, variant: String) -> URL? {
        guard let dir = directory() else { return nil }
        return locate(base: filename(forKey: key, variant: variant), in: dir)
    }

    /// The local file for this track: a pinned download first, then the LRU
    /// cache. Callers don't need to know which tier answered.
    public static func localFile(forKey key: String, variant: String) -> URL? {
        if let f = downloadedFile(forKey: key, variant: variant) { return f }
        // A download taken on Wi-Fi is stored as "orig". On mobile data the
        // player asks for the AAC variant and would otherwise miss its OWN
        // download and stream instead — burning data at the exact moment the
        // download existed to prevent it. Any pinned copy beats the network.
        if variant != "orig", let f = downloadedFile(forKey: key, variant: "orig") { return f }
        return cachedFile(forKey: key, variant: variant)
    }

    /// The cached file for this track, or nil on a miss. Touches the modification
    /// date on a hit so pruning keeps what you actually listen to (LRU-ish).
    public static func cachedFile(forKey key: String, variant: String) -> URL? {
        guard !key.isEmpty, let f = fileURL(forKey: key, variant: variant) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return f
    }

    public static func store(_ data: Data, forKey key: String, variant: String) {
        guard !data.isEmpty, !key.isEmpty, let dir = directory() else { return }
        let f = destination(base: filename(forKey: key, variant: variant), in: dir, for: data)
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
