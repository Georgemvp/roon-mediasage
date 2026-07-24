import XCTest
@testable import RoonSageCore

/// Covers the editorial_cache layer that backs artist bios + album reviews:
/// cache-hit within TTL, negative caching, staleness past TTL, and upsert.
final class EditorialClientTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-editorial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("library.db")
        db = try DatabaseManager(url: dbURL)
    }

    override func tearDownWithError() throws {
        db = nil
        if let dir = dbURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testMissWhenNothingCached() async {
        let result = await db.cachedEditorial(entityType: "artist", entityKey: "nobody", kind: "bio", maxAgeDays: 30)
        guard case .missing = result else { return XCTFail("expected .missing, got \(result)") }
    }

    func testSavedEditorialIsFreshWithinTTL() async {
        await db.saveEditorial(entityType: "artist", entityKey: "radiohead", kind: "bio",
                               editorial: Editorial(body: "An English rock band.", source: "Wikipedia"))
        let result = await db.cachedEditorial(entityType: "artist", entityKey: "radiohead", kind: "bio", maxAgeDays: 30)
        guard case .fresh(let editorial) = result else { return XCTFail("expected .fresh, got \(result)") }
        XCTAssertEqual(editorial?.body, "An English rock band.")
        XCTAssertEqual(editorial?.source, "Wikipedia")
    }

    func testNegativeResultCachesAsFreshNil() async {
        // A known-absent lookup caches too, so we don't re-hit every source per visit.
        await db.saveEditorial(entityType: "album", entityKey: "obscure|nobody", kind: "review", editorial: nil)
        let result = await db.cachedEditorial(entityType: "album", entityKey: "obscure|nobody", kind: "review", maxAgeDays: 30)
        guard case .fresh(let editorial) = result else { return XCTFail("expected .fresh(nil), got \(result)") }
        XCTAssertNil(editorial, "negative cache is fresh-but-empty, not a re-fetch trigger")
    }

    func testStalePastTTL() async throws {
        // Backdate the row 40 days so a 30-day TTL treats it as stale → re-fetch.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40 * 86_400))
        try await db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO editorial_cache (entity_type, entity_key, kind, body, source, fetched_at)
                VALUES ('artist','stale-artist','bio','old text','Wikipedia',?)
                """, arguments: [old])
        }
        let result = await db.cachedEditorial(entityType: "artist", entityKey: "stale-artist", kind: "bio", maxAgeDays: 30)
        guard case .stale = result else { return XCTFail("expected .stale, got \(result)") }
    }

    func testUpsertOverwritesBody() async {
        let key = "aphex twin"
        await db.saveEditorial(entityType: "artist", entityKey: key, kind: "bio",
                               editorial: Editorial(body: "first", source: "Last.fm"))
        await db.saveEditorial(entityType: "artist", entityKey: key, kind: "bio",
                               editorial: Editorial(body: "second", source: "Wikipedia"))
        let result = await db.cachedEditorial(entityType: "artist", entityKey: key, kind: "bio", maxAgeDays: 30)
        guard case .fresh(let editorial) = result else { return XCTFail("expected .fresh, got \(result)") }
        XCTAssertEqual(editorial?.body, "second", "second save overwrites, not duplicates")
        XCTAssertEqual(editorial?.source, "Wikipedia")
    }
}
