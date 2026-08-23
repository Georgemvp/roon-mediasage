import AudioAnalysis
import GRDB
import XCTest
@testable import RoonSageCore

/// Plex as a library source (DatabaseManager+PlexLibrary + PlexClient): Plex's
/// stable `ratingKey` becomes the row id, the absolute file path travels with the
/// row so it joins to the analyser exactly, and Roon rows step aside.
final class PlexLibrarySourceTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-plex-lib-\(UUID().uuidString)", isDirectory: true)
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

    private func plex(_ ratingKey: String, artist: String, title: String, album: String,
                      albumRatingKey: String? = nil, year: Int? = nil, file: String? = nil,
                      thumb: String? = nil) -> DatabaseManager.PlexTrackRow {
        DatabaseManager.PlexTrackRow(
            ratingKey: ratingKey, title: title, artist: artist, album: album,
            albumRatingKey: albumRatingKey, year: year, filePath: file, thumb: thumb)
    }

    private func roonRecord(_ id: String, artist: String, title: String, album: String) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album, albumKey: "ak-\(id)",
                    matchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title))
    }

    // MARK: - Ingest

    func testIngestKeysOnRatingKeyAndStoresTheFilePath() async throws {
        let result = try await db.ingestPlexTracks([
            plex("108053", artist: "&on&on", title: "Don't Say a Word", album: "DJ-Kicks",
                 albumRatingKey: "90244", year: 2012,
                 file: "/Volumes/4tbdrive/Muziek/&on&on/06 - Don't Say a Word.flac"),
            plex("112009", artist: "2 Brothers", title: "Come Take My Hand", album: "Come Take My Hand",
                 file: "/Volumes/4tbdrive/Muziek/2 Brothers/01 - Come Take My Hand.flac"),
        ])

        XCTAssertEqual(result.offered, 2)
        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.total, 2)

        let rows = try await db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, album_key, file_path, source FROM tracks ORDER BY id")
        }
        XCTAssertEqual(rows.map { $0["id"] as String? }, ["plex::108053", "plex::112009"])
        XCTAssertEqual(rows[0]["album_key"] as String?, "plex::90244",
                       "met een parentRatingKey moet de albumsleutel die van Plex zijn")
        XCTAssertEqual(rows[0]["file_path"] as String?,
                       "/Volumes/4tbdrive/Muziek/&on&on/06 - Don't Say a Word.flac")
        XCTAssertEqual(rows.map { $0["source"] as String? }, ["plex", "plex"])
    }

    /// Artwork must resolve through the analyser's /artwork, not through Plex:
    /// a thin client holds no Plex token. The `local::` prefix here is the
    /// resolution scheme `imageURL(forKey:)` switches on, not a provenance claim.
    func testArtworkKeyUsesTheAnalyserResolutionScheme() async throws {
        try await db.ingestPlexTracks([plex("1", artist: "A", title: "T", album: "Al",
                                            thumb: "/library/metadata/9/thumb/1")])
        let imageKey = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT image_key FROM tracks WHERE id = 'plex::1'")
        }
        let expected = DatabaseManager.localKeyPrefix
            + TrackIdentity.matchKey(artist: "A", album: "Al", title: "T")
        XCTAssertEqual(imageKey, expected)
        XCTAssertFalse(imageKey?.hasPrefix(DatabaseManager.plexKeyPrefix) ?? true,
                       "de Plex-thumb mag hier niet staan — clients hebben geen Plex-token")
    }

    // MARK: - Sync wiring

    /// The import displaces Roon rows, so it must never start by itself. Nothing
    /// in start-up may write this key.
    func testPlexSyncIsOffUntilExplicitlyEnabled() {
        XCTAssertNil(UserDefaults.standard.object(forKey: "plex_sync_enabled"),
                     "plex_sync_enabled mag niet gezet zijn zonder dat de user hem aanzet")
    }

    func testLibraryRowMapsEveryFieldTheIngestNeeds() {
        let track = PlexClient.Track(
            ratingKey: "174626", guid: "plex://track/abc", title: "Mandy",
            artist: "10cc", album: "Classic", albumRatingKey: "90244", year: 2012,
            filePath: "/Volumes/4tbdrive/Muziek/10cc/04 - Mandy.flac",
            duration: 321120, thumb: "/library/metadata/90244/thumb/1")
        let row = RoonClient.libraryRow(track)
        XCTAssertEqual(row.ratingKey, "174626")
        XCTAssertEqual(row.title, "Mandy")
        XCTAssertEqual(row.artist, "10cc")
        XCTAssertEqual(row.album, "Classic")
        XCTAssertEqual(row.albumRatingKey, "90244")
        XCTAssertEqual(row.year, 2012)
        XCTAssertEqual(row.filePath, "/Volumes/4tbdrive/Muziek/10cc/04 - Mandy.flac")
    }

    func testAlbumKeyFallsBackWhenPlexHasNoAlbumID() async throws {
        try await db.ingestPlexTracks([
            plex("1", artist: "Solti", title: "Elektra", album: "Strauss"),
            plex("2", artist: "Solti", title: "Salome", album: "Strauss"),
        ])
        let keys = try await db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT album_key FROM tracks")
        }
        XCTAssertEqual(keys, ["plex::strauss|solti"],
                       "zonder parentRatingKey moeten beide tracks tóch op één album vallen")
    }

    func testIngestDisplacesTheRoonRowForTheSameRecording() async throws {
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks(
            [roonRecord("r1", artist: "Solti", title: "Elektra", album: "Strauss")],
            albumTitle: "Strauss", fingerprint: "fpA", generation: run.generation)

        let result = try await db.ingestPlexTracks([
            plex("1", artist: "Solti", title: "Elektra", album: "Strauss"),
        ])

        XCTAssertEqual(result.reclaimed, 1, "de Roon-rij voor hetzelfde nummer moet verdrongen zijn")
        let sources = try await db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT source FROM tracks")
        }
        XCTAssertEqual(sources, ["plex"])
    }

    func testReingestRefreshesInsteadOfDuplicating() async throws {
        try await db.ingestPlexTracks([plex("1", artist: "A", title: "T", album: "Al")])
        let second = try await db.ingestPlexTracks([
            plex("1", artist: "A", title: "T (Remastered)", album: "Al", year: 1999),
        ])
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.refreshed, 1)
        XCTAssertEqual(second.total, 1)
        let row = try await db.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT title, year FROM tracks WHERE id = 'plex::1'")
        }
        XCTAssertEqual(row?["title"] as String?, "T (Remastered)")
        XCTAssertEqual(row?["year"] as Int?, 1999)
    }

    func testPruneIsSkippedWhenThePayloadCollapsed() async throws {
        try await db.ingestPlexTracks((1...10).map { plex("\($0)", artist: "A", title: "T\($0)", album: "Al") })
        // Eén track terug uit tien = een afgekapte lezing, geen bibliotheek die kromp.
        let result = try await db.ingestPlexTracks([plex("1", artist: "A", title: "T1", album: "Al")])
        XCTAssertEqual(result.pruned, 0, "de rem moet een ingestorte payload tegenhouden")
        XCTAssertEqual(result.total, 10)
    }

    func testPrunesWhatPlexNoLongerOffers() async throws {
        try await db.ingestPlexTracks((1...10).map { plex("\($0)", artist: "A", title: "T\($0)", album: "Al") })
        let result = try await db.ingestPlexTracks((1...9).map { plex("\($0)", artist: "A", title: "T\($0)", album: "Al") })
        XCTAssertEqual(result.pruned, 1)
        XCTAssertEqual(result.total, 9)
    }

    func testDuplicateRatingKeysInOnePayloadDoNotCollide() async throws {
        let result = try await db.ingestPlexTracks([
            plex("1", artist: "A", title: "T", album: "Al"),
            plex("1", artist: "A", title: "T", album: "Al"),
        ])
        XCTAssertEqual(result.total, 1)
    }

    // MARK: - The exact join to the analyser

    func testFilePathJoinsAnalysedFilesExactly() async throws {
        let hit = "/Volumes/4tbdrive/Muziek/A/01 - Hit.flac"
        let miss = "/Volumes/4tbdrive/Muziek/A/02 - Miss.flac"
        try await db.ingestPlexTracks([
            plex("1", artist: "A", title: "Hit", album: "Al", file: hit),
            plex("2", artist: "A", title: "Miss", album: "Al", file: miss),
        ])
        let coverage = try await db.plexFeatureJoinCoverage(analysedPaths: [hit])
        XCTAssertEqual(coverage.joined, 1)
        XCTAssertEqual(coverage.total, 2)
    }

    /// The 2.608-track bug: APFS reports filenames decomposed (NFD), Plex stores
    /// them composed (NFC). A row must be stored normalised so the join works.
    func testDecomposedPathsAreNormalisedOnIngest() async throws {
        // Bouw beide vormen uit expliciete scalars. Een "é"-literal hier zou de
        // test laten afhangen van hoe dít bronbestand op schijf genormaliseerd
        // staat — en dan is de decompositie een no-op en test hij niets.
        let composed = "/Volumes/4tbdrive/Muziek/Beyonc\u{00E9}/01 - Halo.flac"      // é
        let decomposed = "/Volumes/4tbdrive/Muziek/Beyonc\u{0065}\u{0301}/01 - Halo.flac"  // e + combining acute
        XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count,
                          "de testinvoer moet echt in twee vormen staan")

        try await db.ingestPlexTracks([
            plex("1", artist: "Beyoncé", title: "Halo", album: "I Am", file: decomposed),
        ])
        let stored = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT file_path FROM tracks WHERE id = 'plex::1'")
        }
        XCTAssertEqual(stored, composed)

        let coverage = try await db.plexFeatureJoinCoverage(analysedPaths: [composed])
        XCTAssertEqual(coverage.joined, 1, "een NFD-pad moet tóch op een NFC-analyse joinen")
    }

    // MARK: - PlexClient parsing

    func testParseTrackReadsTheNestedFilePath() throws {
        let raw: [String: Any] = [
            "ratingKey": "174626",
            "guid": "plex://track/5d07cdf7403c640290fb2426",
            "title": "I'm Mandy Fly Me",
            "grandparentTitle": "10cc",
            "parentTitle": "Classic Album Selection",
            "parentRatingKey": "90244",
            "parentYear": 2012,
            "duration": 321120,
            "thumb": "/library/metadata/90244/thumb/1786174413",
            "Media": [["Part": [["file": "/Volumes/4tbdrive/Muziek/10cc/04 - Mandy.flac"]]]],
        ]
        let track = try XCTUnwrap(PlexClient.parseTrack(raw))
        XCTAssertEqual(track.ratingKey, "174626")
        XCTAssertEqual(track.artist, "10cc")
        XCTAssertEqual(track.album, "Classic Album Selection")
        XCTAssertEqual(track.albumRatingKey, "90244")
        XCTAssertEqual(track.year, 2012, "tracks dragen zelf geen year — parentYear moet invallen")
        XCTAssertEqual(track.filePath, "/Volumes/4tbdrive/Muziek/10cc/04 - Mandy.flac")
        XCTAssertEqual(track.duration, 321120)
    }

    func testParseTrackToleratesNumericRatingKeyAndMissingMedia() throws {
        let track = try XCTUnwrap(PlexClient.parseTrack([
            "ratingKey": 42,            // sommige versies geven een getal
            "title": "Naked",
        ]))
        XCTAssertEqual(track.ratingKey, "42")
        XCTAssertNil(track.filePath)
        XCTAssertNil(track.albumRatingKey)
    }

    func testParseTrackRejectsRowsWithoutKeyOrTitle() {
        XCTAssertNil(PlexClient.parseTrack(["title": "geen ratingKey"]))
        XCTAssertNil(PlexClient.parseTrack(["ratingKey": "1"]), "geen titel én geen bestand")
        XCTAssertNil(PlexClient.parseTrack(["ratingKey": "1", "title": "   "]))
    }

    /// 184 van de 65.719 tracks hebben in Plex een lege titel (vinyl-siderips,
    /// 5.1-AC3-stems). Die mogen niet onzichtbaar worden — het bestand heeft wél
    /// een bruikbare naam.
    func testBlankTitleFallsBackToTheFilename() throws {
        let track = try XCTUnwrap(PlexClient.parseTrack([
            "ratingKey": "94073",
            "title": "",
            "grandparentTitle": "Depeche Mode",
            "Media": [["Part": [["file": "/M/Depeche Mode - Spirit - Side A.flac"]]]],
        ]))
        XCTAssertEqual(track.title, "Depeche Mode - Spirit - Side A")
    }

    func testTitleFromFilenameStripsTrackNumbersButNeverEverything() {
        XCTAssertEqual(PlexClient.titleFromFilename("/m/06 - Back In Black.flac"), "Back In Black")
        XCTAssertEqual(PlexClient.titleFromFilename("/m/02-03-Allegiance to Denethor.ac3"),
                       "03-Allegiance to Denethor")
        XCTAssertEqual(PlexClient.titleFromFilename("/m/11 Another Brick.flac"), "Another Brick")
        // Alleen een nummer: strippen zou niets overlaten, dus blijft het staan.
        XCTAssertEqual(PlexClient.titleFromFilename("/m/07.flac"), "07")
    }

    // MARK: - Live server (opt-in)

    /// End-to-end against the real Plex on this machine. Unit tests prove the
    /// parsing of a hand-written payload, not that the live server's payload has
    /// the shape we assume — so this one talks to it for real.
    ///
    /// Off by default (needs a running Plex + a token), so CI stays hermetic.
    /// Run with: `ROONSAGE_PLEX_LIVE=1 swift test --filter testLiveServer`
    func testLiveServerYieldsTracksWithFilePaths() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROONSAGE_PLEX_LIVE"] == "1",
                          "opt-in: zet ROONSAGE_PLEX_LIVE=1")
        let token = try XCTUnwrap(PlexClient.localToken(), "geen PlexOnlineToken in Preferences.xml")
        let client = PlexClient(baseURL: URL(string: "http://127.0.0.1:32400")!, token: token)

        // XCTUnwrap neemt een autoclosure, die geen `await` toestaat — dus eerst
        // ophalen, dan uitpakken.
        let found = try await client.musicSection()
        let section = try XCTUnwrap(found, "geen muzieksectie op deze server")
        var page: [PlexClient.Track] = []
        try await client.allTracks(inSection: section.key, pageSize: 200) { tracks in
            if page.isEmpty { page = tracks }
        }
        XCTAssertFalse(page.isEmpty, "de eerste pagina moet tracks bevatten")

        let withPath = page.filter { $0.filePath != nil }
        XCTAssertGreaterThan(withPath.count, page.count / 2,
                             "de meeste tracks moeten een bestandspad hebben — dat is de hele reden voor deze bron")
        for t in withPath {
            XCTAssertEqual(t.filePath, t.filePath?.precomposedStringWithCanonicalMapping,
                           "paden moeten NFC-genormaliseerd binnenkomen")
        }
        print("[plex live] sectie '\(section.title)' — \(page.count) tracks in pagina 1, "
              + "\(withPath.count) met pad, \(page.filter { $0.albumRatingKey != nil }.count) met album-id")
    }

    /// The whole fase-1 path at real scale: live Plex → paging → ingest.
    ///
    /// Runs against a COPY of the real `library.db`, never the live one — the
    /// ingest displaces Roon rows, and that is the user's call to make, not a
    /// test run's. Off by default.
    ///
    /// `ROONSAGE_PLEX_LIVE=1 swift test --filter testLiveFullImport`
    func testLiveFullImportAgainstACopyOfTheRealLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROONSAGE_PLEX_LIVE"] == "1",
                          "opt-in: zet ROONSAGE_PLEX_LIVE=1")
        let live = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/RoonSage/library.db")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: live.path),
                          "geen echte library.db op deze machine")

        let copy = dbURL.deletingLastPathComponent().appendingPathComponent("live-copy.db")
        try FileManager.default.copyItem(at: live, to: copy)
        let real = try DatabaseManager(url: copy)
        let roonBefore = try await real.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE source = 'roon'") ?? 0
        }

        let token = try XCTUnwrap(PlexClient.localToken())
        let client = PlexClient(baseURL: URL(string: "http://127.0.0.1:32400")!, token: token)
        let found = try await client.musicSection()
        let section = try XCTUnwrap(found)

        var rows: [DatabaseManager.PlexTrackRow] = []
        try await client.allTracks(inSection: section.key) { page in
            rows.append(contentsOf: page.map(RoonClient.libraryRow))
        }
        XCTAssertGreaterThan(rows.count, 1000, "een echte muzieksectie levert veel meer dan een pagina")

        let result = try await real.ingestPlexTracks(rows)
        let withPath = rows.filter { $0.filePath != nil }.count
        print("[plex live] \(rows.count) tracks opgehaald (\(withPath) met pad) → "
              + "\(result.inserted) nieuw, \(result.reclaimed) Roon-rijen verdrongen "
              + "(van \(roonBefore)), \(result.total) Plex-rijen totaal")

        XCTAssertEqual(result.inserted, rows.count, "een lege bibliotheek moet ze allemaal opnemen")
        XCTAssertGreaterThan(result.reclaimed, 0, "Plex hoort Roon-rijen te verdringen")
        XCTAssertGreaterThan(withPath, rows.count / 2, "de meeste rijen moeten een bestandspad hebben")
    }

    func testTokenIsReadFromPreferencesXML() {
        let xml = #"<?xml version="1.0"?><Preferences MachineIdentifier="abc" PlexOnlineToken="s3cr3t-t0k3n" FriendlyName="mini" />"#
        XCTAssertEqual(PlexClient.attribute("PlexOnlineToken", in: xml), "s3cr3t-t0k3n")
        XCTAssertNil(PlexClient.attribute("NoSuchKey", in: xml))
    }
}
