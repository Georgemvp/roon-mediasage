import Foundation
import XCTest
@testable import RoonSageCore

/// The automatic genre stations and a user-composed station with a genre facet
/// are the same rule on two different sources, **on purpose**.
///
/// `b5325a9` moved the buckets to `SonicTrack.genres` (MusicBrainz ∪ Deezer)
/// because Roon's coarse `track_genres` put Daft Punk in a jazz station — and
/// that same commit says in as many words: "Roon genresByTrackID() blijft
/// ongemoeid (artist-affiniteit/custom/SonicDNA hangen eraan)."
///
/// The consequence is that an own station is *looser* than the automatic one of
/// the same name. That may well be worth changing (the argument that killed the
/// coarse source for buckets applies here too), but it changes what people's
/// saved stations play, so it is a decision — not a cleanup. These tests pin the
/// difference so it can only move deliberately.
final class StationGateParityTests: XCTestCase {

    private func track(id: String, genres: [String], matchKey: String = "mk") -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: "t", artist: "a", album: nil, imageKey: nil, matchKey: matchKey,
            bpm: nil, camelot: "8A", rmsEnergy: nil, tags: [], embedding: nil,
            moods: [:], genres: genres)
    }

    private let roonSaysJazz = "daft-punk-track"

    func testBothGatesAgreeWhenBothSourcesAgree() {
        let t = track(id: "x", genres: ["jazz"])
        let coarse: [String: Set<String>] = ["x": ["jazz"]]
        XCTAssertTrue(RoonClient.bucketGate(radioID: "genre:jazz", genres: coarse)?(t) ?? false)
        XCTAssertTrue(RoonClient.customGate(cfg: RadioConfig(name: "Mijn jazz", genres: ["jazz"]),
                                            genres: coarse, years: [:], calibration: nil)?(t) ?? false)
    }

    func testTheyDivergeExactlyWhereTheSourcesDo() {
        // Roon calls it jazz; MusicBrainz/Deezer call it electronic.
        let t = track(id: roonSaysJazz, genres: ["electronic"])
        let coarse: [String: Set<String>] = [roonSaysJazz: ["jazz"]]

        XCTAssertFalse(RoonClient.bucketGate(radioID: "genre:jazz", genres: coarse)?(t) ?? true,
                       "de automatische poort leest MB∪Deezer en weert dit")
        XCTAssertTrue(RoonClient.customGate(cfg: RadioConfig(name: "Mijn jazz", genres: ["jazz"]),
                                            genres: coarse, years: [:], calibration: nil)?(t) ?? false,
                      "een eigen station leest Roon's tabel en laat dit toe — bewust, zie b5325a9")
    }

    func testGenreMatchingIsCaseInsensitiveOnBothSides() {
        let t = track(id: "x", genres: ["jazz"])
        let coarse: [String: Set<String>] = ["x": ["Jazz"]]
        XCTAssertTrue(RoonClient.customGate(cfg: RadioConfig(name: "M", genres: ["JAZZ"]),
                                            genres: coarse, years: [:], calibration: nil)?(t) ?? false)
        XCTAssertTrue(RoonClient.bucketGate(radioID: "genre:jazz", genres: coarse)?(t) ?? false)
    }

    func testAFacetlessConfigHasNoGate() {
        // Proximity to the seeds is then the whole definition; a gate that always
        // returns true would only cost time.
        XCTAssertNil(RoonClient.customGate(cfg: RadioConfig(name: "Leeg"),
                                           genres: [:], years: [:], calibration: nil))
        XCTAssertNil(RoonClient.bucketGate(radioID: "artist:dire straits"))
    }
}
