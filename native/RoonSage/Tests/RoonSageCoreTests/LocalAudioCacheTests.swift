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
}
