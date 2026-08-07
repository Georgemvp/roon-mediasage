@testable import RoonSageCore
import XCTest

/// Pure selection rules for the "Aanbevelingen" Qobuz playlist.
final class RecommendationsPlaylistTests: XCTestCase {

    private let albums = [
        (qobuzAlbumID: "a1", artist: "Foals", album: "Holy Fire"),
        (qobuzAlbumID: "a2", artist: "Bob Moses", album: "Battle Lines"),
    ]

    func testTakesTheRequestedNumberOfTracksPerAlbumInBatchOrder() {
        // Batch order is best-score-first, so the playlist must not resort it.
        let byAlbum: [String: [(title: String, artist: String?)]] = [
            "a1": [("Inhaler", nil), ("My Number", nil), ("Late Night", nil)],
            "a2": [("Heaven Only Knows", nil), ("Enough to Believe", nil)],
        ]
        let out = RoonClient.recommendationsTrackList(
            albums: albums, tracksByAlbumID: byAlbum, perAlbum: 2)
        XCTAssertEqual(out.map(\.title),
                       ["Inhaler", "My Number", "Heaven Only Knows", "Enough to Believe"])
        XCTAssertEqual(out.first?.album, "Holy Fire", "album is carried for Qobuz matching")
    }

    func testFallsBackToTheAlbumArtistWhenTheTrackHasNone() {
        // album/get track items don't always carry a performer.
        let out = RoonClient.recommendationsTrackList(
            albums: [albums[0]], tracksByAlbumID: ["a1": [("Inhaler", nil)]], perAlbum: 1)
        XCTAssertEqual(out.first?.artist, "Foals")
    }

    func testDedupesTheSameTrackAcrossTwoRecommendedAlbums() {
        // A single and the album it comes from can both be recommended.
        let byAlbum: [String: [(title: String, artist: String?)]] = [
            "a1": [("Inhaler", "Foals")],
            "a2": [("inhaler", "foals")],   // same track, different casing
        ]
        let out = RoonClient.recommendationsTrackList(
            albums: albums, tracksByAlbumID: byAlbum, perAlbum: 2)
        XCTAssertEqual(out.count, 1, "one playlist slot per distinct track")
    }

    func testSkipsAlbumsWithNoFetchedTracksAndBlankTitles() {
        // album/get failing for one album must not drop the others.
        let byAlbum: [String: [(title: String, artist: String?)]] = [
            "a1": [("", nil), ("My Number", nil)],
            // "a2" missing entirely — the fetch failed.
        ]
        let out = RoonClient.recommendationsTrackList(
            albums: albums, tracksByAlbumID: byAlbum, perAlbum: 2)
        XCTAssertEqual(out.map(\.title), ["My Number"])
    }

    func testEmptyInputYieldsEmptyPlaylistRatherThanCrashing() {
        XCTAssertTrue(RoonClient.recommendationsTrackList(
            albums: [], tracksByAlbumID: [:], perAlbum: 2).isEmpty)
    }

    func testPlaylistTitleIsLiteralAndNamespaced() {
        // User asked for unambiguous names; this one is looked up by name in Roon.
        XCTAssertEqual(RoonClient.recommendationsPlaylistTitle, "Aanbevelingen")
        XCTAssertEqual(RoonClient.recommendationsQobuzName, "RoonSage · Aanbevelingen")
    }
}
