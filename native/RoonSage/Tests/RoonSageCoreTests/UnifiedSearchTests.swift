import XCTest
@testable import RoonSageCore

/// Ranking for the single search box.
///
/// The defect these guard against is specific: albums and artists come back
/// from SQL in alphabetical order, so taking the first N of a match set can
/// drop the exact hit entirely.
final class UnifiedSearchTests: XCTestCase {

    func testTiersRankExactAboveEveryWeakerMatch() {
        XCTAssertEqual(UnifiedSearch.tier("Dire Straits", matching: "Dire Straits"), .exact)
        XCTAssertEqual(UnifiedSearch.tier("Dire Straits", matching: "dire"), .prefix)
        XCTAssertEqual(UnifiedSearch.tier("Sultans of Swing", matching: "swi"), .wordPrefix)
        XCTAssertEqual(UnifiedSearch.tier("Sultans of Swing", matching: "wing"), .contains)
        XCTAssertEqual(UnifiedSearch.tier("Sultans of Swing", matching: "zeppelin"), .none)
        XCTAssertEqual(UnifiedSearch.tier(nil, matching: "x"), .none)
        XCTAssertEqual(UnifiedSearch.tier("Anything", matching: "   "), .none)
    }

    /// Case and accents are typing noise, not intent — nobody reaches for the
    /// diaeresis to find Motörhead.
    func testMatchingIgnoresCaseAndDiacritics() {
        XCTAssertEqual(UnifiedSearch.tier("Motörhead", matching: "motorhead"), .exact)
        XCTAssertEqual(UnifiedSearch.tier("Sigur Rós", matching: "sigur ros"), .exact)
        XCTAssertEqual(UnifiedSearch.tier("Beyoncé", matching: "BEYONCE"), .exact)
    }

    /// Punctuation is a word boundary: "(Live)" and hyphenated titles are how
    /// half a real library is named.
    func testWordPrefixSeesPastPunctuation() {
        XCTAssertEqual(UnifiedSearch.tier("Sultans of Swing (Live)", matching: "live"), .wordPrefix)
        XCTAssertEqual(UnifiedSearch.tier("Post-Rock Anthems", matching: "rock"), .wordPrefix)
    }

    func testBestTierTakesTheStrongestField() {
        // Matches the artist exactly, the title not at all — the artist wins.
        XCTAssertEqual(UnifiedSearch.bestTier(["Brothers in Arms", "Dire Straits"],
                                              matching: "dire straits"), .exact)
        XCTAssertEqual(UnifiedSearch.bestTier([nil, nil], matching: "x"), .none)
    }

    /// THE regression this type exists for. Alphabetical order puts the exact
    /// album last; a naive `prefix(3)` would never show it.
    func testExactMatchSurvivesTheSectionCap() {
        let alphabetical = ["Alchemy: Dire Straits Live",
                            "Brothers in Arms",
                            "Communiqué",
                            "Dire Straits"]
        let ranked = UnifiedSearch.rank(alphabetical, query: "Dire Straits", limit: 3) { [$0] }
        XCTAssertEqual(ranked.first, "Dire Straits", "the exact match must lead, not be cut off")
        // Two of the four mention the band; the other two match nothing and are
        // dropped rather than padding the section out to its cap.
        XCTAssertEqual(ranked, ["Dire Straits", "Alchemy: Dire Straits Live"])
    }

    /// Equal-tier hits keep the caller's order. Without this the list reshuffles
    /// on every keystroke, which reads as flicker rather than as ranking.
    func testEqualTiersKeepSourceOrder() {
        let items = ["Swing Time", "Swingers", "Swing Low"]   // all .prefix
        XCTAssertEqual(UnifiedSearch.rank(items, query: "swing", limit: 5) { [$0] }, items)
    }

    /// Over-fetched candidates that match nothing are dropped rather than
    /// padded in to reach the limit.
    func testNonMatchesAreDroppedNotPadded() {
        let items = ["Dire Straits", "Led Zeppelin", "Pink Floyd"]
        let ranked = UnifiedSearch.rank(items, query: "dire", limit: 5) { [$0] }
        XCTAssertEqual(ranked, ["Dire Straits"])
    }

    /// An empty query is a browse, not a search: keep the order SQL chose.
    func testEmptyQueryPassesThroughUnranked() {
        let items = ["C", "A", "B"]
        XCTAssertEqual(UnifiedSearch.rank(items, query: "  ", limit: 2) { [$0] }, ["C", "A"])
    }

    /// The pool must be bigger than what we display, or ranking has nothing to
    /// reorder and the alphabetical cap comes straight back.
    func testCandidatePoolExceedsWhatIsShown() {
        XCTAssertGreaterThan(UnifiedSearch.candidatePool, UnifiedSearch.sectionLimit * 4)
    }

    /// Ranking real result types, not just strings — an album matched by its
    /// artist has to outrank one matched by a stray word in its title.
    func testRanksAlbumsByArtistAndTitleTogether() {
        let albums = [
            DatabaseManager.AlbumResult(albumKey: "1", album: "Straits of Malacca",
                                        artist: "Various", year: 1999, trackCount: 10),
            DatabaseManager.AlbumResult(albumKey: "2", album: "Brothers in Arms",
                                        artist: "Dire Straits", year: 1985, trackCount: 9),
        ]
        let ranked = UnifiedSearch.rank(albums, query: "dire straits", limit: 5) {
            [$0.album, $0.artist]
        }
        XCTAssertEqual(ranked.first?.albumKey, "2")
        XCTAssertEqual(ranked.count, 1, "the compilation matches nothing and should be dropped")
    }
}
