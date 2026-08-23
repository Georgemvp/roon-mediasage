@testable import AnalyzerCore
import AudioAnalysis
import Foundation
import XCTest

@testable import RoonSageCore

/// Fase 2 — the lyrics the library already owns: `.lrc` sidecars and embedded
/// ID3 frames, harvested by the analyser instead of fetched from LRCLIB.
final class LyricsSourceTests: XCTestCase {

    // MARK: - LRCParser is the one parser

    /// `LyricsService.parseLRC` must not grow a second implementation: it is the
    /// client's mapping onto `LRCParser`, and the two drifting apart is exactly
    /// how a sidecar parses in the analyser but not in the app.
    func testClientParserForwardsToTheSharedOne() {
        let lrc = "[00:12.00]first\n[01:05.50]second"
        let viaClient = LyricsService.parseLRC(lrc)
        let viaShared = LRCParser.parse(lrc)
        XCTAssertEqual(viaClient.count, viaShared.count)
        for (a, b) in zip(viaClient, viaShared) {
            XCTAssertEqual(a.time, b.time)
            XCTAssertEqual(a.text, b.text)
        }
    }

    func testPlainTextDropsTimestampsAndBlankLines() {
        let lrc = "[ar:Someone]\n[00:01.00]one\n[00:02.00]\n[00:03.00]three"
        XCTAssertEqual(LRCParser.plainText(lrc), "one\nthree")
    }

    // MARK: - SYLT

    /// Build a minimal ID3v2 `SYLT` payload the way a tagger writes one.
    private func syltPayload(encoding: UInt8, timestampFormat: UInt8,
                             entries: [(ms: UInt32, text: String)]) -> Data {
        var bytes: [UInt8] = [encoding]
        bytes += Array("eng".utf8)
        bytes.append(timestampFormat)
        bytes.append(1)                 // content type: lyrics
        bytes.append(0)                 // empty content descriptor + terminator
        for e in entries {
            bytes += Array(e.text.utf8)
            bytes.append(0)
            bytes += [UInt8((e.ms >> 24) & 0xFF), UInt8((e.ms >> 16) & 0xFF),
                      UInt8((e.ms >> 8) & 0xFF), UInt8(e.ms & 0xFF)]
        }
        return Data(bytes)
    }

    func testSYLTDecodesMillisecondTimestamps() {
        let data = syltPayload(encoding: 3, timestampFormat: 2,
                               entries: [(1000, "Hello"), (2500, "World")])
        let lines = SYLTParser.parse(data)
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?[0].time, 1.0)
        XCTAssertEqual(lines?[0].text, "Hello")
        XCTAssertEqual(lines?[1].time, 2.5)
        XCTAssertEqual(lines?[1].text, "World")
    }

    /// Timestamp format 1 counts MPEG audio frames, which cannot be turned into
    /// seconds without the file's frame rate. Guessing would desynchronise the
    /// whole track silently — refusing lets the caller fall through to plain
    /// lyrics, which is honest.
    func testSYLTRefusesMPEGFrameTimestamps() {
        let data = syltPayload(encoding: 3, timestampFormat: 1, entries: [(1000, "Hello")])
        XCTAssertNil(SYLTParser.parse(data))
    }

    func testSYLTRefusesTruncatedAndUnknownEncodings() {
        XCTAssertNil(SYLTParser.parse(Data([3, 0x65, 0x6E])))          // shorter than the header
        XCTAssertNil(SYLTParser.parse(syltPayload(encoding: 9, timestampFormat: 2,
                                                  entries: [(0, "x")])))
    }

    /// UTF-16 lines end in TWO NUL bytes, and the high byte of an ASCII
    /// character is itself a NUL — scanning byte-by-byte would cut every line in
    /// half at its first character.
    func testSYLTHandlesUTF16Terminators() {
        var bytes: [UInt8] = [2]                    // UTF-16 big-endian, no BOM
        bytes += Array("eng".utf8)
        bytes += [2, 1]
        bytes += [0, 0]                             // empty descriptor, 2-byte terminator
        for unit in Array("Hi".utf16) {
            bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)]
        }
        bytes += [0, 0]
        bytes += [0, 0, 0x03, 0xE8]                 // 1000 ms
        let lines = SYLTParser.parse(Data(bytes))
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?[0].text, "Hi")
        XCTAssertEqual(lines?[0].time, 1.0)
    }

    // MARK: - Sidecar resolution

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSidecarMatchesTheTrackBasenameCaseInsensitively() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("Some Song.flac")
        try Data().write(to: audio)
        try "[00:01.00]hi".write(to: dir.appendingPathComponent("SOME SONG.LRC"),
                                atomically: true, encoding: .utf8)

        let resolved = LyricsProvider.sidecarLyrics(besideFile: audio)
        XCTAssertEqual(resolved?.source, "lrc-sidecar")
        XCTAssertEqual(resolved?.synced?.count, 1)
        XCTAssertEqual(resolved?.plain, "hi")
    }

    /// A different song's `.lrc` in the same folder is not this song's lyrics.
    /// `ArtworkProvider` can take any `cover.jpg` in a folder because an album
    /// has one cover; lyrics are per track.
    func testSidecarIgnoresOtherTracksInTheSameFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("Track A.flac")
        try Data().write(to: audio)
        try "[00:01.00]wrong".write(to: dir.appendingPathComponent("Track B.lrc"),
                                    atomically: true, encoding: .utf8)
        XCTAssertNil(LyricsProvider.sidecarLyrics(besideFile: audio))
    }

    /// A `.lrc` with no timestamps is still lyrics — plenty of taggers write
    /// one. Dropping it because it doesn't parse as timed would throw away
    /// words we are holding.
    func testUntimedSidecarIsKeptAsPlainText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("Song.mp3")
        try Data().write(to: audio)
        try "just\nthe words\n".write(to: dir.appendingPathComponent("Song.lrc"),
                                      atomically: true, encoding: .utf8)

        let resolved = LyricsProvider.sidecarLyrics(besideFile: audio)
        XCTAssertNil(resolved?.synced)
        XCTAssertEqual(resolved?.plain, "just\nthe words")
    }

    // MARK: - The /lyrics wire shape

    /// The analyser hand-encodes this body because it cannot import the
    /// `Lyrics` type it has to match. That makes the key names a contract with
    /// nothing but this test holding it — decode it with the REAL client type.
    func testEndpointBodyDecodesAsTheClientLyricsType() throws {
        let resolved = LyricsProvider.Resolved(
            plain: "one\ntwo",
            synced: [LRCParser.Line(time: 1, text: "one"), LRCParser.Line(time: 2, text: "two")],
            source: "lrc-sidecar")
        let body = LyricsProvider.jsonBody(resolved)

        let decoded = try JSONDecoder().decode(Lyrics.self, from: body)
        XCTAssertEqual(decoded.plain, "one\ntwo")
        XCTAssertEqual(decoded.synced?.count, 2)
        XCTAssertEqual(decoded.synced?[1].time, 2)
        XCTAssertEqual(decoded.synced?[1].text, "two")
        XCTAssertFalse(decoded.isInstrumental)
        XCTAssertTrue(decoded.hasContent)
    }

    /// "No lyrics" is the literal `null`, which the client decodes to nil —
    /// distinct from an empty object, which would decode to a content-less
    /// `Lyrics` and stop the LRCLIB fallback.
    func testEndpointBodyForNothingIsNull() throws {
        XCTAssertEqual(String(data: LyricsProvider.jsonBody(nil), encoding: .utf8), "null")
        let empty = LyricsProvider.Resolved(plain: nil, synced: [], source: "uslt")
        XCTAssertEqual(String(data: LyricsProvider.jsonBody(empty), encoding: .utf8), "null")
        XCTAssertNil(try JSONDecoder().decode(Lyrics?.self, from: LyricsProvider.jsonBody(nil)))
    }

    // MARK: - Store round-trip

    func testStoreRecordsNegativesSoTheBackfillConverges() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-store-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try FeatureStore(path: path)

        // Never checked → nil.
        XCTAssertNil(store.lyrics(matchKey: "a|b|c"))

        // Checked, found nothing → a row exists with no content, so the backfill
        // does not read the file again.
        try store.setLyrics(matchKey: "a|b|c", lyrics: nil, checkedAt: "2026-08-23T00:00:00Z")
        let negative = store.lyrics(matchKey: "a|b|c")
        XCTAssertNotNil(negative)
        XCTAssertFalse(negative?.hasContent ?? true)

        let found = LyricsProvider.Resolved(
            plain: "words", synced: [LRCParser.Line(time: 3, text: "words")], source: "sylt")
        try store.setLyrics(matchKey: "d|e|f", lyrics: found, checkedAt: "2026-08-23T00:00:00Z")
        let back = store.lyrics(matchKey: "d|e|f")
        XCTAssertEqual(back?.plain, "words")
        XCTAssertEqual(back?.synced?.first?.time, 3)
        XCTAssertEqual(back?.source, "sylt")
        XCTAssertEqual(store.lyricsCounts().withLyrics, 1)
        XCTAssertEqual(store.lyricsCounts().checked, 2)
    }
}
