import AVFoundation
import Foundation

/// On-the-fly transcoding for the `/audio` endpoint (LMS-audit §1.2):
/// streaming FLAC over ZeroTier on cellular is heavy and expensive, so remote
/// clients can request `format=aac&bitrate=<kbps>` (an M4A) or
/// `format=opus&bitrate=<kbps>` (Ogg/Opus) instead.
///
/// Design choices (deliberately different from LMS's ffmpeg pipe):
///  - **Whole-file to a disk cache, then serve with Range.** AVPlayer seeks by
///    Range requests; a fully-written file with a real Content-Length seeks
///    natively, so no `-ss` offset re-request protocol is needed.
///  - **Smart no-op** (`shouldTranscode`): an already-lossy source at or below
///    the requested bitrate is served as-is — never burn CPU to make audio
///    worse. Lossless sources always transcode when asked.
///  - **Single-flight per (file, bitrate, codec)** so a scrubbing client doesn't
///    kick off parallel encodes of the same track; LRU cache capped at 500 MB.
///
/// The two codecs take different routes, and not by accident. AAC goes through
/// `AVAssetWriter`, which is in-process and always available. Opus has no
/// AVFoundation *encoder* on macOS, so it shells out to `ffmpeg` — which means
/// Opus is only offered when ffmpeg is actually installed, and a request for it
/// on a machine without one degrades to AAC rather than failing.
public actor AudioTranscoder {
    public static let shared = AudioTranscoder()

    /// What the client asked for. `aac` is the floor: every Apple client can
    /// decode it, so it is what an unavailable codec falls back to.
    public enum Codec: String, Sendable, CaseIterable {
        case aac
        case opus

        var fileExtension: String { self == .aac ? "m4a" : "ogg" }
        /// What `/audio` must send back, so the client's decoder is told the
        /// truth about the bytes.
        public var contentType: String { self == .aac ? "audio/mp4" : "audio/ogg" }
    }

    static let lossyExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "opus"]
    static let cacheCap: Int64 = 500 * 1024 * 1024

    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// Whether a transcode is worth it: lossless always; lossy only when its
    /// estimated bitrate meaningfully exceeds the request (15% headroom so a
    /// 260 kbps MP3 isn't "transcoded" to 256).
    public static func shouldTranscode(sourcePath: String, requestedKbps: Int) -> Bool {
        let ext = (sourcePath as NSString).pathExtension.lowercased()
        guard lossyExtensions.contains(ext) else { return true }   // lossless → yes
        guard let size = try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? Int64,
              size > 0 else { return false }
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 1 else { return false }  // unknown → serve original
        let estKbps = Double(size) * 8 / seconds / 1000
        return estKbps > Double(requestedKbps) * 1.15
    }

    /// Cached (or freshly encoded) file for this source, bitrate and codec, plus
    /// the codec that was actually used — which is not always the one asked for
    /// (Opus without ffmpeg falls back to AAC). `nil` = encode failed; callers
    /// fall back to the original file.
    ///
    /// Returning the codec rather than letting the caller assume is the point:
    /// serving Ogg bytes under `audio/mp4` produces a file the client refuses
    /// with a decode error that looks like a corrupt download.
    public func transcoded(sourcePath: String, kbps: Int, codec: Codec = .aac) async -> (url: URL, codec: Codec)? {
        let effective: Codec = (codec == .opus && Self.ffmpegPath() == nil) ? .aac : codec
        guard let url = await encodeOrCached(sourcePath: sourcePath, kbps: kbps, codec: effective) else {
            return nil
        }
        return (url, effective)
    }

    private func encodeOrCached(sourcePath: String, kbps: Int, codec: Codec) async -> URL? {
        let dest = Self.cacheURL(sourcePath: sourcePath, kbps: kbps, codec: codec)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Touch for LRU.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        let key = dest.lastPathComponent
        if let running = inFlight[key] { return await running.value }
        let task = Task<URL?, Never>.detached(priority: .userInitiated) {
            let source = URL(fileURLWithPath: sourcePath)
            let ok = codec == .aac
                ? await Self.encode(source: source, dest: dest, kbps: kbps)
                : Self.encodeOpus(source: source, dest: dest, kbps: kbps)
            if ok { Self.pruneCache() }
            return ok ? dest : nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Cache

    static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("roonsage-transcode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(sourcePath: String, kbps: Int, codec: Codec = .aac) -> URL {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.modificationDate] as? Date)
            .map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        var h: UInt64 = 0xcbf29ce484222325
        // The codec is part of the key, not just the extension: two encodes of
        // the same track at the same bitrate are different files, and hashing
        // only the extension apart would let a prune of one evict the other's
        // name into a collision.
        for b in "\(sourcePath)\u{1f}\(mtime)\u{1f}\(kbps)\u{1f}\(codec.rawValue)".utf8 {
            h ^= UInt64(b); h &*= 0x100000001b3
        }
        return cacheDir().appendingPathComponent(String(h, radix: 36) + "." + codec.fileExtension)
    }

    /// LRU-ish prune: drop oldest-touched files until under the cap.
    static func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir(), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { url in
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = vals.fileSize else { return nil }
            return (url, Int64(size), vals.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > cacheCap else { return }
        entries.sort { $0.date < $1.date }
        for e in entries {
            guard total > cacheCap else { break }
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }

    // MARK: - Encoding: Opus (ffmpeg)
    //
    // AVFoundation can DECODE Opus but ships no encoder for it, so this is the
    // one path that leaves the process. `ffmpeg` is treated as optional
    // equipment: absent, `transcoded` quietly serves AAC instead, and the
    // client never learns the difference beyond the Content-Type it is told.

    /// Where `ffmpeg` lives, cached for the process. Homebrew first (this is
    /// where it is on the Mac mini that runs the server-of-record), then the
    /// Intel Homebrew prefix, then the system path.
    ///
    /// An absolute path, never a bare `ffmpeg` handed to a shell: the analyser
    /// runs under launchd with a minimal PATH, and resolving through `$PATH`
    /// both fails there and is the shape of an injection bug.
    nonisolated(unsafe) private static var cachedFFmpeg: String??
    private static let ffmpegLock = NSLock()

    /// A `var` only so a test can empty it and exercise the no-ffmpeg fallback,
    /// which is a supported configuration and therefore has to be covered on a
    /// machine that does have ffmpeg installed.
    nonisolated(unsafe) static var ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func ffmpegPath() -> String? {
        ffmpegLock.lock(); defer { ffmpegLock.unlock() }
        if let cached = cachedFFmpeg { return cached }
        let found = ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedFFmpeg = found
        return found
    }

    /// Forget the resolved path — for tests, and so installing ffmpeg does not
    /// need an analyser restart to take effect on the next launch's first miss.
    static func resetFFmpegPath() {
        ffmpegLock.lock(); cachedFFmpeg = nil; ffmpegLock.unlock()
    }

    /// Encode to Ogg/Opus. Synchronous — it already runs on a detached task, and
    /// `Process.waitUntilExit()` is the honest way to wait for a child.
    static func encodeOpus(source: URL, dest: URL, kbps: Int) -> Bool {
        guard let ffmpeg = ffmpegPath() else { return false }
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin",            // never block waiting on a terminal that isn't there
            "-v", "error",
            "-i", source.path,
            "-vn",                 // drop embedded cover art: it is not audio, and
                                   // an Ogg stream with a video track confuses players
            "-map", "0:a:0",       // first audio stream only
            "-c:a", "libopus",
            "-b:a", "\(max(32, min(320, kbps)))k",
            // Opus is defined at 48 kHz; libopus resamples anything else itself,
            // but saying so keeps the output predictable across sources.
            "-ar", "48000",
            "-f", "ogg",
            "-y", tmp.path,
        ]
        // Discard the child's output rather than inheriting: a full pipe buffer
        // would deadlock the encode, and there is nothing here worth logging per
        // track.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        process.waitUntilExit()

        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard process.terminationStatus == 0, size > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - Encoding (AVAssetReader → AVAssetWriter, PCM → AAC)

    /// Below this, HE-AAC beats plain AAC-LC by a wide margin; above it, LC is
    /// the better encoder and SBR just costs you.
    static let heAACCeiling = 112

    /// The AAC flavour to ask for at this bitrate.
    ///
    /// AAC-LC falls apart under ~112 kbps; HE-AAC (LC + spectral band
    /// replication) stays usable down to ~64. Opus would be better still, but
    /// `AVPlayer` cannot decode it — so the codec is fixed and the flavour is
    /// the only lever we actually have.
    static func aacFormat(forKbps kbps: Int) -> AudioFormatID {
        kbps < heAACCeiling ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC
    }

    static func encode(source: URL, dest: URL, kbps: Int) async -> Bool {
        // HE-AAC is the better encoder low down, but AVAssetWriter is picky about
        // it (sample-rate and channel constraints vary by platform). Try it, and
        // fall back to LC rather than serving nothing.
        if aacFormat(forKbps: kbps) == kAudioFormatMPEG4AAC_HE,
           await encode(source: source, dest: dest, kbps: kbps, format: kAudioFormatMPEG4AAC_HE) {
            return true
        }
        return await encode(source: source, dest: dest, kbps: kbps, format: kAudioFormatMPEG4AAC)
    }

    private static func encode(source: URL, dest: URL, kbps: Int, format: AudioFormatID) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let srcTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .m4a) else { return false }

        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM]
        let readerOutput = AVAssetReaderTrackOutput(track: srcTrack, outputSettings: pcm)
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        let aac: [String: Any] = [
            AVFormatIDKey: format,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: max(32, min(320, kbps)) * 1000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "roonsage.transcode")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        reader.cancelReading()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            return false
        }
    }
}
