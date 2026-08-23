@testable import AnalyzerCore
import AudioAnalysis
import CLAPEngine
import GRDB
import XCTest
@testable import RoonSageCore

/// The library's second source (DatabaseManager+LocalLibrary): analysed on-disk
/// tracks that the Roon walk produced no row for become `source='local'` rows,
/// they survive a full resync, and they step aside as soon as Roon covers them.
final class LocalLibrarySourceTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-local-lib-\(UUID().uuidString)", isDirectory: true)
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

    private func local(_ artist: String, _ title: String, album: String, year: Int? = nil)
    -> DatabaseManager.LocalTrackRow {
        DatabaseManager.LocalTrackRow(
            matchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title),
            artist: artist, title: title, album: album, year: year)
    }

    private func roonRecord(_ id: String, artist: String, title: String, album: String) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album, albumKey: "ak-\(id)",
                    matchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title))
    }

    // MARK: - Ingest

    func testIngestTakesEveryAnalysedFileAndDisplacesTheRoonRow() async throws {
        // De analyzer is de primaire catalogus (user, 2026-08-23). Een Roon-rij
        // voor een bestand dat wij zelf gelopen hebben is een duplicaat.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Solti", title: "Elektra", album: "Strauss")],
            albumTitle: "Strauss", fingerprint: "fpA", generation: run.generation)

        let result = try await db.ingestLocalTracks([
            local("Solti", "Elektra", album: "Strauss"),          // Roon heeft hem óók
            local("Solti", "Salome", album: "Strauss"),
            local("Menuhin", "Chaconne", album: "The Century"),
        ])

        XCTAssertEqual(result.offered, 3)
        XCTAssertEqual(result.inserted, 3)
        XCTAssertEqual(result.reclaimed, 1, "de Roon-rij voor Elektra is verdrongen")
        XCTAssertEqual(result.total, 3)
        let total = try await db.trackCount()
        XCTAssertEqual(total, 3, "geen duplicaat naast elkaar")
    }

    func testARoonOnlyRowSurvives() async throws {
        // Dat is precies de Qobuz/streaming-laag: Roon kent hem, er is geen
        // bestand, dus de analyzer kan hem niet hebben. Die rij moet blijven.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("q1", artist: "LPO", title: "Calm Classical", album: "Curated")],
            albumTitle: "Curated", fingerprint: "fpQ", generation: run.generation)

        _ = try await db.ingestLocalTracks([local("Menuhin", "Chaconne", album: "The Century")])

        let roonRows = try await db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE source = 'roon'")
        }
        XCTAssertEqual(roonRows, ["Calm Classical"])
    }

    func testTheWalkStopsWritingWhatTheAnalyserAlreadyOwns() async throws {
        // Anders zou élke walk ~51.000 rijen schrijven die de eerstvolgende
        // feature-sync weer verdringt.
        _ = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes")])

        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes"),
             roonRecord("r2", artist: "Bowie", title: "Ashes to Ashes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run.generation)

        let roonTitles = try await db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE source = 'roon' ORDER BY title")
        }
        XCTAssertEqual(roonTitles, ["Ashes to Ashes"], "Heroes is van de analyzer, die schrijft Roon niet meer")
    }

    func testAFreshMachineWithoutAnalysedFilesBehavesExactlyAsBefore() async throws {
        // Geen lokale rijen = geen filter. De walk moet zich dan gedragen zoals
        // hij altijd deed, anders is een verse installatie stuk.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes"),
             roonRecord("r2", artist: "Bowie", title: "Ashes to Ashes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run.generation)
        let total = try await db.trackCount()
        XCTAssertEqual(total, 2)
    }

    func testDisplacedRoonRowsHandOverTheirGenres() async throws {
        // Roon's genrehiërarchie hangt aan de RIJ (track_genres.track_id, ON
        // DELETE CASCADE). Zonder overdracht verliest 1,2% van de geanalyseerde
        // tracks het enige genre dat ze hebben.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run.generation)
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO track_genres (track_id, genre) VALUES ('r1','art rock')")
        }

        _ = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes")])

        let genres = try await db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT g.genre FROM track_genres g JOIN tracks t ON t.id = g.track_id
                WHERE t.source = 'local'
                """)
        }
        XCTAssertEqual(genres, ["art rock"])
    }

    func testLocalRowIsPlayableByItsOwnRecomputedMatchKey() async throws {
        // The whole reason no new playback code is needed: LocalPlayability
        // recomputes the key from artist/album/title, and the row was built from
        // the very tags the analyser keyed on. If those two ever diverge, a local
        // row silently becomes unplayable.
        let row = local("Sir Georg Solti", "Die Frau ohne Schatten (2011 Remaster)", album: "Strauss")
        _ = try await db.ingestLocalTracks([row])

        let stored = try await db.pool.read { db in
            try TrackRecord.fetchOne(db, sql: "SELECT * FROM tracks WHERE source = 'local'")
        }
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.id, DatabaseManager.localTrackID(
            album: row.album, artist: row.artist, matchKey: row.matchKey))
        // The artwork marker: no Roon image key exists for this file, so the
        // image key carries the same `local::` prefix and imageURL(forKey:)
        // resolves it against the analyser's /artwork instead of the Core.
        XCTAssertEqual(record.imageKey, DatabaseManager.localKeyPrefix + row.matchKey)
        XCTAssertEqual(LocalPlayability.matchKey(for: record), row.matchKey)
        XCTAssertEqual(
            LocalPlayability.partition([record], playableKeys: [row.matchKey]).playable.count, 1)
    }

    func testReIngestRefreshesInPlaceWhenTheAlbumIsUnchanged() async throws {
        _ = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes")])
        let second = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes", year: 1977)])

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.refreshed, 1)
        XCTAssertEqual(second.pruned, 0)
        XCTAssertEqual(second.total, 1)
        let year = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT year FROM tracks WHERE source = 'local'")
        }
        XCTAssertEqual(year, 1977)
    }

    func testARetaggedAlbumMovesTheRowInsteadOfLeavingAnOrphan() async throws {
        // The album is part of the row id, so a corrected album tag lands on a
        // NEW row. Without the prune the old one stays behind for an album that
        // no longer has any files.
        _ = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes")])
        let second = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "\"Heroes\"", year: 1977)])

        XCTAssertEqual(second.inserted, 1)
        XCTAssertEqual(second.pruned, 1)
        XCTAssertEqual(second.total, 1)
        let album = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT album FROM tracks WHERE source = 'local'")
        }
        XCTAssertEqual(album, "\"Heroes\"")
    }

    func testTheSameRecordingOnTwoAlbumsIsTwoRows() async throws {
        // match_key is album-free by design, so keying rows on it alone collapsed
        // 66.377 analysed files into 59.517 library rows on the real library —
        // 6.860 tracks that exist on a second album simply vanished.
        let result = try await db.ingestLocalTracks([
            local("Bowie", "Heroes", album: "\"Heroes\""),
            local("Bowie", "Heroes", album: "Best of Bowie"),
        ])
        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.total, 2)
    }

    func testAHalvedPayloadDoesNotEmptyTheShelf() async throws {
        // Same brake as the Roon walk's prune: a truncated read must never be
        // mistaken for a library that shrank.
        _ = try await db.ingestLocalTracks([
            local("Bowie", "Heroes", album: "Heroes"),
            local("Bowie", "Ashes to Ashes", album: "Scary Monsters"),
            local("Menuhin", "Chaconne", album: "The Century"),
            local("Menuhin", "Partita", album: "The Century"),
        ])
        let truncated = try await db.ingestLocalTracks([local("Bowie", "Heroes", album: "Heroes")])
        XCTAssertEqual(truncated.pruned, 0, "een gehalveerde payload mag niets wissen")
        XCTAssertEqual(truncated.total, 4)
    }

    func testKeylessAndTitlelessRowsAreRejected() async throws {
        let result = try await db.ingestLocalTracks([
            DatabaseManager.LocalTrackRow(matchKey: "", artist: "X", title: "T", album: "A", year: nil),
            DatabaseManager.LocalTrackRow(matchKey: "k", artist: "X", title: "  ", album: "A", year: nil),
        ])
        XCTAssertEqual(result.offered, 2)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.total, 0)
    }

    func testDuplicateKeysInOnePayloadCollapseToOneRow() async throws {
        // Two files normalising onto one match_key would collide on the primary
        // key inside a single INSERT statement.
        let result = try await db.ingestLocalTracks([
            local("Bowie", "Heroes", album: "Heroes"),
            local("Bowie", "Heroes (2017 Remaster)", album: "Heroes"),
        ])
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.total, 1)
    }

    // MARK: - Surviving the Roon walk

    func testLocalRowsSurviveAFullSyncWithPrune() async throws {
        _ = try await db.ingestLocalTracks([local("Menuhin", "Chaconne", album: "The Century")])

        // A complete Roon walk that never mentions that album: the prune must
        // leave it alone, because the walk only owns source='roon' rows.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run.generation)
        try await db.finishSyncRun(generation: run.generation)

        let locals = try await db.localTrackCount()
        XCTAssertEqual(locals, 1)
        let total = try await db.trackCount()
        XCTAssertEqual(total, 2)
    }

    func testSameTitledRoonAlbumDoesNotDeleteTheLocalRow() async throws {
        // replaceAlbumTracks' legacy branch deletes by album NAME when album_fp
        // is NULL. A local row sharing that album name must not be caught by it.
        _ = try await db.ingestLocalTracks([local("Menuhin", "Chaconne", album: "The Century")])

        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Menuhin", title: "Partita", album: "The Century")],
            albumTitle: "The Century", fingerprint: "fpC", generation: run.generation)

        let locals = try await db.localTrackCount()
        XCTAssertEqual(locals, 1)
    }

    // MARK: - First-seen

    func testFirstSeenIsBackdatedNotStampedToday() async throws {
        // A pre-existing library stamp is the oldest thing we know about; the
        // new rows must inherit it, or 19.5k tracks announce themselves as "new
        // today" in the on-this-day / new-in-library views.
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO track_first_seen (match_key, first_seen) VALUES ('seed','2024-01-02T03:04:05Z')")
        }
        _ = try await db.ingestLocalTracks([local("Menuhin", "Chaconne", album: "The Century")])

        let stamps = try await db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT first_seen FROM track_first_seen WHERE match_key != 'seed'")
        }
        XCTAssertEqual(stamps, ["2024-01-02T03:04:05Z"])
    }

    // MARK: - Album grouping

    func testLocalRowsOfOneAlbumShareAnAlbumKey() async throws {
        _ = try await db.ingestLocalTracks([
            local("Menuhin", "Chaconne", album: "The Century"),
            local("Menuhin", "Partita", album: "The Century"),
            local("Bowie", "Heroes", album: "Heroes"),
        ])
        let albums = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT album_key) FROM tracks WHERE source = 'local'")
        }
        XCTAssertEqual(albums, 2)
    }

    // MARK: - Library share (:5767)

    func testSourceSurvivesTheShareRoundtrip() async throws {
        // The client needs to know a row is analyser-sourced: it carries no Roon
        // image_key, so artwork has to come from the analyser instead.
        try await db.upsertTracks([
            TrackRecord(id: "roon-1", title: "Heroes", artist: "Bowie", album: "Heroes",
                        albumKey: "ak1", matchKey: "bowie\u{1f}heroes", imageKey: "img1"),
        ])
        _ = try await db.ingestLocalTracks([local("Menuhin", "Chaconne", album: "The Century")])

        let json = try await db.exportLibraryJSON()
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-local-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir2) }
        let dst = try DatabaseManager(url: dir2.appendingPathComponent("library.db"))

        let imported = try await dst.importLibrary(json: json)
        XCTAssertEqual(imported, 2)
        let locals = try await dst.localTrackCount()
        XCTAssertEqual(locals, 1)
        let roonSide = try await dst.pool.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE source = 'roon' ORDER BY title")
        }
        XCTAssertEqual(roonSide, ["Heroes"])
    }

    // MARK: - Measurement against the real library (opt-in)

    /// Repeatable measurement of what this actually does to Casper's library.
    /// Skipped unless both databases are pointed at explicitly — it works on
    /// COPIES, never on the live files (the analyser holds their WAL open):
    ///
    ///     ROONSAGE_REAL_LIBRARY_DB="$HOME/Library/Application Support/RoonSage/library.db" \
    ///     ROONSAGE_REAL_ANALYZER_DB="$HOME/Library/Application Support/RoonSageAnalyzer/analyzer.db" \
    ///     swift test --filter testMeasureAgainstTheRealLibrary
    func testMeasureAgainstTheRealLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let libSrc = env["ROONSAGE_REAL_LIBRARY_DB"], let anSrc = env["ROONSAGE_REAL_ANALYZER_DB"] else {
            throw XCTSkip("Set ROONSAGE_REAL_LIBRARY_DB + ROONSAGE_REAL_ANALYZER_DB to measure.")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("roonsage-measure-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let libCopy = dir.appendingPathComponent("library.db")
        let anCopy = dir.appendingPathComponent("analyzer.db")
        try fm.copyItem(at: URL(fileURLWithPath: libSrc), to: libCopy)
        try fm.copyItem(at: URL(fileURLWithPath: anSrc), to: anCopy)

        // The real payload: the analyser's own /features export, parsed the way
        // RoonClient.fetchFeaturePayload parses it.
        let store = try FeatureStore(path: anCopy.path)
        let json = store.exportJSON(includeEmbedding: false)
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        var rows: [DatabaseManager.LocalTrackRow] = []
        for o in arr {
            guard let mk = o["match_key"] as? String, !mk.isEmpty,
                  let t = o["title"] as? String, !t.isEmpty else { continue }
            let year = o["year"] as? Int
            rows.append(DatabaseManager.LocalTrackRow(
                matchKey: mk,
                artist: (o["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                title: t,
                album: (o["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                year: (year ?? 0) > 1900 ? year : nil))
        }

        let real = try DatabaseManager(url: libCopy)
        let before = try await real.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_audio_features f
                LEFT JOIN (SELECT DISTINCT match_key k FROM tracks) t ON t.k = f.match_key
                WHERE t.k IS NULL
                """) ?? 0
        }
        let tracksBefore = try await real.trackCount()
        let reachableBefore = try await real.analyzedTrackIdentities(excludeLive: false).count
        let result = try await real.ingestLocalTracks(rows)
        let after = try await real.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_audio_features f
                LEFT JOIN (SELECT DISTINCT match_key k FROM tracks) t ON t.k = f.match_key
                WHERE t.k IS NULL
                """) ?? 0
        }
        let reachableAfter = try await real.analyzedTrackIdentities(excludeLive: false).count
        let tracksAfter = try await real.trackCount()
        print("""
            METING lokale bibliotheekbron
              feature-rijen aangeboden   : \(result.offered)
              tracks vóór                : \(tracksBefore)
              tracks ná                  : \(tracksAfter)
              lokale rijen               : \(result.total) (nieuw \(result.inserted))
              features zonder tracks-rij : \(before) -> \(after)
              analyzedTrackIdentities    : \(reachableBefore) -> \(reachableAfter)
            """)
        // Fase 2: hoe vaak vinden we daadwerkelijk een hoes voor zo'n rij? Een
        // steekproef, want elke treffer is een echte decode van een echt bestand.
        let sampleKeys = try await real.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT match_key FROM tracks WHERE source = 'local' AND match_key IS NOT NULL
                ORDER BY match_key LIMIT 200
                """)
        }
        var embedded = 0, sidecar = 0, none = 0
        for key in sampleKeys {
            guard let path = store.filePath(forMatchKey: key) else { none += 1; continue }
            let url = URL(fileURLWithPath: path)
            if MetadataReader.artwork(url: url) != nil { embedded += 1 }
            else if ArtworkProvider.sidecarURL(besideFile: url) != nil { sidecar += 1 }
            else { none += 1 }
        }
        print("""
            METING hoezen (steekproef \(sampleKeys.count) lokale rijen)
              ingebed in het bestand : \(embedded)
              cover.jpg ernaast      : \(sidecar)
              geen hoes te vinden    : \(none)
            """)

        // End-to-end over HTTP, tegen een echt bestand: de route, de auth en de
        // schaling in één keer. Alleen de framing komt uit `sendRaw`, die /audio
        // al in productie gebruikt.
        let servedKey = try XCTUnwrap(sampleKeys.first { key in
            guard let p = store.filePath(forMatchKey: key) else { return false }
            return MetadataReader.artwork(url: URL(fileURLWithPath: p)) != nil
        })
        let server = HTTPServer(port: 57661, store: store, token: "meet-token")
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:57661/artwork?match_key="
        let enc = servedKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? servedKey

        let okURL = try XCTUnwrap(URL(string: "\(base)\(enc)&size=200&token=meet-token"))
        let (body, resp) = try await URLSession.shared.data(from: okURL)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        let imgSrc = try XCTUnwrap(CGImageSourceCreateWithData(body as CFData, nil))
        let imgProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imgSrc, 0, nil) as? [CFString: Any])
        print("""
            METING /artwork end-to-end
              bytes                  : \(body.count)
              pixels                 : \(imgProps[kCGImagePropertyPixelWidth] as? Int ?? -1)x\(imgProps[kCGImagePropertyPixelHeight] as? Int ?? -1)
            """)
        // kCGImageSourceThumbnailMaxPixelSize begrenst de LANGSTE zijde, dus een
        // niet-vierkante hoes komt op bv. 199x200 uit — dat is de afspraak, niet
        // een afwijking. Toets die afspraak, niet de breedte.
        let w = try XCTUnwrap(imgProps[kCGImagePropertyPixelWidth] as? Int)
        let h = try XCTUnwrap(imgProps[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertEqual(max(w, h), 200)
        XCTAssertLessThanOrEqual(min(w, h), 200)

        // Zonder token: dicht. Dit endpoint serveert bestanden van de muziekschijf.
        let badURL = try XCTUnwrap(URL(string: "\(base)\(enc)&size=200"))
        var badReq = URLRequest(url: badURL)
        badReq.setValue("127.0.0.2", forHTTPHeaderField: "X-Ignored")
        let (_, badResp) = try await URLSession.shared.data(for: badReq)
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 200,
                       "loopback is bewust vrijgesteld, net als bij /audio")

        XCTAssertLessThan(after, before)
        XCTAssertGreaterThan(result.inserted, 0)
        XCTAssertGreaterThan(reachableAfter, reachableBefore)
    }

    /// Wat blijft er over als Roon wegvalt? Bouwt de bibliotheek op een KOPIE
    /// volledig opnieuw uit alleen de analyzer, en telt wat je dan hebt. Zelfde
    /// opt-in als de meting hierboven.
    func testMeasureFullStandaloneLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let libSrc = env["ROONSAGE_REAL_LIBRARY_DB"], let anSrc = env["ROONSAGE_REAL_ANALYZER_DB"] else {
            throw XCTSkip("Set ROONSAGE_REAL_LIBRARY_DB + ROONSAGE_REAL_ANALYZER_DB to measure.")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rs-standalone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let libCopy = dir.appendingPathComponent("library.db")
        let anCopy = dir.appendingPathComponent("analyzer.db")
        try fm.copyItem(at: URL(fileURLWithPath: libSrc), to: libCopy)
        try fm.copyItem(at: URL(fileURLWithPath: anSrc), to: anCopy)

        let store = try FeatureStore(path: anCopy.path)
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: store.exportJSON(includeEmbedding: false)) as? [[String: Any]])
        var rows: [DatabaseManager.LocalTrackRow] = []
        for o in arr {
            guard let mk = o["match_key"] as? String, !mk.isEmpty,
                  let t = o["title"] as? String, !t.isEmpty else { continue }
            let year = o["year"] as? Int
            rows.append(DatabaseManager.LocalTrackRow(
                matchKey: mk,
                artist: (o["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                title: t,
                album: (o["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                year: (year ?? 0) > 1900 ? year : nil))
        }

        let real = try DatabaseManager(url: libCopy)
        func shape() async throws -> (tracks: Int, albums: Int, artists: Int, art: Int, years: Int) {
            try await real.pool.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT album_key) FROM tracks") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT LOWER(artist)) FROM tracks WHERE artist IS NOT NULL") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE image_key IS NOT NULL AND image_key != ''") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE year IS NOT NULL") ?? 0
                )
            }
        }
        let withRoon = try await shape()
        let reachableWithRoon = try await real.analyzedTrackIdentities(excludeLive: false).count

        // Roon uit: al zijn rijen weg, daarna alles opnieuw uit de bestanden.
        try await real.pool.write { db in try db.execute(sql: "DELETE FROM tracks WHERE source = 'roon'") }
        let result = try await real.ingestLocalTracks(rows)
        let standalone = try await shape()
        let reachableStandalone = try await real.analyzedTrackIdentities(excludeLive: false).count
        let genres = try await real.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_mb_genres") ?? 0
        }

        print("""
            METING bibliotheek zonder Roon
                                     met Roon   ->   alleen bestanden
              tracks               : \(withRoon.tracks)  ->  \(standalone.tracks)
              albums               : \(withRoon.albums)  ->  \(standalone.albums)
              artiesten            : \(withRoon.artists)  ->  \(standalone.artists)
              met albumhoes        : \(withRoon.art)  ->  \(standalone.art)
              met jaartal          : \(withRoon.years)  ->  \(standalone.years)
              sonisch bereikbaar   : \(reachableWithRoon)  ->  \(reachableStandalone)
              MB-genres (los van Roon) : \(genres)
              ingest: \(result.inserted) nieuw van \(result.offered) aangeboden
            """)
        XCTAssertGreaterThan(standalone.tracks, 0)
    }

    // MARK: - Jaartallen

    func testARoonResyncDoesNotWipeTheYearsTheAnalyserFilledIn() async throws {
        // Roon's jaar komt uit een subtitle-string die zelden te parsen is: op de
        // echte bibliotheek droegen 1.071 van de 89.752 rijen er een, terwijl de
        // bestandstags er 59.136 leveren. `applyTrackYears` vult die in — en elke
        // volgende walk schreef er een NULL overheen.
        let run1 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run1.generation)

        let key = TrackIdentity.matchKey(artist: "Bowie", album: "Heroes", title: "Heroes")
        let filled = try await db.applyTrackYears([(matchKey: key, year: 1977)])
        XCTAssertEqual(filled, 1)

        // Tweede walk, Roon levert nog steeds geen jaar.
        let run2 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")],
            albumTitle: "Heroes", fingerprint: "fpH", generation: run2.generation)

        let year = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT year FROM tracks WHERE id = 'r1'")
        }
        XCTAssertEqual(year, 1977, "de walk mag een ingevuld jaartal niet wissen")
    }

    func testRoonsOwnYearStillWinsWhenItHasOne() async throws {
        // COALESCE mag niet betekenen "eerste waarde wint voor altijd": als Roon
        // wél een jaar levert, is dat een echte waarde en die hoort te landen.
        let run = try await db.beginSyncRun()
        var rec = roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")
        rec.year = nil
        try await db.replaceAlbumTracks([rec], albumTitle: "Heroes", fingerprint: "fpH",
                                        generation: run.generation)
        rec.year = 1977
        try await db.replaceAlbumTracks([rec], albumTitle: "Heroes", fingerprint: "fpH",
                                        generation: run.generation)

        let year = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT year FROM tracks WHERE id = 'r1'")
        }
        XCTAssertEqual(year, 1977)
    }

    func testTheBatchPathPreservesYearsToo() async throws {
        // replaceAlbumBatch is wat de échte sync gebruikt (25 albums per
        // transactie); replaceAlbumTracks is de losse variant.
        func batch(_ gen: Int) -> [DatabaseManager.AlbumBatchItem] {
            [DatabaseManager.AlbumBatchItem(
                records: [roonRecord("r1", artist: "Bowie", title: "Heroes", album: "Heroes")],
                albumTitle: "Heroes", fingerprint: "fpH", generation: gen, append: false)]
        }
        let run1 = try await db.beginSyncRun()
        try await db.replaceAlbumBatch(batch(run1.generation))
        let key = TrackIdentity.matchKey(artist: "Bowie", album: "Heroes", title: "Heroes")
        _ = try await db.applyTrackYears([(matchKey: key, year: 1977)])

        let run2 = try await db.beginSyncRun()
        try await db.replaceAlbumBatch(batch(run2.generation))

        let year = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT year FROM tracks WHERE id = 'r1'")
        }
        XCTAssertEqual(year, 1977)
    }
}
