@testable import RoonSageCore
import XCTest

/// Covers the per-client request budget: ordinary use is untouched, sustained
/// hammering is refused with a wait, the expensive routes share one tight bucket,
/// clients don't starve each other, and the store stays bounded.
final class RequestLimiterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Classification

    func testHealthAndEventsAreExempt() {
        XCTAssertNil(RequestLimiter.budget(forPath: "/health"))
        XCTAssertNil(RequestLimiter.budget(forPath: "/events"))
    }

    func testExpensiveRoutesShareTheHeavyBucket() {
        XCTAssertEqual(RequestLimiter.bucketClass(forPath: "/generate"), "heavy")
        XCTAssertEqual(RequestLimiter.bucketClass(forPath: "/discovery/run"), "heavy")
        XCTAssertEqual(RequestLimiter.bucketClass(forPath: "/library"), "heavy")
        XCTAssertEqual(RequestLimiter.bucketClass(forPath: "/discover-weekly/refresh"), "heavy")
        XCTAssertEqual(RequestLimiter.bucketClass(forPath: "/playback"), "default")
    }

    // MARK: - Ordinary use

    func testNormalBurstIsNeverRefused() async {
        let limiter = RequestLimiter()
        // A screen opening fans out a handful of calls at once; that must pass.
        for i in 0..<20 {
            let wait = await limiter.consume(client: "phone", path: "/playback", now: t0)
            XCTAssertNil(wait, "aanroep \(i) hoorde binnen het budget te vallen")
        }
    }

    func testSustainedHammeringIsRefusedWithAWait() async {
        let limiter = RequestLimiter()
        var refusedAt: Int?
        for i in 0..<120 {
            if let wait = await limiter.consume(client: "phone", path: "/playback", now: t0) {
                refusedAt = i
                XCTAssertGreaterThanOrEqual(wait, 1, "een weigering moet een wachttijd noemen")
                break
            }
        }
        XCTAssertNotNil(refusedAt, "onbegrensd hameren hoort geweigerd te worden")
        XCTAssertGreaterThanOrEqual(refusedAt ?? 0, 60, "pas ná de burst-capaciteit")
    }

    // MARK: - Heavy routes

    func testHeavyRouteAllowsASmallBurstThenRefuses() async {
        let limiter = RequestLimiter()
        // Three is a human pressing refresh a few times; the fourth is a loop.
        for i in 0..<3 {
            let wait = await limiter.consume(client: "phone", path: "/discovery/run", now: t0)
            XCTAssertNil(wait, "handmatige poging \(i) hoort te mogen")
        }
        let refusedFourth = await limiter.consume(client: "phone", path: "/discovery/run", now: t0)
        XCTAssertNotNil(refusedFourth, "de vierde op rij is een lus, geen mens")
    }

    func testHeavyRoutesShareOneBudgetPerClient() async {
        let limiter = RequestLimiter()
        _ = await limiter.consume(client: "phone", path: "/generate", now: t0)
        _ = await limiter.consume(client: "phone", path: "/discovery/run", now: t0)
        _ = await limiter.consume(client: "phone", path: "/library", now: t0)
        // Budget spent across three different heavy routes — a fourth must fail,
        // otherwise three loops on three routes would be three times the load.
        let refused = await limiter.consume(client: "phone", path: "/generate", now: t0)
        XCTAssertNotNil(refused)
    }

    func testTokensRefillOverTime() async {
        let limiter = RequestLimiter()
        for _ in 0..<3 { _ = await limiter.consume(client: "phone", path: "/generate", now: t0) }
        // Note: XCTAssert takes its expression as an @autoclosure, which cannot
        // carry an `await` — hence the separate lets throughout this file.
        let exhausted = await limiter.consume(client: "phone", path: "/generate", now: t0)
        XCTAssertNotNil(exhausted)

        // heavyBudget refills one token per 30 s.
        let later = t0.addingTimeInterval(35)
        let afterRefill = await limiter.consume(client: "phone", path: "/generate", now: later)
        XCTAssertNil(afterRefill, "na de bijvultijd moet er weer ruimte zijn")
    }

    // MARK: - Isolation and bounds

    func testOneClientCannotStarveAnother() async {
        let limiter = RequestLimiter()
        for _ in 0..<200 { _ = await limiter.consume(client: "loop", path: "/playback", now: t0) }
        let loopRefused = await limiter.consume(client: "loop", path: "/playback", now: t0)
        XCTAssertNotNil(loopRefused)

        let other = await limiter.consume(client: "rustige-mac", path: "/playback", now: t0)
        XCTAssertNil(other, "een ander apparaat mag geen last hebben van de lus")
    }

    func testBucketStoreStaysBounded() async {
        let limiter = RequestLimiter()
        for i in 0..<(RequestLimiter.maxBuckets + 50) {
            _ = await limiter.consume(client: "client-\(i)", path: "/playback",
                                      now: t0.addingTimeInterval(Double(i)))
        }
        let count = await limiter.bucketCount()
        XCTAssertLessThanOrEqual(count, RequestLimiter.maxBuckets,
                                 "roterende tokens mogen de store niet laten groeien")
    }

    func testExemptPathsNeverConsume() async {
        let limiter = RequestLimiter()
        for _ in 0..<1000 {
            let wait = await limiter.consume(client: "phone", path: "/health", now: t0)
            XCTAssertNil(wait)
        }
        let count = await limiter.bucketCount()
        XCTAssertEqual(count, 0, "vrijgestelde paden maken geen emmer aan")
    }
}
