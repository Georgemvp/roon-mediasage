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
