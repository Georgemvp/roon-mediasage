import GRDB
import XCTest
@testable import RoonSageCore

/// Guards the indexes the hot browse queries depend on.
///
/// A missing index is silent: the query still returns the right rows, just via a
/// full table scan. The artist grid shipped that way until it was measured on the
/// real 87.820-track library — 27,0 ms → 2,5 ms per query once indexed. These
/// tests fail loudly if a migration is ever dropped or renamed.
final class SchemaIndexTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-index-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func indexNames() async throws -> Set<String> {
        try await db.pool.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name IS NOT NULL"))
        }
    }

    func testBrowseIndexesExistAfterMigration() async throws {
        let names = try await indexNames()
        // Titles were already covered; the artist grid was not (v47).
        XCTAssertTrue(names.contains("idx_tracks_lower_title_artist"),
                      "title/artist browse index missing — the track list falls back to a scan")
        XCTAssertTrue(names.contains("idx_tracks_lower_artist"),
                      "artist browse index missing — the artist grid falls back to a full scan")
        XCTAssertTrue(names.contains("idx_tracks_album_key"),
                      "album_key index missing — album drill-down falls back to a scan")
    }

    /// The plan, not the clock: timings are too noisy in CI, but "does SQLite
    /// choose the index" is deterministic.
    func testArtistGridQueryUsesTheIndex() async throws {
        // EXPLAIN QUERY PLAN yields (id, parent, notused, detail) — the readable
        // part is `detail`; fetching the first column just gives row ids.
        let plan = try await db.pool.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT artist, COUNT(DISTINCT album_key) FROM tracks
                WHERE artist IS NOT NULL
                GROUP BY LOWER(artist) ORDER BY LOWER(artist) LIMIT 120
                """).compactMap { $0["detail"] as String? }
        }.joined(separator: " | ")
        XCTAssertTrue(plan.contains("idx_tracks_lower_artist"),
                      "artist grid no longer uses its index — plan was: \(plan)")
    }
}
