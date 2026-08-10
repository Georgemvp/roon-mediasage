@testable import RoonSageCore
import XCTest

/// Covers the pure queue arithmetic behind the on-device player's insert-next /
/// append / remove / reorder verbs — specifically that the index of the playing
/// track follows it through every mutation, since getting that wrong silently
/// skips or restarts a song.
final class LocalQueueTests: XCTestCase {
    private let q = ["0", "1", "2", "3", "4"]

    // MARK: - followerIndex (what gets pre-enqueued for gapless)

    func testFollowerIsTheNextTrack() {
        XCTAssertEqual(LocalQueue.followerIndex(after: 1, count: 5, loopMode: "disabled"), 2)
    }

    func testFollowerAtTheEndIsNilWithoutRepeat() {
        XCTAssertNil(LocalQueue.followerIndex(after: 4, count: 5, loopMode: "disabled"))
    }

    func testFollowerWrapsWhenLooping() {
        XCTAssertEqual(LocalQueue.followerIndex(after: 4, count: 5, loopMode: "loop"), 0)
    }

    /// loop_one pre-enqueues the SAME track, so repeating one song is gapless
    /// rather than a reload at every boundary.
    func testFollowerRepeatsItselfOnLoopOne() {
        XCTAssertEqual(LocalQueue.followerIndex(after: 2, count: 5, loopMode: "loop_one"), 2)
        XCTAssertEqual(LocalQueue.followerIndex(after: 4, count: 5, loopMode: "loop_one"), 4)
    }

    func testFollowerOfAnEmptyOrOutOfRangeQueueIsNil() {
        XCTAssertNil(LocalQueue.followerIndex(after: 0, count: 0, loopMode: "loop"))
        XCTAssertNil(LocalQueue.followerIndex(after: 7, count: 5, loopMode: "loop"))
        XCTAssertNil(LocalQueue.followerIndex(after: -1, count: 5, loopMode: "loop"))
    }

    func testSingleTrackQueueFollowsOnlyWhenRepeating() {
        XCTAssertNil(LocalQueue.followerIndex(after: 0, count: 1, loopMode: "disabled"))
        XCTAssertEqual(LocalQueue.followerIndex(after: 0, count: 1, loopMode: "loop"), 0)
    }

    // MARK: - insert

    func testInsertNextGoesAfterThePlayingTrack() {
        let out = LocalQueue.insert(["a", "b"], into: q, playingAt: 1, next: true)
        XCTAssertEqual(out, ["0", "1", "a", "b", "2", "3", "4"])
    }

    func testInsertLastGoesToTheEnd() {
        let out = LocalQueue.insert(["a"], into: q, playingAt: 1, next: false)
        XCTAssertEqual(out, ["0", "1", "2", "3", "4", "a"])
    }

    func testInsertNextWhilePlayingTheLastTrackAppends() {
        let out = LocalQueue.insert(["a"], into: q, playingAt: 4, next: true)
        XCTAssertEqual(out, ["0", "1", "2", "3", "4", "a"])
    }

    func testInsertIntoEmptyQueueBecomesTheQueue() {
        XCTAssertEqual(LocalQueue.insert(["a", "b"], into: [], playingAt: 0, next: true), ["a", "b"])
        XCTAssertEqual(LocalQueue.insert(["a", "b"], into: [], playingAt: 0, next: false), ["a", "b"])
    }

    func testInsertNothingIsANoOp() {
        XCTAssertEqual(LocalQueue.insert([], into: q, playingAt: 2, next: true), q)
    }

    // MARK: - remove

    func testRemoveBeforeCurrentShiftsTheIndexDown() {
        let u = LocalQueue.remove(atOffsets: IndexSet([0, 1]), from: q, playingAt: 3)
        XCTAssertEqual(u.items, ["2", "3", "4"])
        XCTAssertEqual(u.index, 1)          // still "3"
        XCTAssertFalse(u.currentRemoved)
    }

    func testRemoveAfterCurrentLeavesTheIndexAlone() {
        let u = LocalQueue.remove(atOffsets: IndexSet([3, 4]), from: q, playingAt: 1)
        XCTAssertEqual(u.items, ["0", "1", "2"])
        XCTAssertEqual(u.index, 1)
        XCTAssertFalse(u.currentRemoved)
    }

    func testRemovingCurrentLandsOnTheNextSurvivor() {
        let u = LocalQueue.remove(atOffsets: IndexSet([2]), from: q, playingAt: 2)
        XCTAssertEqual(u.items, ["0", "1", "3", "4"])
        XCTAssertEqual(u.index, 2)          // "3" — the queue moved up
        XCTAssertTrue(u.currentRemoved)
    }

    func testRemovingCurrentAtTheTailLandsOnTheNewLast() {
        let u = LocalQueue.remove(atOffsets: IndexSet([3, 4]), from: q, playingAt: 4)
        XCTAssertEqual(u.items, ["0", "1", "2"])
        XCTAssertEqual(u.index, 2)
        XCTAssertTrue(u.currentRemoved)
    }

    func testRemovingEverythingEmptiesTheQueue() {
        let u = LocalQueue.remove(atOffsets: IndexSet(0..<5), from: q, playingAt: 2)
        XCTAssertTrue(u.items.isEmpty)
        XCTAssertEqual(u.index, 0)
        XCTAssertTrue(u.currentRemoved)
    }

    // MARK: - move

    /// Pins `LocalQueue.move` to SwiftUI's `Array.move(fromOffsets:toOffset:)`,
    /// whose `toOffset` is an index into the ORIGINAL array. These six cases were
    /// captured from the real implementation; if Apple's semantics ever drift,
    /// this is the test that catches it.
    func testMoveMatchesSwiftUISemantics() {
        let cases: [(IndexSet, Int, [String])] = [
            (IndexSet([0]), 3, ["1", "2", "0", "3", "4"]),
            (IndexSet([3]), 1, ["0", "3", "1", "2", "4"]),
            (IndexSet([0, 1]), 4, ["2", "3", "0", "1", "4"]),
            (IndexSet([1, 3]), 0, ["1", "3", "0", "2", "4"]),
            (IndexSet([4]), 0, ["4", "0", "1", "2", "3"]),
            (IndexSet([1]), 5, ["0", "2", "3", "4", "1"]),
        ]
        for (offsets, destination, expected) in cases {
            let u = LocalQueue.move(fromOffsets: offsets, toOffset: destination, in: q, playingAt: 0)
            XCTAssertEqual(u.items, expected, "move \(offsets.map { $0 }) -> \(destination)")
            XCTAssertFalse(u.currentRemoved)
        }
    }

    func testMoveFollowsThePlayingTrack() {
        // Drag "1" (playing) down to the end: the index must follow it, not stay.
        let u = LocalQueue.move(fromOffsets: IndexSet([1]), toOffset: 5, in: q, playingAt: 1)
        XCTAssertEqual(u.items, ["0", "2", "3", "4", "1"])
        XCTAssertEqual(u.index, 4)
    }

    func testMovingAroundThePlayingTrackKeepsItPlaying() {
        // Drag "4" above "2" while "2" is playing — "2" shifts down one slot.
        let u = LocalQueue.move(fromOffsets: IndexSet([4]), toOffset: 2, in: q, playingAt: 2)
        XCTAssertEqual(u.items, ["0", "1", "4", "2", "3"])
        XCTAssertEqual(u.index, 3)
        XCTAssertFalse(u.currentRemoved)
    }

    func testOutOfRangeMoveIsANoOp() {
        let u = LocalQueue.move(fromOffsets: IndexSet([9]), toOffset: 2, in: q, playingAt: 1)
        XCTAssertEqual(u.items, q)
        XCTAssertEqual(u.index, 1)
    }
}
