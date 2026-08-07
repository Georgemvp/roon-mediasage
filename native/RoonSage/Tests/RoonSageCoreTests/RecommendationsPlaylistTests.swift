@testable import RoonSageCore
import XCTest

/// Pure selection rules for the two discovery Qobuz playlists.
final class RecommendationsPlaylistTests: XCTestCase {

    private let albums = [
        (qobuzAlbumID: "a1", artist: "Foals", album: "Holy Fire"),
        (qobuzAlbumID: "a2", artist: "Bob Moses", album: "Battle Lines"),
    ]

    // MARK: Track budgeting

    func testSingleContributesOneTrackNotTwo() {
        // The bug this replaced: a fixed 2-per-release took "two tracks off a
        // single", which is what made the playlist read as padded.
        XCTAssertEqual(RoonClient.tracksToTake(fromReleaseOf: 1), 1)
        XCTAssertEqual(RoonClient.tracksToTake(fromReleaseOf: 0), 1, "unknown length is treated as a single")
    }

    func testBudgetGrowsWithReleaseLength() {
        XCTAssertEqual(RoonClient.tracksToTake(fromReleaseOf: 3), 1, "EP stays a taster")
        XCTAssertEqual(RoonClient.tracksToTake(fromReleaseOf: 6), 2)
        XCTAssertEqual(RoonClient.tracksToTake(fromReleaseOf: 12), 3, "full album gets the most room")
    }

    // MARK: Album playlist

    func testAlbumPlaylistAppliesThePerReleaseBudgetInBatchOrder() {
        // a1 is a 12-track album (3 taken), a2 a single (1 taken).
        let byAlbum: [String: [(title: String, artist: String?)]] = [
            "a1": (1...12).map { (title: "T\($0)", artist: nil) },
            "a2": [("Solo Single", nil)],
        ]
        let out = RoonClient.recommendationsTrackList(albums: albums, tracksByAlbumID: byAlbum)
        XCTAssertEqual(out.map(\.title), ["T1", "T2", "T3", "Solo Single"])
        XCTAssertEqual(out.first?.album, "Holy Fire", "album is carried for Qobuz matching")
    }

    func testFallsBackToTheAlbumArtistWhenTheTrackHasNone() {
        let out = RoonClient.recommendationsTrackList(
            albums: [albums[0]], tracksByAlbumID: ["a1": [("Inhaler", nil)]])
        XCTAssertEqual(out.first?.artist, "Foals")
    }

    func testDedupesTheSameTrackAcrossTwoRecommendedReleases() {
        // A single and the album it came from can both be recommended.
        let byAlbum: [String: [(title: String, artist: String?)]] = [
            "a1": [("Inhaler", "Foals")],
            "a2": [("inhaler", "foals")],   // same track, different casing
        ]
        let out = RoonClient.recommendationsTrackList(albums: albums, tracksByAlbumID: byAlbum)
        XCTAssertEqual(out.count, 1, "one playlist slot per distinct track")
    }

    func testSkipsReleasesWithNoFetchedTracksAndBlankTitles() {
        // album/get failing for one release must not drop the others.
        let out = RoonClient.recommendationsTrackList(
            albums: albums, tracksByAlbumID: ["a1": [("", nil), ("My Number", nil)]])
        XCTAssertEqual(out.map(\.title), ["My Number"])
    }

    func testEmptyInputYieldsEmptyPlaylistRatherThanCrashing() {
        XCTAssertTrue(RoonClient.recommendationsTrackList(albums: [], tracksByAlbumID: [:]).isEmpty)
    }

    // MARK: Artist playlist

    func testNewForYouTakesOneTrackPerArtistInBatchOrder() {
        let out = RoonClient.newForYouTrackList(
            artists: ["Khruangbin", "Men I Trust"],
            trackByArtist: ["Khruangbin": ("Time (You and I)", "Mordechai"),
                            "Men I Trust": ("Numb", "Oncle Jazz")])
        XCTAssertEqual(out.map(\.title), ["Time (You and I)", "Numb"])
        XCTAssertEqual(out.map(\.artist), ["Khruangbin", "Men I Trust"])
    }

    func testNewForYouSkipsArtistsThatCouldNotBeResolved() {
        // searchArtistAlbums finds nothing for an obscure/misspelled name.
        let out = RoonClient.newForYouTrackList(
            artists: ["Known", "Unresolvable"],
            trackByArtist: ["Known": ("A Track", nil)])
        XCTAssertEqual(out.map(\.artist), ["Known"])
    }

    func testNewForYouKeepsOneSlotPerArtist() {
        let out = RoonClient.newForYouTrackList(
            artists: ["Foals", "foals"],
            trackByArtist: ["Foals": ("Inhaler", nil), "foals": ("My Number", nil)])
        XCTAssertEqual(out.count, 1, "an artist appears once even if the batch repeats them")
    }

    // MARK: Naming

    func testPlaylistTitlesAreLiteralAndNamespaced() {
        XCTAssertEqual(RoonClient.recommendationsPlaylistTitle, "Aanbevelingen")
        XCTAssertEqual(RoonClient.newForYouPlaylistTitle, "Nieuw voor jou")
        XCTAssertEqual(RoonClient.recommendationsQobuzName, "RoonSage · Aanbevelingen")
        XCTAssertEqual(RoonClient.newForYouQobuzName, "RoonSage · Nieuw voor jou")
    }
}
