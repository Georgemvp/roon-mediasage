@testable import AnalyzerCore
import AudioAnalysis
import Foundation
import GRDB
import XCTest

/// Hard identity in the analyser store (FeatureStore + IdentityBackfill): the
/// tag/dataset precedence, the repair of rows whose artist or album held a
/// MusicBrainz id instead of a name, and the corpus signature that decides
/// whether clients ever re-pull any of it.
final class IdentityStoreTests: XCTestCase {

    private let mbid = "300c4c73-33ac-4255-9d57-4e32627f5e13"

    private func makeStore() throws -> (FeatureStore, String) {
        let path = NSTemporaryDirectory() + "identity_\(UUID().uuidString).sqlite"
        return (try FeatureStore(path: path), path)
    }

    /// Read a raw column. FeatureStore's connection is private and `featureRow`
    /// doesn't carry `identity_source`, so the test opens its own reader on the
    /// same file rather than widening production access for a test.
    private func column(_ name: String, key: String, at path: String) throws -> String? {
        try DatabaseQueue(path: path).read { db in
            try String.fetchOne(db, sql: "SELECT \(name) FROM track_features WHERE match_key = ?",
                                arguments: [key])
        }
    }

    /// Make a row look like it was analysed before the identity columns existed:
    /// that is what every one of the 66.378 rows in the real library looks like,
    /// and it is the only state the backfill ever sees.
    private func makeLegacy(_ keys: [String], at path: String) throws {
        try DatabaseQueue(path: path).write { db in
            for k in keys {
                try db.execute(sql: """
                    UPDATE track_features SET identity_checked_at = NULL, identity_source = NULL
                    WHERE match_key = ?
                """, arguments: [k])
            }
        }
    }

    private func row(_ mk: String, artist: String, album: String, title: String = "T",
                     path: String = "/m/1.flac", isrc: String? = nil) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: mk, artist: artist, title: title, album: album, year: 2001,
            filePath: path, fileMtime: 1, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: nil, analyzedAt: "2026-06-27T00:00:00Z", isrc: isrc)
    }

    // MARK: - Precedence between the two writers

    func testTagISRCWinsButAbsenceDoesNotWipeTheDatasetValue() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsertBatch([
            row("a\u{1f}one", artist: "A", album: "Blue", isrc: "GBAYE9900123"),
            row("a\u{1f}two", artist: "A", album: "Blue", isrc: "GBAYE9900456"),
        ])
        try makeLegacy(["a\u{1f}one", "a\u{1f}two"], at: path)

        // The file's tags carry a different ISRC → the tag wins, it is in the file.
        try store.setIdentity(matchKey: "a\u{1f}one", isrc: "NLA0Y1234567", recordingMBID: nil,
                              releaseTrackMBID: nil, albumMBID: nil, artistMBID: nil,
                              checkedAt: "2026-08-23T00:00:00Z")
        // The file has no ISRC tag at all → the dataset value must survive.
        try store.setIdentity(matchKey: "a\u{1f}two", isrc: nil, recordingMBID: nil,
                              releaseTrackMBID: nil, albumMBID: nil, artistMBID: nil,
                              checkedAt: "2026-08-23T00:00:00Z")

        XCTAssertEqual(try column("isrc", key: "a\u{1f}one", at: path), "NLA0Y1234567")
        XCTAssertEqual(try column("isrc", key: "a\u{1f}two", at: path), "GBAYE9900456")
        // Source only claims 'tag' where the file actually yielded something.
        XCTAssertEqual(try column("identity_source", key: "a\u{1f}one", at: path), "tag")
        XCTAssertNil(try column("identity_source", key: "a\u{1f}two", at: path))
    }

    func testEveryCheckedRowIsStampedSoTheBackfillConverges() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsertBatch([row("a\u{1f}one", artist: "A", album: "Blue", path: "/m/1.flac")])
        try makeLegacy(["a\u{1f}one"], at: path)

        XCTAssertEqual(store.tracksNeedingIdentity(limit: 10).count, 1)
        try store.setIdentity(matchKey: "a\u{1f}one", isrc: nil, recordingMBID: nil,
                              releaseTrackMBID: nil, albumMBID: nil, artistMBID: nil,
                              checkedAt: "2026-08-23T00:00:00Z")
        XCTAssertTrue(store.tracksNeedingIdentity(limit: 10).isEmpty)
        XCTAssertEqual(store.identityCheckedCount(), 1)
        XCTAssertEqual(store.hardIdentityCount(), 0)
    }

    // MARK: - Repairing the MBID-as-name rows

    func testRepairMovesTheRowToTheKeyTheRealNamesProduce() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bad = TrackIdentity.matchKey(artist: mbid, album: mbid, title: "Golden Blunders")
        try store.upsertBatch([row(bad, artist: mbid, album: mbid, title: "Golden Blunders")])

        let good = TrackIdentity.matchKey(artist: "Ringo Starr", album: "Time Takes Time",
                                          title: "Golden Blunders")
        let outcome = try store.repairIdentityNames(matchKey: bad, artist: "Ringo Starr",
                                                    album: "Time Takes Time", newMatchKey: good)
        XCTAssertEqual(outcome, .rekeyed)
        XCTAssertEqual(try column("artist", key: good, at: path), "Ringo Starr")
        XCTAssertEqual(try column("album", key: good, at: path), "Time Takes Time")
        XCTAssertNil(try column("artist", key: bad, at: path))
    }

    func testRepairDropsTheRowWhenACorrectOneAlreadyExists() throws {
        // Otherwise the library shows the same track twice: once under its real
        // name and once under the UUID.
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let good = TrackIdentity.matchKey(artist: "Ringo Starr", album: "Time Takes Time",
                                          title: "Golden Blunders")
        let bad = TrackIdentity.matchKey(artist: mbid, album: mbid, title: "Golden Blunders")
        try store.upsertBatch([
            row(good, artist: "Ringo Starr", album: "Time Takes Time", title: "Golden Blunders",
                path: "/m/a.flac"),
            row(bad, artist: mbid, album: mbid, title: "Golden Blunders", path: "/m/b.flac"),
        ])
        XCTAssertEqual(store.count(), 2)

        let outcome = try store.repairIdentityNames(matchKey: bad, artist: "Ringo Starr",
                                                    album: "Time Takes Time", newMatchKey: good)
        XCTAssertEqual(outcome, .droppedDuplicate)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(try column("artist", key: good, at: path), "Ringo Starr")
    }

    func testRepairWithAnUnchangedKeyJustRenames() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Only the album was a UUID, and the key ignores album — so the key holds.
        let key = TrackIdentity.matchKey(artist: "Ringo Starr", album: mbid, title: "Golden Blunders")
        try store.upsertBatch([row(key, artist: "Ringo Starr", album: mbid, title: "Golden Blunders")])

        let outcome = try store.repairIdentityNames(matchKey: key, artist: "Ringo Starr",
                                                    album: "Time Takes Time", newMatchKey: key)
        XCTAssertEqual(outcome, .renamed)
        XCTAssertEqual(try column("album", key: key, at: path), "Time Takes Time")
    }

    func testTheBackfillRecognisesAStoredUUIDAsAnIdentifierNotAName() {
        XCTAssertTrue(IdentityBackfill.isMBID(mbid))
        XCTAssertFalse(IdentityBackfill.isMBID("Ringo Starr"))
        XCTAssertFalse(IdentityBackfill.isMBID(nil))
    }

    // MARK: - Propagation to clients

    func testSignatureMovesWhenIdentityIsWrittenInPlace() throws {
        // The trap this shares with moods, arousal and the CLAP retag: the
        // backfill REWRITES isrc on rows that already had a dataset value, so
        // COUNT(isrc) can stay flat while the corpus genuinely changed. Without an
        // identity term in the signature no client would ever re-pull it.
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsertBatch([row("a\u{1f}one", artist: "A", album: "Blue", isrc: "GBAYE9900123")])
        try makeLegacy(["a\u{1f}one"], at: path)
        let before = store.contentSignature()

        try store.setIdentity(matchKey: "a\u{1f}one", isrc: "NLA0Y1234567", recordingMBID: nil,
                              releaseTrackMBID: nil, albumMBID: nil, artistMBID: nil,
                              checkedAt: "2026-08-23T00:00:00Z")
        XCTAssertNotEqual(store.contentSignature(), before)
    }

    func testAnalysedRowsCarryTheirIdentityStraightFromTheWalk() throws {
        // A freshly analysed row never needs the backfill: the walker passes the
        // identity from the same tag read that produced the names.
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var r = row("a\u{1f}one", artist: "A", album: "Blue")
        r.isrc = "GBAYE9900123"
        r.recordingMBID = mbid
        try store.upsertBatch([r])

        XCTAssertEqual(try column("isrc", key: "a\u{1f}one", at: path), "GBAYE9900123")
        XCTAssertEqual(try column("recording_mbid", key: "a\u{1f}one", at: path), mbid)
        XCTAssertEqual(store.hardIdentityCount(), 1)
        XCTAssertTrue(store.tracksNeedingIdentity(limit: 10).isEmpty)
    }

    // MARK: - Measurement against the real library (opt-in)

    /// What this actually does to Casper's analyser DB. Works on a COPY, and is
    /// skipped unless the source is named explicitly:
    ///
    ///     ROONSAGE_REAL_ANALYZER_DB="$HOME/Library/Application Support/RoonSageAnalyzer/analyzer.db" \\
    ///     swift test --filter testMeasureIdentityAgainstTheRealLibrary
    ///
    /// Reading 66.378 tag blocks off the external drive takes minutes, so the run
    /// is scoped: every UUID-named row (the ones the reader bug produced) plus a
    /// random sample. The rest is pre-stamped as checked, which is exactly what
    /// the backfill would leave behind anyway.
    func testMeasureIdentityAgainstTheRealLibrary() async throws {
        guard let src = ProcessInfo.processInfo.environment["ROONSAGE_REAL_ANALYZER_DB"] else {
            throw XCTSkip("Set ROONSAGE_REAL_ANALYZER_DB to measure.")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rs-identity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("analyzer.db")
        try fm.copyItem(at: URL(fileURLWithPath: src), to: copy)

        let uuidLike = "artist GLOB '[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*' AND length(artist) = 36"
        let queue = try DatabaseQueue(path: copy.path)
        let store = try FeatureStore(path: copy.path)   // runs the migration first

        struct Counts { var total = 0; var isrc = 0; var uuidNames = 0; var scoped = 0 }
        func counts() async throws -> Counts {
            try await queue.read { db in
                var c = Counts()
                c.total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features") ?? 0
                c.isrc = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE isrc IS NOT NULL AND isrc != ''") ?? 0
                c.uuidNames = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE \(uuidLike)") ?? 0
                c.scoped = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE identity_checked_at IS NULL") ?? 0
                return c
            }
        }

        // Scope: every UUID-named row + 1500 random others.
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE track_features SET identity_checked_at = 'scoped-out'
                WHERE NOT (\(uuidLike))
                  AND match_key NOT IN (
                    SELECT match_key FROM track_features WHERE NOT (\(uuidLike)) ORDER BY RANDOM() LIMIT 1500
                  )
            """)
        }
        let before = try await counts()
        let scopedISRCBefore = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE identity_checked_at IS NULL AND isrc IS NOT NULL AND isrc != ''") ?? 0
        }

        let backfill = IdentityBackfill(store: store, batch: 250, throttleMs: 0)
        let repaired = await backfill.run { _ in }
        let after = try await counts()
        let scopedISRCAfter = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE identity_checked_at != 'scoped-out' AND isrc IS NOT NULL AND isrc != ''") ?? 0
        }
        let mbids = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE recording_mbid IS NOT NULL OR release_track_mbid IS NOT NULL") ?? 0
        }

        print("""
            METING harde identiteit uit de tags
              rijen in de kopie          : \(before.total)
              in scope gezet             : \(before.scoped)
              ISRC binnen die scope      : \(scopedISRCBefore) -> \(scopedISRCAfter)
              MusicBrainz-ids gevonden   : \(mbids)
              artiest = UUID             : \(before.uuidNames) -> \(after.uuidNames)
              rijen hersteld             : \(repaired)
              rijen totaal               : \(before.total) -> \(after.total)
            """)

        XCTAssertEqual(after.uuidNames, 0, "elke UUID-als-naam moet hersteld zijn")
        XCTAssertGreaterThan(scopedISRCAfter, scopedISRCBefore)
    }
}
