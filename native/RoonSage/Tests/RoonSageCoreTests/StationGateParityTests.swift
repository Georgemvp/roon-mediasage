import Foundation
import XCTest
@testable import RoonSageCore

/// The automatic genre stations and a user-composed station with a genre facet
/// are one rule on two sources, and they had drifted apart.
///
/// `b5325a9` moved the buckets to `SonicTrack.genres` (MusicBrainz ∪ Deezer)
/// after Daft Punk turned up in a jazz station, and scoped itself out of the
/// custom path. So an own station named "jazz" let in exactly what the automatic
/// one rejects.
///
/// The custom gate now prefers the precise genres and falls back to Roon's coarse
/// tag **only for tracks that have no precise genre at all** — measured on the
/// real library that is 785 of 64.038 (1,2 %), which have no counter-evidence to
/// go on. The buckets stay stricter on purpose: a bucket is built FROM precise
/// genres, so its gate only confirms membership.
final class StationGateParityTests: XCTestCase {

    private func track(id: String, genres: [String], matchKey: String = "mk") -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: "t", artist: "a", album: nil, imageKey: nil, matchKey: matchKey,
            bpm: nil, camelot: "8A", rmsEnergy: nil, tags: [], embedding: nil,
            moods: [:], genres: genres)
    }

    private func customJazzGate(coarse: [String: Set<String>]) -> ((DatabaseManager.SonicTrack) -> Bool)? {
        RoonClient.customGate(cfg: RadioConfig(name: "Mijn jazz", genres: ["jazz"]),
                              genres: coarse, years: [:], calibration: nil)
    }

    func testBothRejectWhatOnlyRoonCallsJazz() {
        // The case that started it: precise sources say electronic, Roon says
        // jazz. Both gates must now say no.
        let daftPunk = track(id: "dp", genres: ["electronic"])
        let coarse: [String: Set<String>] = ["dp": ["jazz"]]
        XCTAssertFalse(RoonClient.bucketGate(radioID: "genre:jazz", genres: coarse)?(daftPunk) ?? true)
        XCTAssertFalse(customJazzGate(coarse: coarse)?(daftPunk) ?? true,
                       "een eigen station hoort dezelfde grens te trekken")
    }

    func testBothAcceptAGenuineMatch() {
        let t = track(id: "x", genres: ["jazz"])
        XCTAssertTrue(RoonClient.bucketGate(radioID: "genre:jazz")?(t) ?? false)
        XCTAssertTrue(customJazzGate(coarse: [:])?(t) ?? false)
    }

    func testTracksWithoutAPreciseGenreFallBackToRoon() {
        // 785 of 64.038 tracks on the real library. No precise genre exists, so a
        // coarse tag is the best evidence there is — dropping them would silently
        // narrow every own station.
        let unknown = track(id: "u", genres: [])
        XCTAssertTrue(customJazzGate(coarse: ["u": ["jazz"]])?(unknown) ?? false,
                      "zonder precies genre telt Roon's tag")
        XCTAssertFalse(customJazzGate(coarse: ["u": ["rock"]])?(unknown) ?? true,
                       "maar dan moet die tag wel matchen")
        XCTAssertFalse(customJazzGate(coarse: [:])?(unknown) ?? true,
                       "en zonder enige bron valt hij af")
    }

    func testThePreciseSourceWinsWhenBothExist() {
        // The fallback must not become a second chance for a track we DO know
        // about — that would put Daft Punk back in jazz.
        let t = track(id: "dp", genres: ["electronic"])
        XCTAssertFalse(customJazzGate(coarse: ["dp": ["jazz"]])?(t) ?? true)
    }

    func testGenreMatchingIsCaseInsensitiveOnBothPaths() {
        XCTAssertTrue(customJazzGate(coarse: [:])?(track(id: "x", genres: ["JAZZ"])) ?? false)
        XCTAssertTrue(customJazzGate(coarse: ["u": ["Jazz"]])?(track(id: "u", genres: [])) ?? false)
    }

    func testAFacetlessConfigHasNoGate() {
        // Proximity to the seeds is then the whole definition; a gate that always
        // returns true would only cost time.
        XCTAssertNil(RoonClient.customGate(cfg: RadioConfig(name: "Leeg"),
                                           genres: [:], years: [:], calibration: nil))
        XCTAssertNil(RoonClient.bucketGate(radioID: "artist:dire straits"))
    }
}
