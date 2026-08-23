import XCTest
@testable import RoonSageCore

/// The Plex PIN sign-in (PlexAuth). This is the blocker fase 4 of PLEX_MIGRATION
/// starts with: without a per-device token, streaming from Plex would mean
/// shipping the server's admin token to every client.
final class PlexAuthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Eigen keychain-service, zodat de test nooit het echte token aanraakt.
        KeychainStore.serviceOverride = "roonsage.tests.plexauth.\(UUID().uuidString)"
    }

    override func tearDown() {
        _ = KeychainStore.delete(key: PlexAuth.tokenKey)
        _ = KeychainStore.delete(key: PlexAuth.clientIDKey)
        KeychainStore.serviceOverride = nil
        super.tearDown()
    }

    // MARK: - Parsing

    func testParsePinReadsIDAndShortCode() throws {
        let pin = try XCTUnwrap(PlexAuth.parsePin([
            "id": 837848415, "code": "STSV", "expiresIn": 900, "authToken": NSNull(),
        ]))
        XCTAssertEqual(pin.id, 837848415)
        XCTAssertEqual(pin.code, "STSV")
        XCTAssertEqual(pin.expiresIn, 900)
    }

    func testParsePinToleratesAStringIDAndAMissingExpiry() throws {
        let pin = try XCTUnwrap(PlexAuth.parsePin(["id": "42", "code": "ABCD"]))
        XCTAssertEqual(pin.id, 42)
        XCTAssertEqual(pin.expiresIn, 900, "zonder expiresIn de gemeten standaard")
    }

    func testParsePinRejectsIncompletePayloads() {
        XCTAssertNil(PlexAuth.parsePin(["code": "ABCD"]))
        XCTAssertNil(PlexAuth.parsePin(["id": 1]))
        XCTAssertNil(PlexAuth.parsePin(["id": 1, "code": ""]))
    }

    /// `authToken: null` is de NORMALE toestand tot de user de code koppelt —
    /// dat mag geen parse-fout zijn, anders breekt elke poll de inlog af.
    func testParseTokenTreatsNullAsNotLinkedYet() {
        XCTAssertNil(PlexAuth.parseToken(["authToken": NSNull()]))
        XCTAssertNil(PlexAuth.parseToken([:]))
        XCTAssertNil(PlexAuth.parseToken(["authToken": ""]))
        XCTAssertEqual(PlexAuth.parseToken(["authToken": "xyz-token"]), "xyz-token")
    }

    // MARK: - Identity & opslag

    func testClientIdentifierIsMintedOnceAndReused() {
        let first = PlexAuth.clientIdentifier()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(PlexAuth.clientIdentifier(), first,
                       "een nieuw id per aanroep zou elke start een nieuwe inlog vragen")
    }

    func testTokenRoundTripsAndSignOutClearsIt() {
        XCTAssertNil(PlexAuth.storedToken())
        XCTAssertTrue(PlexAuth.store(token: "tok-123"))
        XCTAssertEqual(PlexAuth.storedToken(), "tok-123")
        PlexAuth.signOut()
        XCTAssertNil(PlexAuth.storedToken())
    }

    // MARK: - Serverontdekking

    /// De bug die dit vond: `plexBaseURL` staat standaard op 127.0.0.1, wat op een
    /// telefoon de telefoon zélf is. Een correct gekoppeld toestel synchroniseerde
    /// daardoor 0 tracks, zonder één foutmelding.
    func testParseServersKeepsOnlyServersWithConnections() {
        let servers = PlexAuth.parseServers([
            ["name": "Mac mini", "provides": "server", "accessToken": "srv-tok",
             "connections": [
                ["uri": "https://10-0-0-1.plex.direct:32400", "local": true, "relay": false],
                ["uri": "https://82-217-191-164.plex.direct:14084", "local": false, "relay": false],
             ]],
            ["name": "Een speler", "provides": "player", "connections": [["uri": "x"]]],
            ["name": "Server zonder route", "provides": "server", "connections": []],
        ])
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "Mac mini")
        XCTAssertEqual(servers[0].accessToken, "srv-tok")
        XCTAssertEqual(servers[0].connections.count, 2)
    }

    /// Lokaal eerst (snel), dan direct extern, dan pas relay (traagst).
    func testConnectionsAreRankedLocalThenDirectThenRelay() {
        let ranked = PlexAuth.ranked([
            .init(uri: "relay", local: false, relay: true),
            .init(uri: "extern", local: false, relay: false),
            .init(uri: "lokaal", local: true, relay: false),
        ])
        XCTAssertEqual(ranked.map(\.uri), ["lokaal", "extern", "relay"])
    }

    /// Echt tegen plex.tv: geeft die dit account een server met een bruikbaar adres?
    func testLiveResourcesReturnsAReachableServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROONSAGE_PLEX_LIVE"] == "1",
                          "opt-in: zet ROONSAGE_PLEX_LIVE=1")
        // De live-test gebruikt het admin-token als sta-in voor een apparaat-token.
        let admin = try XCTUnwrap(PlexClient.localToken(), "geen lokale Plex-installatie")
        XCTAssertTrue(PlexAuth.store(token: admin))

        let servers = try await PlexAuth.servers()
        XCTAssertFalse(servers.isEmpty, "plex.tv hoort minstens één server te kennen")
        let found = await PlexAuth.reachableServer()
        let route = try XCTUnwrap(found, "geen enkele route antwoordde op /identity")
        XCTAssertTrue(route.baseURL.hasPrefix("http"))
        print("[plex live] servers=\(servers.map(\.name)) → bereikbaar via \(route.baseURL)")
    }

    // MARK: - Standalone-modus

    /// De poort waar de hele Plex-first opstart op hangt: gekoppeld aan Plex én
    /// geen server ingesteld = de app hoort door te laten.
    @MainActor
    func testStandaloneRequiresBothAPlexTokenAndNoServer() {
        let client = RoonClient.shared
        let savedServer = UserDefaults.standard.string(forKey: "library_import_url")
        defer {
            UserDefaults.standard.set(savedServer, forKey: "library_import_url")
            client.refreshPlexLinkState()
        }

        UserDefaults.standard.removeObject(forKey: "library_import_url")
        PlexAuth.signOut()
        client.refreshPlexLinkState()
        XCTAssertFalse(client.plexStandalone, "zonder Plex-token nooit standalone")

        _ = PlexAuth.store(token: "tok")
        client.refreshPlexLinkState()
        XCTAssertTrue(client.plexLinked)
        XCTAssertTrue(client.plexStandalone, "Plex + geen server = standalone")

        UserDefaults.standard.set("http://10.94.184.22:5767", forKey: "library_import_url")
        XCTAssertFalse(client.plexStandalone,
                       "mét server is de analyzer de bron; dan géén standalone-pad")
    }

    // MARK: - Live (opt-in)

    /// Vraagt een echte code aan bij plex.tv. Onschadelijk: een niet-gekoppelde
    /// pin verloopt vanzelf na 15 minuten.
    ///
    /// `ROONSAGE_PLEX_LIVE=1 swift test --filter testLiveRequestPin`
    func testLiveRequestPinReturnsATypeableCode() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROONSAGE_PLEX_LIVE"] == "1",
                          "opt-in: zet ROONSAGE_PLEX_LIVE=1")
        let pin = try await PlexAuth.requestPin()
        XCTAssertGreaterThan(pin.id, 0)
        XCTAssertEqual(pin.code.count, 4, "de korte code is wat iemand op plex.tv/link intypt")
        XCTAssertGreaterThan(pin.expiresIn, 60)

        // Nog niet gekoppeld → nil, geen fout.
        let token = try await PlexAuth.pollPin(id: pin.id)
        XCTAssertNil(token, "een verse, ongekoppelde pin hoort nog geen token te hebben")
        print("[plex live] pin \(pin.id) code=\(pin.code) verloopt over \(pin.expiresIn)s")
    }
}
