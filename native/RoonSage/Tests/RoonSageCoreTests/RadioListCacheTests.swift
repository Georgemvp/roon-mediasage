import Foundation
import XCTest
@testable import RoonSageCore

/// The station list is a pure function of (category, library, feedback, rotation
/// bucket), and it used to be recomputed on every appearance of the Radio's
/// screen because the "loaded" flag lived in SwiftUI `@State`. These pin the
/// three properties that make caching it safe.
@MainActor
final class RadioListCacheTests: XCTestCase {

    private func radio(_ id: String) -> RoonClient.SonicRadio {
        RoonClient.SonicRadio(id: id, artist: id, imageKey: nil, trackCount: 5, seedIds: ["a"])
    }

    func testHitOnSameCategoryAndStamp() {
        let c = RadioListCache()
        c.store([radio("artist:x")], category: "artist", stamp: "2026-08-22-0")
        XCTAssertEqual(c.value(category: "artist", stamp: "2026-08-22-0")?.count, 1)
    }

    func testMissOnAnotherCategory() {
        let c = RadioListCache()
        c.store([radio("artist:x")], category: "artist", stamp: "2026-08-22-0")
        XCTAssertNil(c.value(category: "genre", stamp: "2026-08-22-0"))
    }

    func testMissOnANewRotationBucket() {
        // The whole point: a new day-part must produce a fresh list.
        let c = RadioListCache()
        c.store([radio("artist:x")], category: "artist", stamp: "2026-08-22-0")
        XCTAssertNil(c.value(category: "artist", stamp: "2026-08-22-1"))
    }

    func testOlderBucketsAreDroppedOnStore() {
        // Otherwise the dictionary grows by one entry per category per day-part,
        // forever, on a device that is never restarted.
        let c = RadioListCache()
        c.store([radio("a")], category: "artist", stamp: "2026-08-22-0")
        c.store([radio("b")], category: "genre", stamp: "2026-08-22-0")
        XCTAssertEqual(c.count, 2)
        c.store([radio("c")], category: "artist", stamp: "2026-08-22-1")
        XCTAssertEqual(c.count, 1, "entries uit een oudere bucket horen weg te vallen")
        XCTAssertNil(c.value(category: "genre", stamp: "2026-08-22-0"))
    }

    func testInvalidateClearsEverything() {
        let c = RadioListCache()
        c.store([radio("a")], category: "artist", stamp: "s")
        c.invalidate()
        XCTAssertEqual(c.count, 0)
    }

    func testEmptyListIsCachedAsAResult() {
        // "No stations in this category" is an answer too, and recomputing it is
        // just as expensive as recomputing a full one.
        let c = RadioListCache()
        c.store([], category: "sonic", stamp: "s")
        XCTAssertEqual(c.value(category: "sonic", stamp: "s")?.count, 0)
        XCTAssertNotNil(c.value(category: "sonic", stamp: "s"))
    }
}
