import CLAPEngine
import Foundation
import XCTest
@testable import RoonSageCore

/// Covers the on-disk cache of already-streamed audio: that a track round-trips,
/// that the transcode profile keeps variants apart, and that pruning evicts the
/// least-recently-used file rather than an arbitrary one.
final class LocalAudioCacheTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAudioCacheTests-\(UUID().uuidString)", isDirectory: true)
        LocalAudioCache.directoryOverride = tmp.appendingPathComponent("cache", isDirectory: true)
        LocalAudioCache.pinnedDirectoryOverride = tmp.appendingPathComponent("pinned", isDirectory: true)
    }

    override func tearDown() {
        LocalAudioCache.directoryOverride = nil
        LocalAudioCache.pinnedDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private let key = "boards of canada|roygbiv"

    // MARK: - Pinned downloads
    //
    // The whole point of a download is that it is NOT a cache: it has to survive
    // pruning and outlive whatever the LRU decides. These pin that promise.

    func testDownloadSurvivesAPruneThatWipesTheCache() throws {
        LocalAudioCache.store(Data(repeating: 0, count: 5000), forKey: "cached", variant: "orig")
        XCTAssertTrue(LocalAudioCache.storeDownload(
            Data(repeating: 0, count: 5000), forKey: "pinned", variant: "orig"))

        // A limit far below what is stored: the cache must give everything back.
        LocalAudioCache.prune(limitBytes: 0)

        XCTAssertNil(LocalAudioCache.cachedFile(forKey: "cached", variant: "orig"),
                     "cache should have been pruned")
        XCTAssertNotNil(LocalAudioCache.downloadedFile(forKey: "pinned", variant: "orig"),
                        "a download must never be pruned — that is what makes it a download")
    }

    func testLocalFilePrefersTheDownloadOverTheCache() throws {
        LocalAudioCache.store(Data([1]), forKey: key, variant: "orig")
        _ = LocalAudioCache.storeDownload(Data([2, 2]), forKey: key, variant: "orig")
        let resolved = try XCTUnwrap(LocalAudioCache.localFile(forKey: key, variant: "orig"))
        XCTAssertEqual(try? Data(contentsOf: resolved), Data([2, 2]))
    }

    func testLocalFileFallsBackToTheCache() throws {
        LocalAudioCache.store(Data([1]), forKey: key, variant: "orig")
        let resolved = try XCTUnwrap(LocalAudioCache.localFile(forKey: key, variant: "orig"))
        XCTAssertEqual(try? Data(contentsOf: resolved), Data([1]))
    }

    func testRemovingADownloadLeavesTheCacheCopyAlone() throws {
        LocalAudioCache.store(Data([1]), forKey: key, variant: "orig")
        _ = LocalAudioCache.storeDownload(Data([2, 2]), forKey: key, variant: "orig")
        LocalAudioCache.removeDownload(forKey: key, variant: "orig")
        XCTAssertNil(LocalAudioCache.downloadedFile(forKey: key, variant: "orig"))
        XCTAssertNotNil(LocalAudioCache.cachedFile(forKey: key, variant: "orig"))
    }

    func testDownloadSizeAndClear() {
        _ = LocalAudioCache.storeDownload(Data(repeating: 0, count: 700), forKey: "a", variant: "orig")
        _ = LocalAudioCache.storeDownload(Data(repeating: 0, count: 300), forKey: "b", variant: "orig")
        XCTAssertEqual(LocalAudioCache.downloadsSizeBytes(), 1000)
        LocalAudioCache.clearDownloads()
        XCTAssertEqual(LocalAudioCache.downloadsSizeBytes(), 0)
    }

    func testStoreThenReadRoundTrips() {
        XCTAssertNil(LocalAudioCache.cachedFile(forKey: key, variant: "orig"))
        LocalAudioCache.store(Data([1, 2, 3, 4]), forKey: key, variant: "orig")
        let hit = LocalAudioCache.cachedFile(forKey: key, variant: "orig")
        XCTAssertNotNil(hit)
        XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(hit)), Data([1, 2, 3, 4]))
    }

    /// The AAC copy and the original must not collide — otherwise switching the
    /// transcode policy would serve the wrong bytes from cache.
    func testVariantsDoNotCollide() {
        LocalAudioCache.store(Data([1]), forKey: key, variant: "orig")
        LocalAudioCache.store(Data([2, 2]), forKey: key, variant: "format=aac&bitrate=256")
        XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(
            LocalAudioCache.cachedFile(forKey: key, variant: "orig"))), Data([1]))
        XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(
            LocalAudioCache.cachedFile(forKey: key, variant: "format=aac&bitrate=256"))), Data([2, 2]))
    }

    func testVariantNameFollowsTheTranscodePolicy() {
        XCTAssertEqual(LocalAudioCache.variant(for: []), "orig")
        XCTAssertEqual(
            LocalAudioCache.variant(for: [URLQueryItem(name: "format", value: "aac"),
                                          URLQueryItem(name: "bitrate", value: "256")]),
            "format=aac&bitrate=256")
    }

    func testEmptyKeyOrDataIsIgnored() {
        LocalAudioCache.store(Data([1]), forKey: "", variant: "orig")
        LocalAudioCache.store(Data(), forKey: key, variant: "orig")
        XCTAssertNil(LocalAudioCache.cachedFile(forKey: "", variant: "orig"))
        XCTAssertNil(LocalAudioCache.cachedFile(forKey: key, variant: "orig"))
    }

    func testPruneEvictsLeastRecentlyUsedFirst() throws {
        LocalAudioCache.store(Data(repeating: 0, count: 1000), forKey: "old", variant: "orig")
        LocalAudioCache.store(Data(repeating: 0, count: 1000), forKey: "new", variant: "orig")

        // Age the "old" entry explicitly — mtime is what pruning sorts on, and
        // two writes in the same millisecond would otherwise tie.
        let oldFile = try XCTUnwrap(LocalAudioCache.cachedFile(forKey: "old", variant: "orig"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: oldFile.path)

        LocalAudioCache.prune(limitBytes: 1500)

        XCTAssertNil(LocalAudioCache.cachedFile(forKey: "old", variant: "orig"))
        XCTAssertNotNil(LocalAudioCache.cachedFile(forKey: "new", variant: "orig"))
    }

    func testPruneUnderTheLimitKeepsEverything() {
        LocalAudioCache.store(Data(repeating: 0, count: 100), forKey: "a", variant: "orig")
        LocalAudioCache.store(Data(repeating: 0, count: 100), forKey: "b", variant: "orig")
        LocalAudioCache.prune(limitBytes: 10_000)
        XCTAssertNotNil(LocalAudioCache.cachedFile(forKey: "a", variant: "orig"))
        XCTAssertNotNil(LocalAudioCache.cachedFile(forKey: "b", variant: "orig"))
    }

    func testSizeAndClear() {
        LocalAudioCache.store(Data(repeating: 0, count: 500), forKey: "a", variant: "orig")
        LocalAudioCache.store(Data(repeating: 0, count: 300), forKey: "b", variant: "orig")
        XCTAssertEqual(LocalAudioCache.sizeBytes(), 800)
        LocalAudioCache.clear()
        XCTAssertEqual(LocalAudioCache.sizeBytes(), 0)
        XCTAssertNil(LocalAudioCache.cachedFile(forKey: "a", variant: "orig"))
    }

    // MARK: - File type
    //
    // These files are named by SHA-256. `AVURLAsset` reads the media type off
    // the path extension and will not sniff content: handed the same bytes it
    // opens "x.m4a" and refuses the extensionless copy with -12847. So without
    // an extension NOTHING in either tier can be played — which is why offline
    // playback was broken while streaming the same track was fine (an HTTP
    // response carries Content-Type; a file does not).

    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testRecognisesTheFormatsWeStore() {
        let cases: [(String, [UInt8])] = [
            ("flac", ascii("fLaC") + [0, 0, 0, 34]),
            // "ftyp" sits at offset 4, behind the box length — the only magic
            // that isn't at the start of the file.
            ("m4a",  [0, 0, 0, 0x20] + ascii("ftypM4A ")),
            ("wav",  ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE")),
            ("aiff", ascii("FORM") + [0, 0, 0, 0] + ascii("AIFF")),
            ("ogg",  ascii("OggS") + [0, 2, 0, 0]),
            ("mp3",  ascii("ID3") + [3, 0, 0, 0, 0, 0, 0]),
            ("mp3",  [0xFF, 0xFB, 0x90, 0x00]),   // frame sync, no ID3 tag
        ]
        for (want, bytes) in cases {
            XCTAssertEqual(LocalAudioCache.fileExtension(forHeader: Data(bytes)), want,
                           "header \(bytes.prefix(4)) hoort \(want) te geven")
        }
    }

    func testUnrecognisedHeaderGetsNoExtension() {
        // Better none than a wrong one: a wrong type makes AVFoundation fail in
        // a way that reads like a corrupt file.
        XCTAssertNil(LocalAudioCache.fileExtension(forHeader: Data(ascii("not audio at all"))))
        XCTAssertNil(LocalAudioCache.fileExtension(forHeader: Data([0x00, 0x01])))
        // RIFF alone isn't enough — RIFF/AVI is not audio.
        XCTAssertNil(LocalAudioCache.fileExtension(
            forHeader: Data(ascii("RIFF") + [0, 0, 0, 0] + ascii("AVI "))))
    }

    private var m4a: Data { Data([0, 0, 0, 0x20] + ascii("ftypM4A ") + [0, 0, 0, 0]) }

    func testDownloadLandsOnAPlayableName() {
        XCTAssertTrue(LocalAudioCache.storeDownload(m4a, forKey: key, variant: "orig"))
        let f = LocalAudioCache.downloadedFile(forKey: key, variant: "orig")
        XCTAssertEqual(f?.pathExtension, "m4a",
                       "zonder extensie weigert AVURLAsset het bestand")
    }

    func testCachedFileLandsOnAPlayableName() {
        LocalAudioCache.store(m4a, forKey: key, variant: "orig")
        XCTAssertEqual(LocalAudioCache.cachedFile(forKey: key, variant: "orig")?.pathExtension, "m4a")
    }

    func testUnknownFormatStillRoundTripsWithoutExtension() {
        // We must not lose data we can't name; playback then behaves exactly as
        // it did before this fix rather than worse.
        let blob = Data(ascii("iets onbekends maar wel bytes"))
        XCTAssertTrue(LocalAudioCache.storeDownload(blob, forKey: key, variant: "orig"))
        let f = LocalAudioCache.downloadedFile(forKey: key, variant: "orig")
        XCTAssertEqual(f?.pathExtension, "")
        XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(f)), blob)
    }

    func testExistingExtensionlessFileIsAdoptedAndRenamed() {
        // The migration that matters: everything already downloaded on a phone
        // sits under a bare hash. It must become playable without re-downloading.
        let dir = LocalAudioCache.pinnedDirectoryOverride!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bare = dir.appendingPathComponent(
            LocalAudioCache.filename(forKey: key, variant: "orig"))
        try? m4a.write(to: bare)

        let found = LocalAudioCache.downloadedFile(forKey: key, variant: "orig")
        XCTAssertEqual(found?.pathExtension, "m4a", "oude download is niet hernoemd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.path),
                       "de oude naam moet weg zijn, niet gedupliceerd")
        XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(found)), m4a)
    }

    func testRemoveDownloadLeavesNoCopyBehind() {
        LocalAudioCache.storeDownload(m4a, forKey: key, variant: "orig")
        XCTAssertTrue(LocalAudioCache.removeDownload(forKey: key, variant: "orig"))
        XCTAssertNil(LocalAudioCache.downloadedFile(forKey: key, variant: "orig"))
    }

}
