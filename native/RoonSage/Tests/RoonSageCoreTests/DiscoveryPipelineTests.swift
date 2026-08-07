@testable import RoonSageCore
import XCTest

/// The pure pipeline merge/dedup: cross-producer grouping (which becomes the
/// consensus signal) and post-resolve re-dedup by canonical identity.
final class DiscoveryPipelineTests: XCTestCase {

    func testMergeGroupsByNormalizedIdentityAndCountsSources() {
        let candidates = [
            Candidate(kind: .artist, artist: "Boards of Canada", similarity: 0.9, producer: "similar-artist-web"),
            Candidate(kind: .artist, artist: "boards of canada", similarity: 0.7, producer: "charts"),   // same after normalise
            Candidate(kind: .artist, artist: "Aphex Twin", similarity: 0.8, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 2)

        let boc = merged.first { $0.artist.lowercased() == "boards of canada" }
        XCTAssertNotNil(boc)
        XCTAssertEqual(boc?.distinctSources, 2)   // found by two producers → consensus
        XCTAssertEqual(boc?.sources.count, 2)

        let aphex = merged.first { $0.artist.lowercased() == "aphex twin" }
        XCTAssertEqual(aphex?.distinctSources, 1)
    }

    func testMergeDoesNotDoubleCountSameProducer() {
        let candidates = [
            Candidate(kind: .artist, artist: "Autechre", similarity: 0.6, producer: "similar-artist-web"),
            Candidate(kind: .artist, artist: "Autechre", similarity: 0.9, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.distinctSources, 1)   // same producer twice ≠ consensus
    }

    func testRededupeCollapsesByResolvedMBID() {
        // Two items that normalized differently pre-resolve but share an MBID
        // (canonicalised) collapse into one, unioning their sources.
        var a = WorkItem(kind: .artist, artist: "The Beatles", album: nil, year: nil, genres: [],
                         sources: [SourceRef(producer: "similar-artist-web")], artistMbid: "mbid-1",
                         releaseGroupMbid: nil, qobuzAlbumID: nil, imageURL: nil, releaseDate: nil, gapPriority: nil)
        var b = a
        b.artist = "Beatles"
        b.sources = [SourceRef(producer: "charts")]
        let deduped = DiscoveryPipeline.rededupe([a, b])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.distinctSources, 2)
        _ = (a, b)
    }

    func testMergeThreadsGapPriorityFromCandidate() {
        // Gap-fill sets gapPriority; a later, gapPriority-less duplicate from
        // another producer must not blank it out (first non-nil wins).
        let candidates = [
            Candidate(kind: .album, artist: "Boards of Canada", album: "Geogaddi",
                     similarity: 0.6, producer: "gap-fill", gapPriority: 1.0),
            Candidate(kind: .album, artist: "Boards of Canada", album: "Geogaddi",
                     similarity: 0.5, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.gapPriority, 1.0)
        XCTAssertEqual(merged.first?.distinctSources, 2)
    }

    func testPreKeyNormalizesArtist() {
        XCTAssertEqual(
            DiscoveryPipeline.preKey(kind: .artist, artist: "Sigur Rós", album: nil),
            DiscoveryPipeline.preKey(kind: .artist, artist: "sigur ros", album: nil))
    }

    // MARK: - Genre-from-tags distillation (fixes the "0 genres" empty inputs)

    func testGenresFromTagsFiltersNoiseAgainstVocabulary() {
        let tags = ["rock", "british", "blues rock", "1980s", "classic rock", "seen live"]
        let vocab: Set<String> = ["rock", "blues rock", "classic rock", "country rock"]
        // Keeps only real genres, in the original vote-ranked order.
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: vocab),
                       ["rock", "blues rock", "classic rock"])
    }

    func testGenresFromTagsFallsBackToRawTagsWhenVocabularyEmpty() {
        // Taxonomy not synced yet → don't stay blank; use the raw tags (capped at 6).
        let tags = ["a", "b", "c", "d", "e", "f", "g"]
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: []),
                       ["a", "b", "c", "d", "e", "f"])
    }

    func testGenresFromTagsCapsAtSix() {
        let tags = ["rock", "pop", "jazz", "blues", "folk", "soul", "funk", "disco"]
        let vocab = Set(tags)
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: vocab).count, 6)
    }

    // MARK: Recency-first seeding

    func testMergeRecentFirstPutsRecentAheadOfAllTimeFavourites() {
        // The all-time leader must not displace what's actually playing now —
        // that inversion is the whole reason discovery seeds on recency.
        let recent  = [(artist: "Foals", count: 4), (artist: "Bob Moses", count: 2)]
        let allTime = [(artist: "Dire Straits", count: 900), (artist: "Foals", count: 30)]
        let out = RoonClient.mergeRecentFirst(recent: recent, allTime: allTime, limit: 10)
        XCTAssertEqual(out.map(\.artist), ["Foals", "Bob Moses", "Dire Straits"])
    }

    func testMergeRecentFirstDedupesCaseInsensitivelyKeepingRecentSpelling() {
        // listening_history.artist is free text from Roon AND imported Last.fm, so
        // the same artist can differ in case between the two queries.
        let out = RoonClient.mergeRecentFirst(
            recent:  [(artist: "boards of canada", count: 3)],
            allTime: [(artist: "Boards of Canada", count: 200)],
            limit: 10)
        XCTAssertEqual(out.map(\.artist), ["boards of canada"], "one slot, recent spelling wins")
    }

    func testMergeRecentFirstFallsBackToAllTimeWhenHistoryIsThin() {
        // Brand-new user / empty recent window: seeds still fill from all-time.
        let allTime = [(artist: "A", count: 9), (artist: "B", count: 8)]
        let out = RoonClient.mergeRecentFirst(recent: [], allTime: allTime, limit: 10)
        XCTAssertEqual(out.map(\.artist), ["A", "B"])
    }

    func testMergeRecentFirstRespectsLimitAndDropsBlanks() {
        let recent = [(artist: "", count: 5), (artist: "A", count: 1), (artist: "B", count: 1)]
        let out = RoonClient.mergeRecentFirst(
            recent: recent, allTime: [(artist: "C", count: 1)], limit: 2)
        XCTAssertEqual(out.map(\.artist), ["A", "B"], "blank artists never consume a seed slot")
    }
}
