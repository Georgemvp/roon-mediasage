import Foundation
import XCTest
@testable import RoonSageCore

/// `RadioConfig` is the general case that the engine's automatic stations are
/// special cases of. These pin that mapping, because getting it wrong means
/// "keep this station" saves something that plays different music than the one
/// you were listening to.
final class RadioConfigFromStationTests: XCTestCase {

    func testArtistStationKeepsTheDisplayName() {
        // The id is lowercased; the seed resolver matches on the display name.
        let c = RadioConfig.fromStation(id: "artist:dire straits", name: "Dire Straits",
                                        adventurousness: 0.4)
        XCTAssertEqual(c?.artists, ["Dire Straits"])
        XCTAssertEqual(c?.adventurousness, 0.4)
        XCTAssertTrue(c?.genres.isEmpty ?? false)
    }

    func testMetadataStationsMapToTheirOwnFacet() {
        XCTAssertEqual(RadioConfig.fromStation(id: "genre:House", name: "House",
                                               adventurousness: 0.5)?.genres, ["house"])
        XCTAssertEqual(RadioConfig.fromStation(id: "mood:Calm", name: "Calm",
                                               adventurousness: 0.5)?.moods, ["calm"])
        XCTAssertEqual(RadioConfig.fromStation(id: "activity:workout", name: "Workout",
                                               adventurousness: 0.5)?.activities, ["workout"])
        XCTAssertEqual(RadioConfig.fromStation(id: "decade:1980", name: "1980s",
                                               adventurousness: 0.5)?.decades, [1980])
    }

    func testFacetlessStationsPinTheirSeeds() {
        // A cluster or an album has no genre to be named by — the seeds ARE the
        // definition, so without them we must refuse rather than guess.
        let withSeeds = RadioConfig.fromStation(id: "sonic:7", name: "Klankgroep 7",
                                                adventurousness: 0.5,
                                                seedMatchKeys: ["a", "b"])
        XCTAssertEqual(withSeeds?.trackKeys, ["a", "b"])
        XCTAssertNil(RadioConfig.fromStation(id: "sonic:7", name: "Klankgroep 7",
                                             adventurousness: 0.5))
        XCTAssertNil(RadioConfig.fromStation(id: "album:x", name: "Album",
                                             adventurousness: 0.5))
    }

    func testUnknownOrMalformedIdsAreRefused() {
        XCTAssertNil(RadioConfig.fromStation(id: "wat:dan-ook", name: "x", adventurousness: 0.5))
        XCTAssertNil(RadioConfig.fromStation(id: "geen-scheidingsteken", name: "x", adventurousness: 0.5))
        XCTAssertNil(RadioConfig.fromStation(id: "genre:", name: "x", adventurousness: 0.5))
        XCTAssertNil(RadioConfig.fromStation(id: "decade:tachtig", name: "x", adventurousness: 0.5))
    }

    func testResultAlwaysHasFacets() {
        // An empty config seeds nothing; it must never be handed back as valid.
        for id in ["artist:x", "genre:house", "mood:calm", "activity:focus", "decade:1990"] {
            let c = RadioConfig.fromStation(id: id, name: "Naam", adventurousness: 0.5)
            XCTAssertTrue(c?.hasFacets ?? false, "\(id) leverde een config zonder facetten")
        }
    }
}
