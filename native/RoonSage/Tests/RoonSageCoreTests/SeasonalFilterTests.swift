import XCTest
@testable import RoonSageCore

/// Keeping Christmas out of a summer playlist.
///
/// Found live: a request for "zitten in het zonnetje te chillen" returned two
/// Michael Bublé holiday tracks. They passed every existing gate honestly —
/// genuinely easy listening, genuinely relaxed, genuinely chill — because no
/// gate knew about the season.
final class SeasonalFilterTests: XCTestCase {

    private struct T {
        let title: String
        let album: String?
        var genres: [String] = []
    }

    private func run(_ pool: [T], prompt: String?, minPool: Int = 0) -> (kept: [T], dropped: Int) {
        SeasonalFilter.filter(pool, prompt: prompt, keepIfFewerThan: minPool,
                              title: { $0.title }, album: { $0.album }, genres: { $0.genres })
    }

    func testDropsHolidayTracksFromAnUnrelatedRequest() {
        let pool = [T(title: "Holly Jolly Christmas", album: "Christmas"),
                    T(title: "Cold December Night", album: "Christmas"),
                    T(title: "Down Under", album: "Business as Usual")]
        let out = run(pool, prompt: "zitten in het zonnetje te chillen")
        XCTAssertEqual(out.kept.map(\.title), ["Down Under"])
        XCTAssertEqual(out.dropped, 2)
    }

    /// A Christmas album with an ordinary song title is still Christmas.
    func testCatchesItViaTheAlbum() {
        let pool = [T(title: "Blue Moon", album: "A Very Merry Christmas"),
                    T(title: "Blue Moon", album: "Standards")]
        let out = run(pool, prompt: "chill")
        XCTAssertEqual(out.kept.count, 1)
        XCTAssertEqual(out.kept.first?.album, "Standards")
    }

    func testCatchesItViaGenre() {
        let pool = [T(title: "Something", album: "Album", genres: ["Holiday"]),
                    T(title: "Other", album: "Album", genres: ["Jazz"])]
        XCTAssertEqual(run(pool, prompt: "rustig").kept.map(\.title), ["Other"])
    }

    /// Ask for Christmas and you get Christmas — the filter must not fight the user.
    func testKeepsThemWhenTheRequestAsksForThem() {
        let pool = [T(title: "Holly Jolly Christmas", album: "Christmas"),
                    T(title: "Down Under", album: "Business as Usual")]
        XCTAssertEqual(run(pool, prompt: "kerstmuziek voor bij het diner").dropped, 0)
        XCTAssertEqual(run(pool, prompt: "cosy christmas evening").dropped, 0)
    }

    /// Safety valve: never starve the pool, same posture as the genre/mood gates.
    func testKeepsEverythingRatherThanStarveThePool() {
        let pool = [T(title: "Jingle Bell Rock", album: "Christmas"),
                    T(title: "Silent Night", album: "Christmas")]
        let out = run(pool, prompt: "chill", minPool: 2)
        XCTAssertEqual(out.kept.count, 2, "filtering to nothing is worse than a wrong track")
        XCTAssertEqual(out.dropped, 0)
    }

    /// Deliberately narrow: seasons carry too many ordinary songs.
    func testDoesNotTouchOrdinaryWinterSongs() {
        let pool = [T(title: "Winter", album: "Boys for Pele"),
                    T(title: "Snow (Hey Oh)", album: "Stadium Arcadium")]
        XCTAssertEqual(run(pool, prompt: "chill").dropped, 0)
    }
}
