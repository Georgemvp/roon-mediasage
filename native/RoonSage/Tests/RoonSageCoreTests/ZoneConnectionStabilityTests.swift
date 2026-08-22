@testable import RoonSageCore
import XCTest

/// The rules that keep a zone connection from flapping.
///
/// Both were written on 2026-08-22, after the mini turned out to be running two
/// analyzer copies: each registered as `com.roonsage.server`, the Roon Core
/// allows one connection per extension id, so they kicked each other every ~2 s
/// (1.046 closes in one hour). Two things made that as visible as it was:
/// the backoff reset on every open (so it never slowed down), and every close
/// cleared the zone list (so the chosen zone vanished on every client).
final class ZoneConnectionStabilityTests: XCTestCase {

    // MARK: - Reconnect backoff

    func testLadderClimbsWhileConnectionsKeepFailing() {
        var policy = ReconnectPolicy()
        let delays = (0..<6).map { _ in policy.connectionClosed(openedAt: nil).delaySeconds }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30], "blijft op de bovenste trede staan")
    }

    /// The regression: a socket that opens and is kicked two seconds later is
    /// not a healthy connection, so it must not put the ladder back to 2 s.
    func testShortLivedConnectionDoesNotResetTheLadder() {
        var policy = ReconnectPolicy()
        var now = Date()
        var delays: [UInt64] = []
        for _ in 0..<4 {
            let opened = now
            now = now.addingTimeInterval(2)   // kicked after two seconds
            delays.append(policy.connectionClosed(openedAt: opened, now: now).delaySeconds)
            now = now.addingTimeInterval(Double(delays.last!))
        }
        XCTAssertEqual(delays, [2, 4, 8, 16])
    }

    func testConnectionThatHeldResetsTheLadder() {
        var policy = ReconnectPolicy()
        let start = Date()
        _ = policy.connectionClosed(openedAt: nil, now: start)
        _ = policy.connectionClosed(openedAt: nil, now: start)
        let opened = start
        let after = start.addingTimeInterval(ReconnectPolicy.stableAfter + 1)
        XCTAssertEqual(policy.connectionClosed(openedAt: opened, now: after).delaySeconds, 2)
    }

    func testExplicitReconnectStartsOver() {
        var policy = ReconnectPolicy()
        _ = policy.connectionClosed(openedAt: nil)
        _ = policy.connectionClosed(openedAt: nil)
        policy.reset()
        XCTAssertEqual(policy.connectionClosed(openedAt: nil).delaySeconds, 2)
    }

    // MARK: - Flap detection

    func testRepeatedClosesInsideTheWindowCountAsFlapping() {
        var policy = ReconnectPolicy()
        var now = Date()
        var outcome = policy.connectionClosed(openedAt: nil, now: now)
        for _ in 1..<ReconnectPolicy.flapThreshold {
            now = now.addingTimeInterval(2)
            outcome = policy.connectionClosed(openedAt: nil, now: now)
        }
        XCTAssertTrue(outcome.isFlapping)
        XCTAssertEqual(outcome.closesInWindow, ReconnectPolicy.flapThreshold)
    }

    func testClosesSpreadOutOverTimeAreNotFlapping() {
        var policy = ReconnectPolicy()
        var now = Date()
        var outcome = policy.connectionClosed(openedAt: nil, now: now)
        for _ in 0..<10 {
            now = now.addingTimeInterval(ReconnectPolicy.flapWindow + 1)
            outcome = policy.connectionClosed(openedAt: nil, now: now)
        }
        XCTAssertFalse(outcome.isFlapping)
        XCTAssertEqual(outcome.closesInWindow, 1, "oude sluitingen vallen uit het venster")
    }

    // MARK: - Zone list during a blip (client side)

    private func zone(_ id: String) -> Zone {
        Zone(from: ["zone_id": id, "display_name": id, "state": "playing"])
    }

    /// The symptom: a server whose Roon link is down for two seconds reports
    /// zero zones, and the client used to take that literally — picker empty,
    /// play buttons disabled, Now Playing blank, every reconnect.
    func testEmptyZonesFromADisconnectedServerKeepsWhatIsOnScreen() {
        let kept = RoonClient.zonesAfterSnapshot(incoming: [], current: [zone("keuken")],
                                                 roonConnected: false)
        XCTAssertEqual(kept.map(\.id), ["keuken"])
    }

    /// A connected server reporting no zones is telling the truth.
    func testEmptyZonesFromAConnectedServerIsTakenAtFaceValue() {
        let kept = RoonClient.zonesAfterSnapshot(incoming: [], current: [zone("keuken")],
                                                 roonConnected: true)
        XCTAssertTrue(kept.isEmpty)
    }

    func testFreshZonesAlwaysWin() {
        let kept = RoonClient.zonesAfterSnapshot(incoming: [zone("zolder")],
                                                 current: [zone("keuken")],
                                                 roonConnected: false)
        XCTAssertEqual(kept.map(\.id), ["zolder"], "een echte lijst vervangt de bewaarde")
    }
}
