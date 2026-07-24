import XCTest
@testable import RoonSageCore

/// Covers the record-label browse dimension: backfill from the dataset label
/// column, listing/sorting, exact merge + undo, and deterministic label-of-week.
final class LabelStoreTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-labels-\(UUID().uuidString)", isDirectory: true)
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

    func testRebuildGroupsAlbumsByLabel() async throws {
        try await seed()
        let store = LabelStore(database: db)
        _ = await store.rebuild()
        let labels = await store.labels(sortedBy: .albumCount)
        XCTAssertEqual(labels.map(\.name), ["Blue Note", "ECM"], "sorted by album count desc")
        XCTAssertEqual(labels.first?.albumCount, 2, "Blue Note has two albums")
        // Idempotent: a second rebuild doesn't duplicate album_label rows.
        _ = await store.rebuild()
        let afterRebuild = await store.labels()
        XCTAssertEqual(afterRebuild.first?.albumCount, 2)
    }

    func testMergeThenUndoRestoresExactState() async throws {
        try await seed()
        let store = LabelStore(database: db)
        _ = await store.rebuild()
        let before = await store.labels(sortedBy: .albumCount)
        let blueNote = try XCTUnwrap(before.first { $0.name == "Blue Note" })
        let ecm = try XCTUnwrap(before.first { $0.name == "ECM" })

        await store.mergeLabels(from: ecm.id, into: blueNote.id)
        let merged = await store.labels()
        XCTAssertEqual(merged.map(\.name), ["Blue Note"], "ECM folded into Blue Note")
        XCTAssertEqual(merged.first?.albumCount, 3, "all three albums now under Blue Note")

        await store.undoMerge(from: ecm.id)
        let restored = await store.labels(sortedBy: .albumCount)
        XCTAssertEqual(Set(restored.map(\.name)), ["Blue Note", "ECM"], "both labels back")
        XCTAssertEqual(restored.first { $0.name == "Blue Note" }?.albumCount, 2, "exact prior counts")
        XCTAssertEqual(restored.first { $0.name == "ECM" }?.albumCount, 1)
    }

    func testAlbumsForLabel() async throws {
        try await seed()
        let store = LabelStore(database: db)
        _ = await store.rebuild()
        let all = await store.labels()
        let blueNote = try XCTUnwrap(all.first { $0.name == "Blue Note" })
        let albums = await store.albums(forLabel: blueNote.id).map(\.albumKey).sorted()
        XCTAssertEqual(albums, ["ak-A", "ak-B"])
    }

    func testWeekIndexIsDeterministicAndRotates() {
        let w1 = Date(timeIntervalSince1970: 0)            // 1970-01-01, ISO week 1
        let w2 = Date(timeIntervalSince1970: 7 * 86_400)   // 1970-01-08, ISO week 2
        XCTAssertEqual(LabelStore.weekIndex(for: w1, count: 5), LabelStore.weekIndex(for: w1, count: 5))
        XCTAssertNotEqual(LabelStore.weekIndex(for: w1, count: 5), LabelStore.weekIndex(for: w2, count: 5))
        for c in 1...10 { XCTAssertTrue((0..<c).contains(LabelStore.weekIndex(for: w1, count: c))) }
        XCTAssertEqual(LabelStore.weekIndex(for: w1, count: 0), 0)
    }

    // MARK: - Fixtures: 3 albums, labels via track_audio_features.label

    private func seed() async throws {
        try await db.upsertTracks([
            track("A1", album: "A", mk: "mk-a1"), track("A2", album: "A", mk: "mk-a2"),
            track("B1", album: "B", mk: "mk-b1"),
            track("C1", album: "C", mk: "mk-c1"),
        ])
        try await setLabel("mk-a1", "Blue Note"); try await setLabel("mk-a2", "Blue Note")
        try await setLabel("mk-b1", "Blue Note")
        try await setLabel("mk-c1", "ECM")
    }

    private func track(_ id: String, album: String, mk: String) -> TrackRecord {
        TrackRecord(id: id, title: id, artist: "Artist \(album)", album: album,
                    albumKey: "ak-\(album)", year: 1965, matchKey: mk)
    }

    private func setLabel(_ matchKey: String, _ label: String) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO track_audio_features(match_key, label) VALUES (?,?)",
                           arguments: [matchKey, label])
        }
    }
}
