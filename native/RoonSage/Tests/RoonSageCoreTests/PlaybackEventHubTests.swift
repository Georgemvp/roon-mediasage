@testable import RoonSageCore
import XCTest

/// Covers the pieces of the event stream that are testable without a live Roon
/// session: SSE framing, subscription bookkeeping, and the request-header helpers
/// the streaming path relies on (`/events` routing and keep-alive negotiation).
///
/// The ticker itself needs `RoonClient.shared` and a Roon connection, so its
/// change-detection is not exercised here — that is verified live against the
/// analyzer (see docs/STATE.md).
final class PlaybackEventHubTests: XCTestCase {

    // MARK: - SSE framing

    func testFrameIsWellFormedSSE() {
        let frame = PlaybackEventHub.frame(event: "playback", data: Data("{\"a\":1}".utf8))
        let text = String(decoding: frame, as: UTF8.self)
        XCTAssertEqual(text, "event: playback\ndata: {\"a\":1}\n\n")
        XCTAssertTrue(text.hasSuffix("\n\n"), "een SSE-event eindigt op een lege regel")
    }

    func testKeepaliveIsAComment() {
        let text = String(decoding: PlaybackEventHub.keepaliveFrame, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(":"), "een keepalive moet een comment zijn, geen event")
        XCTAssertTrue(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("data:"), "een keepalive draagt geen payload")
    }

    // MARK: - Subscription bookkeeping

    func testSubscribeAndUnsubscribeTrackCount() async {
        let hub = PlaybackEventHub()
        let a = await hub.subscribe(zone: "zone-1") { _ in }
        let b = await hub.subscribe(zone: nil) { _ in }

        var count = await hub.subscriberCount
        XCTAssertEqual(count, 2)

        await hub.unsubscribe(a)
        count = await hub.subscriberCount
        XCTAssertEqual(count, 1)

        await hub.unsubscribe(b)
        count = await hub.subscriberCount
        XCTAssertEqual(count, 0)
    }

    func testUnsubscribingAnUnknownIdIsHarmless() async {
        let hub = PlaybackEventHub()
        await hub.unsubscribe(UUID())
        let count = await hub.subscriberCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Request parsing used by the streaming path

    func testRequestTargetSplitsMethodPathAndQuery() {
        let (method, path, target) = LibraryShareServer.requestTarget(
            "GET /events?zone=abc%20def HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/events")
        XCTAssertEqual(target, "/events?zone=abc%20def")
    }

    func testRequestTargetOnGarbageIsSafe() {
        let (method, path, _) = LibraryShareServer.requestTarget("")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/")
    }

    // MARK: - Keep-alive negotiation

    func testHTTP11DefaultsToKeepAlive() {
        XCTAssertTrue(LibraryShareServer.wantsKeepAlive(
            "GET /playback HTTP/1.1\r\nHost: x\r\n\r\n"))
    }

    func testExplicitCloseOptsOut() {
        XCTAssertFalse(LibraryShareServer.wantsKeepAlive(
            "GET /playback HTTP/1.1\r\nConnection: close\r\n\r\n"))
        XCTAssertFalse(LibraryShareServer.wantsKeepAlive(
            "GET /playback HTTP/1.1\r\nconnection: Close\r\n\r\n"))
    }

    func testHTTP10NeverKeepsAlive() {
        XCTAssertFalse(LibraryShareServer.wantsKeepAlive(
            "GET /playback HTTP/1.0\r\nHost: x\r\n\r\n"),
            "HTTP/1.0 is per default niet persistent")
    }

    func testExplicitKeepAliveIsHonoured() {
        XCTAssertTrue(LibraryShareServer.wantsKeepAlive(
            "GET /playback HTTP/1.1\r\nConnection: keep-alive\r\n\r\n"))
    }

    // MARK: - Why the auth gate is not unit-tested here
    //
    // `/events` goes through the same `LibraryShareServer.authorize` as every
    // other route (see `startEventStream`), which is the property that matters —
    // a stream that skipped auth would be a hole around the token gate. It is NOT
    // asserted here because `authorize` reaches `currentToken()` → `KeychainStore`,
    // and a Keychain read from the unsigned xctest bundle pops a blocking
    // SecurityAgent ACL prompt that hangs the whole run (the freeze
    // `KeychainStore` documents; it cost this batch and batch 1 a stalled suite
    // each). Do not add a test that calls `authorize`, `currentToken`,
    // `isApprovedDevice` or `SyncableSettings.exportCurrent` — verify that path
    // live against the analyzer instead.
}
