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
        LocalAudioCache.directoryOverride = tmp
    }

    override func tearDown() {
        LocalAudioCache.directoryOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private let key = "boards of canada|roygbiv"

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
