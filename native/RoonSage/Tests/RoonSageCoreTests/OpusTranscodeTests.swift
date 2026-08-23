import AVFoundation
import Foundation
import XCTest

@testable import AnalyzerCore
@testable import RoonSageCore

/// Fase 4 — Opus beside AAC on `/audio`.
final class OpusTranscodeTests: XCTestCase {

    // MARK: - Cache identity

    /// Two encodes of the same track at the same bitrate in different codecs are
    /// different files. If only the extension told them apart, an LRU prune of
    /// one could evict the other's name into a collision.
    func testCacheURLSeparatesCodecs() {
        let aac = AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 128, codec: .aac)
        let opus = AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 128, codec: .opus)
        XCTAssertNotEqual(aac, opus)
        XCTAssertNotEqual(aac.deletingPathExtension().lastPathComponent,
                          opus.deletingPathExtension().lastPathComponent,
                          "the hash itself must differ, not just the extension")
        XCTAssertEqual(aac.pathExtension, "m4a")
        XCTAssertEqual(opus.pathExtension, "ogg")
    }

    /// The default stays AAC, so every existing cached file keeps its name and
    /// the whole transcode cache is not invalidated by this change.
    func testCacheURLDefaultsToAACAndIsUnchanged() {
        XCTAssertEqual(AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 256),
                       AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 256, codec: .aac))
    }

    func testContentTypeFollowsTheCodec() {
        XCTAssertEqual(AudioTranscoder.Codec.aac.contentType, "audio/mp4")
        XCTAssertEqual(AudioTranscoder.Codec.opus.contentType, "audio/ogg")
        // And the streaming helper agrees for a file already on disk, so a
        // cached Ogg served from the LRU is labelled the same as a fresh one.
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/c/x.ogg"), "audio/ogg")
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/c/x.m4a"), "audio/mp4")
    }

    /// Ogg is an OUTPUT of the transcoder, never an input the walker serves —
    /// widening `allowedExtensions` would make `/audio` serve library files the
    /// analyser never analysed.
    func testOggIsNotAServableSourceExtension() {
        XCTAssertFalse(AudioStreaming.isAllowedExtension("ogg"))
        XCTAssertFalse(AudioStreaming.isAllowedExtension("opus"))
        XCTAssertTrue(AudioStreaming.isAllowedExtension("flac"))
    }

    // MARK: - The client policy

    func testQueryItemsCarryTheChosenCodec() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.string(forKey: "local_transcode_mode")
        let savedFormat = defaults.string(forKey: LocalTranscode.formatKey)
        defer {
            defaults.set(savedMode, forKey: "local_transcode_mode")
            defaults.set(savedFormat, forKey: LocalTranscode.formatKey)
        }

        LocalTranscode.mode = .always
        LocalTranscode.format = .aac
        XCTAssertEqual(LocalTranscode.queryItems().first { $0.name == "format" }?.value, "aac")

        LocalTranscode.format = .opus
        // Only when this OS can actually decode it — otherwise the policy is
        // required to degrade rather than request bytes it cannot play.
        XCTAssertEqual(LocalTranscode.queryItems().first { $0.name == "format" }?.value,
                       LocalTranscode.opusSupported ? "opus" : "aac")

        LocalTranscode.mode = .off
        XCTAssertTrue(LocalTranscode.queryItems().isEmpty)
    }

    /// A stored `opus` on a device that cannot play it must read back as `aac`.
    /// Settings sync between the Mac and the phone; they need not agree about
    /// what their OS can decode.
    func testStoredOpusDegradesWhenUnsupported() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: LocalTranscode.formatKey)
        defer { defaults.set(saved, forKey: LocalTranscode.formatKey) }

        defaults.set("opus", forKey: LocalTranscode.formatKey)
        XCTAssertEqual(LocalTranscode.format, LocalTranscode.opusSupported ? .opus : .aac)
    }

    /// The variant string is what the download/cache tier hashes files under, so
    /// an AAC copy and an Opus copy of one track must never collide.
    func testCacheVariantSeparatesCodecs() {
        let aac = LocalAudioCache.variant(for: [URLQueryItem(name: "format", value: "aac"),
                                                URLQueryItem(name: "bitrate", value: "128")])
        let opus = LocalAudioCache.variant(for: [URLQueryItem(name: "format", value: "opus"),
                                                 URLQueryItem(name: "bitrate", value: "128")])
        XCTAssertNotEqual(aac, opus)
    }

    // MARK: - The encoder itself

    /// Encode a real tone to Opus and check the result is something
    /// AVFoundation will actually open. Skipped where ffmpeg is not installed —
    /// which is the same condition under which the app falls back to AAC, so a
    /// skip here is the supported configuration, not a gap.
    func testOpusEncodeProducesAPlayableFile() async throws {
        AudioTranscoder.resetFFmpegPath()
        try XCTSkipIf(AudioTranscoder.ffmpegPath() == nil, "ffmpeg not installed")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("tone.wav")
        try Self.writeSineWAV(to: source, seconds: 2)
        let dest = dir.appendingPathComponent("out.ogg")

        XCTAssertTrue(AudioTranscoder.encodeOpus(source: source, dest: dest, kbps: 128))
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        XCTAssertGreaterThan(size, 0)
        // The bytes are Ogg — `LocalAudioCache` sniffs exactly this to decide
        // the extension a downloaded copy gets, and without the right one
        // AVURLAsset refuses the file.
        let head = try Data(contentsOf: dest).prefix(4)
        XCTAssertEqual(LocalAudioCache.fileExtension(forHeader: head), "ogg")

        let asset = AVURLAsset(url: dest)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    /// Asking for Opus where ffmpeg is missing has to yield AAC, not nil — the
    /// caller would otherwise serve the untranscoded FLAC over cellular, which
    /// is the exact bill this setting exists to avoid.
    ///
    /// The candidate list is emptied rather than skipped on, so this covers the
    /// no-ffmpeg configuration even on a machine that has ffmpeg installed —
    /// otherwise the fallback would only ever be exercised where it can't be.
    func testOpusFallsBackToAACWithoutFFmpeg() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opusfb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let realCandidates = AudioTranscoder.ffmpegCandidates
        defer {
            try? FileManager.default.removeItem(at: dir)
            AudioTranscoder.ffmpegCandidates = realCandidates
            AudioTranscoder.resetFFmpegPath()
        }

        let source = dir.appendingPathComponent("tone.wav")
        try Self.writeSineWAV(to: source, seconds: 1)

        AudioTranscoder.ffmpegCandidates = []
        AudioTranscoder.resetFFmpegPath()
        XCTAssertNil(AudioTranscoder.ffmpegPath())

        let result = await AudioTranscoder.shared.transcoded(sourcePath: source.path, kbps: 96, codec: .opus)
        XCTAssertEqual(result?.codec, .aac, "must degrade to AAC, never return nil")
        XCTAssertEqual(result?.url.pathExtension, "m4a")
    }

    // MARK: - Helpers

    /// A 44.1 kHz mono 16-bit WAV of a 440 Hz sine — a lossless source, so
    /// `shouldTranscode` says yes and ffmpeg has real audio to encode.
    private static func writeSineWAV(to url: URL, seconds: Int) throws {
        let rate = 44_100
        let frames = rate * seconds
        var pcm = Data()
        pcm.reserveCapacity(frames * 2)
        for i in 0..<frames {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 12_000)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }

        func le32(_ v: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
        func le16(_ v: Int) -> Data { Data((0..<2).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }

        var out = Data("RIFF".utf8)
        out += le32(36 + pcm.count)
        out += Data("WAVEfmt ".utf8)
        out += le32(16)             // PCM header size
        out += le16(1)              // format: PCM
        out += le16(1)              // channels
        out += le32(rate)
        out += le32(rate * 2)       // byte rate
        out += le16(2)              // block align
        out += le16(16)             // bits per sample
        out += Data("data".utf8)
        out += le32(pcm.count)
        out += pcm
        try out.write(to: url)
    }
}
