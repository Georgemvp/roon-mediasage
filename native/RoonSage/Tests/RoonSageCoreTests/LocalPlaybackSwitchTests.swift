import XCTest
@testable import RoonSageCore

/// Switching tracks WHILE something is already playing.
///
/// `load` empties the player before refilling it, and `removeAllItems()` drives
/// `currentItem` to nil synchronously — which fires the current-item observer,
/// which read nil as "the queue ran dry" and called `stop()`, emptying `queue`
/// out from under the rest of `load`. The next line subscripted it and the app
/// died. Fresh playback never hit it (an empty player's `currentItem` doesn't
/// change), so it only bit on jump / Journey / Play this mix — always while
/// music was playing.
///
/// These exercise that exact order against the real `AVQueuePlayer`.
@MainActor
final class LocalPlaybackSwitchTests: XCTestCase {

    /// A stream base that can never load. The bug is in the bookkeeping around
    /// item swapping, which happens long before any byte is fetched.
    private let deadBase = "http://127.0.0.1:1"

    private func track(_ id: String) -> LocalPlaybackController.Track {
        .init(id: id, title: "Track \(id)", artist: "Artist", album: "Album",
              imageKey: nil, durationSec: 180)
    }

    override func tearDown() {
        LocalPlaybackController.shared.stop()
        super.tearDown()
    }

    func testJumpingWhilePlayingKeepsTheQueue() {
        let lp = LocalPlaybackController.shared
        lp.play([track("a"), track("b"), track("c")], streamBase: deadBase, token: nil)
        XCTAssertEqual(lp.queue.count, 3)
        XCTAssertTrue(lp.isEngaged)

        // The crash: this is the first load that empties a NON-empty player.
        lp.jump(to: 2)

        XCTAssertEqual(lp.queue.count, 3, "the queue must survive a jump")
        XCTAssertEqual(lp.index, 2)
        XCTAssertTrue(lp.isEngaged, "jumping must not end the session")
    }

    func testStartingASecondListWhilePlayingReplacesIt() {
        let lp = LocalPlaybackController.shared
        lp.play([track("a"), track("b")], streamBase: deadBase, token: nil)
        // What "Play this mix" and Journey do: hand the engine a new list while
        // the old one is mid-flight.
        lp.play([track("x"), track("y"), track("z")], streamBase: deadBase, token: nil)

        XCTAssertEqual(lp.queue.map(\.id), ["x", "y", "z"])
        XCTAssertEqual(lp.index, 0)
        XCTAssertTrue(lp.isEngaged)
    }

    func testSkippingForwardWhilePlayingKeepsTheQueue() {
        let lp = LocalPlaybackController.shared
        lp.play([track("a"), track("b"), track("c")], streamBase: deadBase, token: nil)
        lp.next()
        XCTAssertEqual(lp.queue.count, 3)
        XCTAssertTrue(lp.isEngaged)
    }

    /// An out-of-range jump must be ignored, not trapped.
    func testJumpOutOfRangeIsIgnored() {
        let lp = LocalPlaybackController.shared
        lp.play([track("a")], streamBase: deadBase, token: nil)
        lp.jump(to: 9)
        XCTAssertEqual(lp.index, 0)
        XCTAssertEqual(lp.queue.count, 1)
    }
}
