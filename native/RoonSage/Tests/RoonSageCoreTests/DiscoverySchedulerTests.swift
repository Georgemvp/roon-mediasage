@testable import RoonSageCore
import XCTest

/// The scheduler's cost-control guard: a stable, order-independent taste
/// signature, and the pure skip-if-unchanged decision (no clock/DB reads, so
/// every edge case is directly testable).
final class DiscoverySchedulerTests: XCTestCase {

    // MARK: tasteSignature

    func testTasteSignatureStableAndOrderIndependent() {
        let a = DiscoveryPipeline.tasteSignature(
            topArtists: ["Radiohead", "Bjork"], liked: ["Aphex Twin"], disliked: [], watchlist: ["boards of canada"])
        let b = DiscoveryPipeline.tasteSignature(
            topArtists: ["Bjork", "Radiohead"], liked: ["Aphex Twin"], disliked: [], watchlist: ["Boards Of Canada"])
        XCTAssertEqual(a, b)   // reordering + case differences don't change it
    }

    func testTasteSignatureChangesOnNewLike() {
        let a = DiscoveryPipeline.tasteSignature(topArtists: ["Radiohead"], liked: [], disliked: [], watchlist: [])
        let b = DiscoveryPipeline.tasteSignature(topArtists: ["Radiohead"], liked: ["Aphex Twin"], disliked: [], watchlist: [])
        XCTAssertNotEqual(a, b)
    }

    func testTasteSignatureChangesOnNewWatchlistArtist() {
        let a = DiscoveryPipeline.tasteSignature(topArtists: [], liked: [], disliked: [], watchlist: ["radiohead"])
        let b = DiscoveryPipeline.tasteSignature(topArtists: [], liked: [], disliked: [], watchlist: ["radiohead", "bjork"])
        XCTAssertNotEqual(a, b)
    }

    // MARK: shouldSkipRun

    func testNoSkipWithoutAPriorBatch() {
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "abc", lastBatchSig: nil, lastBatchCreatedAt: nil, now: Date()))
    }

    func testNoSkipWhenTasteChanged() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "new-sig", lastBatchSig: "old-sig",
            lastBatchCreatedAt: now.addingTimeInterval(-60), now: now))
    }

    func testManualSkipsWithinThirtyMinutesWhenUnchanged() {
        let now = Date()
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-10 * 60), now: now))
    }

    func testManualDoesNotSkipPastThirtyMinutes() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-40 * 60), now: now))
    }

    func testScheduledToleratesALongerWindowThanManual() {
        let now = Date()
        let anHourAgo = now.addingTimeInterval(-60 * 60)
        // Same age: manual would already allow a re-run (past its 30-min window),
        // but scheduled still skips (within its 6h window) — different thresholds.
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same", lastBatchCreatedAt: anHourAgo, now: now))
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same", lastBatchCreatedAt: anHourAgo, now: now))
    }

    func testScheduledDoesNotSkipPastSixHours() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-7 * 60 * 60), now: now))
    }

    func testNegativeAgeNeverSkips() {
        // Defensive: a clock-skewed "future" timestamp must not be treated as fresh.
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(120), now: now))
    }

    // MARK: shouldSkipRun — a degraded batch shortens the window

    func testDegradedScheduledBatchRetriesWellBeforeSixHours() {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 60 * 60)
        // Identical inputs, one bit apart: a healthy batch still holds the 6h
        // window; a degraded one (producer outage, chart-only fallback) is retried
        // instead of being frozen in the feed until the cause is long gone.
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: twoHoursAgo, lastBatchDegraded: false, now: now))
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: twoHoursAgo, lastBatchDegraded: true, now: now))
    }

    func testDegradedRunsAreStillRateLimited() {
        // Shorter, not zero — a degraded run must not become a retry loop that
        // re-pays the MB/LLM cost on every scheduler tick.
        let now = Date()
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-10 * 60), lastBatchDegraded: true, now: now))
    }

    func testDegradedFlagDefaultsToHealthy() {
        // Callers that predate the flag (and every pre-v45 batch row) keep the
        // original window.
        let now = Date()
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-2 * 60 * 60), now: now))
    }

    // MARK: RunOutcome.degraded

    func testOutcomeIsDegradedWhenNothingSurvived() {
        XCTAssertTrue(RunOutcome(producersContributing: 5, producersEnabled: 6).degraded)
    }

    func testOutcomeIsDegradedWhenTheSelectionIsPureChartFiller() {
        let outcome = RunOutcome(items: [Self.stubItem()], producersContributing: 6,
                                 producersEnabled: 6, personalisedItems: 0)
        XCTAssertTrue(outcome.degraded, "a feed of only generic picks is not a healthy run")
    }

    func testOutcomeIsDegradedWhenMostProducersCameBackEmpty() {
        let outcome = RunOutcome(items: [Self.stubItem()], producersContributing: 2,
                                 producersEnabled: 11, personalisedItems: 1)
        XCTAssertTrue(outcome.degraded)
    }

    func testHealthyRunIsNotDegraded() {
        let outcome = RunOutcome(items: [Self.stubItem()], producersContributing: 8,
                                 producersEnabled: 11, personalisedItems: 1)
        XCTAssertFalse(outcome.degraded)
    }

    func testSingleEnabledProducerIsNotDegradedByTheRatioRule() {
        // Only one producer configured (e.g. Last.fm alone) and it delivered: the
        // majority rule must not label that an outage.
        let outcome = RunOutcome(items: [Self.stubItem()], producersContributing: 1,
                                 producersEnabled: 1, personalisedItems: 1)
        XCTAssertFalse(outcome.degraded)
    }

    private static func stubItem() -> DatabaseManager.StoredRecommendation {
        DatabaseManager.StoredRecommendation(
            kind: .artist, artist: "Foals", artistMbid: nil, album: nil, releaseGroupMbid: nil,
            year: nil, qobuzAlbumID: nil, imageURL: nil, score: 0.5, components: ScoreComponents(),
            sources: [SourceRef(producer: "similar-artist-web")], genres: [], dedupKey: "artist|foals")
    }
}
