@testable import RoonSageCore
import XCTest

/// Which host a thin client fetches album art from. `imageURL` returns nil
/// without one, so every wrong answer here means "no artwork anywhere" — which is
/// exactly how this surfaced on 2026-08-08, on a fresh iOS install that had no
/// previously-cached host to fall back on.
final class CoreHostResolutionTests: XCTestCase {

    private let serverHosts = ["192.168.178.59", "10.94.184.22", "192.168.178.60"]

    private func resolve(_ reported: String?, server: String? = "10.94.184.22",
                         connected: Bool = true, current: String? = nil) -> String? {
        RoonClient.resolvedCoreHost(reported: reported, serverHost: server,
                                    roonConnected: connected, current: current,
                                    knownHosts: serverHosts)
    }

    // MARK: - The regression

    /// The server can report `.connected` with a nil host after a stale socket's
    /// close races its registration. Before the fix this left the client with no
    /// host at all.
    func testNilReportWhileConnectedFallsBackToTheServerHost() {
        XCTAssertEqual(resolve(nil), "10.94.184.22")
        XCTAssertEqual(resolve(""), "10.94.184.22", "leeg telt als niet gerapporteerd")
    }

    /// A momentary blip must not blank artwork that is already on screen.
    func testNilReportWhileDisconnectedKeepsWhatWeHave() {
        XCTAssertEqual(resolve(nil, connected: false, current: "192.168.178.59"),
                       "192.168.178.59")
    }

    func testNilReportWhileDisconnectedAndNothingKnownStaysNil() {
        XCTAssertNil(resolve(nil, connected: false, current: nil))
    }

    // MARK: - Substituting the server's own addresses

    /// The Core usually runs on the server, which reports it as loopback — useless
    /// to a phone. Use the address this connection actually runs over.
    func testLoopbackIsReplacedByTheConnectionHost() {
        XCTAssertEqual(resolve("127.0.0.1"), "10.94.184.22")
        XCTAssertEqual(resolve("localhost"), "10.94.184.22")
        XCTAssertEqual(resolve("::1"), "10.94.184.22")
    }

    /// The server's LAN address is equally unreachable from 4G/5G while the
    /// connection itself runs over ZeroTier.
    func testAServerAdvertisedAddressIsReplacedToo() {
        XCTAssertEqual(resolve("192.168.178.59"), "10.94.184.22")
    }

    /// A Core on a genuinely different machine must be left alone.
    func testAForeignCoreHostIsKept() {
        XCTAssertEqual(resolve("192.168.178.99"), "192.168.178.99")
    }

    /// With no server host to substitute, the reported one is still better than
    /// nothing.
    func testFallsBackToTheReportedHostWhenNoServerHostIsKnown() {
        XCTAssertEqual(resolve("127.0.0.1", server: nil), "127.0.0.1")
        XCTAssertEqual(resolve("192.168.178.99", server: nil), "192.168.178.99")
    }

    /// Whatever else happens, a connected server must never leave the client
    /// without a host — that is the state that produces blank art everywhere.
    func testAConnectedServerAlwaysYieldsAHost() {
        for reported in [nil, "", "127.0.0.1", "192.168.178.59", "192.168.178.99"] {
            XCTAssertNotNil(resolve(reported), "reported=\(reported ?? "nil") gaf geen host")
        }
    }
}
