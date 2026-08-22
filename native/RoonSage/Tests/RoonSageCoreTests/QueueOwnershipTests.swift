import XCTest
@testable import RoonSageCore

/// Who owns `queueItems` — the Roon subscription, or the snapshot.
///
/// Regression cover for a bug that only existed on the shipped apps. They run in
/// `.server` mode (`RoonSageApp` calls `useServerMode()`), where there is no Roon
/// WebSocket to subscribe to and `queueItems` arrives with every
/// `PlaybackSnapshot`. `QueueView` nonetheless called `startQueue` on appear and
/// `stopQueue` on disappear, and BOTH ends clear `queueItems` before doing
/// anything else. The subscription then failed silently (`try?` → nil → return),
/// so nothing refilled the list until the next snapshot — which `PlaybackEventHub`
/// only pushes when the digest CHANGES, backed by a 15 s fallback poll. Opening
/// the queue on a paused zone therefore showed the empty state for up to fifteen
/// seconds, and closing it blanked the player's up-next pill for the same window.
final class QueueOwnershipTests: XCTestCase {

    func testDirectModeOwnsTheSubscription() {
        // The server build talks to Roon itself, so it must keep subscribing.
        XCTAssertTrue(RoonClient.ownsQueueSubscription(mode: .direct))
    }

    func testServerModeDoesNot() {
        // The client apps are fed a queue; subscribing there is not merely
        // useless, it wipes the list the snapshot just delivered.
        XCTAssertFalse(RoonClient.ownsQueueSubscription(mode: .server))
    }
}
