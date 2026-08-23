import Foundation
import GRDB
import XCTest

@testable import RoonSageCore

/// Fase 5 — declarative smart playlists and automatic recaps.
final class SmartPlaylistTests: XCTestCase {

    // MARK: - The JSON contract
    //
    // These documents are written by hand and stored as text, so the key
    // spelling IS the API. A rename that only breaks at runtime would silently
    // turn a narrow rule into "no rule", which returns the whole library.

    func testRulesDecodeFromSnakeCaseJSON() throws {
        let json = """
        {
          "genre": ["house", "techno"],
          "bpm_range": {"min": 118, "max": 126},
          "camelot_keys": ["8A", "9a"],
          "energy_range": {"min": 0.4},
          "last_played_days_ago": 90,
          "min_play_count": 3,
          "sonic_similarity": {"match_key": "artist|album|title", "min_score": 0.62},
          "exclude_live": false,
          "limit": 40
        }
        """
        let rules = try SmartPlaylistRules.decode(json: json)
        XCTAssertEqual(rules.genre, ["house", "techno"])
        XCTAssertEqual(rules.bpmRange?.min, 118)
        XCTAssertEqual(rules.bpmRange?.max, 126)
        XCTAssertEqual(rules.camelotKeys, ["8A", "9a"])
        XCTAssertEqual(rules.energyRange?.min, 0.4)
        XCTAssertNil(rules.energyRange?.max)
        XCTAssertEqual(rules.lastPlayedDaysAgo, 90)
        XCTAssertEqual(rules.minPlayCount, 3)
        XCTAssertEqual(rules.sonicSimilarity?.matchKey, "artist|album|title")
        XCTAssertEqual(rules.sonicSimilarity?.minScore, 0.62)
        XCTAssertFalse(rules.excludeLive)
        XCTAssertEqual(rules.limit, 40)
    }

    /// The two fields a hand-written document usually omits must not decode as
    /// zero/false — a `limit` of 0 is an empty playlist and `exclude_live: false`
    /// is the opposite of the intended default.
    func testOmittedDefaultsAreFilled() throws {
        let rules = try SmartPlaylistRules.decode(json: "{}")
        XCTAssertTrue(rules.excludeLive)
        XCTAssertEqual(rules.limit, 100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = SmartPlaylistRules(genre: ["jazz"], bpmRange: .init(min: 60, max: 90),
                                          camelotKeys: ["5A"], energyRange: .init(max: 0.5),
                                          lastPlayedDaysAgo: 30, minPlayCount: 2,
                                          sonicSimilarity: .init(matchKey: "a|b|c", minScore: 0.7),
                                          excludeLive: false, limit: 25)
        XCTAssertEqual(try SmartPlaylistRules.decode(json: original.encodedJSON()), original)
    }

    // MARK: - Compilation

    func testEmptyRulesStillExcludeLive() {
        let compiled = SmartPlaylistEngine.compile(SmartPlaylistRules())
        XCTAssertEqual(compiled.whereClauses, ["t.is_live = 0"])
        XCTAssertTrue(compiled.arguments.isEmpty)
        XCTAssertFalse(compiled.needsPlayStats)
        XCTAssertFalse(compiled.needsSonicRanking)
    }

    /// One-sided ranges are the common case ("120 BPM and up") and must produce
    /// exactly one comparison, not a bound of 0 on the missing side.
    func testOneSidedRangesProduceOneClause() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(bpmRange: .init(min: 120), excludeLive: false))
        XCTAssertEqual(compiled.whereClauses, ["f.bpm >= ?"])
        XCTAssertEqual(compiled.arguments.count, 1)
    }

    /// The play-stat sub-select is expensive; it must only appear when a rule
    /// actually reads it.
    func testPlayStatsJoinOnlyWhenAHistoryRuleIsPresent() {
        XCTAssertFalse(SmartPlaylistEngine.compile(
            SmartPlaylistRules(bpmRange: .init(min: 100))).needsPlayStats)
        XCTAssertTrue(SmartPlaylistEngine.compile(
            SmartPlaylistRules(lastPlayedDaysAgo: 30)).needsPlayStats)
        XCTAssertTrue(SmartPlaylistEngine.compile(
            SmartPlaylistRules(minPlayCount: 5)).needsPlayStats)
    }

    /// "Not played in N days" has to include tracks that were never played at
    /// all — those are exactly what the rule is for, and a plain `<` against a
    /// NULL last-played would drop every one of them.
    func testLastPlayedRuleIncludesNeverPlayed() {
        let compiled = SmartPlaylistEngine.compile(SmartPlaylistRules(lastPlayedDaysAgo: 90))
        XCTAssertTrue(compiled.whereClauses.contains { $0.contains("ps.last_played IS NULL") },
                      "never-played tracks must satisfy a dormancy rule")
    }

    /// A zero is "no rule", not "played at least zero times" / "not played in
    /// zero days" — both of which are true for everything.
    func testZeroHistoryValuesAreNoRule() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(lastPlayedDaysAgo: 0, minPlayCount: 0, excludeLive: false))
        XCTAssertTrue(compiled.whereClauses.isEmpty)
        XCTAssertFalse(compiled.needsPlayStats)
    }

    func testCamelotKeysAreUppercasedForMatching() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(camelotKeys: ["8a", "11B"], excludeLive: false))
        XCTAssertEqual(compiled.whereClauses, ["UPPER(f.camelot) IN (?,?)"])
        XCTAssertEqual(compiled.arguments, ["8A", "11B"].map(\.databaseValue))
    }

    /// A genre rule expands to clauses against BOTH sources — Roon's own tags
    /// and the MusicBrainz/Deezer ones — because a track that only one source
    /// knows about still belongs in the result.
    func testGenreRuleMatchesBothGenreSources() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(genre: ["house"], excludeLive: false),
            expandedGenres: ["house", "deep house"])
        XCTAssertEqual(compiled.whereClauses.count, 1)
        XCTAssertTrue(compiled.whereClauses[0].contains("track_genres"))
        XCTAssertTrue(compiled.whereClauses[0].contains("track_mb_genres"))
        // Both sub-selects are bound, so the arguments appear twice.
        XCTAssertEqual(compiled.arguments.count, 4)
    }

    /// A similarity rule cannot be answered in SQL, so the SQL stage has to
    /// over-fetch — otherwise a `limit: 40` playlist with a score floor comes
    /// back with a handful of tracks and looks broken.
    func testSonicRuleOverfetchesAndIsAnnounced() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(sonicSimilarity: .init(matchKey: "a|b|c"), limit: 40))
        XCTAssertTrue(compiled.needsSonicRanking)
        XCTAssertEqual(compiled.limit, 40 * SmartPlaylistEngine.sonicOverfetch)
    }

    /// An empty seed key would rank against nothing. Dropping the rule (rather
    /// than ranking against a zero vector) is what lets the caller notice.
    func testEmptySonicSeedIsNotARule() {
        let compiled = SmartPlaylistEngine.compile(
            SmartPlaylistRules(sonicSimilarity: .init(matchKey: ""), limit: 40))
        XCTAssertFalse(compiled.needsSonicRanking)
        XCTAssertEqual(compiled.limit, 40)
    }

    // MARK: - Execution against a real database

    private func makeDatabase() throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-\(UUID().uuidString).sqlite")
        guard let db = DatabaseManager.open(url: url) else {
            throw XCTSkip("could not open a temporary database")
        }
        return (db, url)
    }

    private func seed(_ db: DatabaseManager) async throws {
        try await db.upsertTracks([
            TrackRecord(id: "1", title: "Fast", artist: "A", album: "One", year: 2020,
                        isLive: false, matchKey: "a|one|fast"),
            TrackRecord(id: "2", title: "Slow", artist: "B", album: "Two", year: 2021,
                        isLive: false, matchKey: "b|two|slow"),
            TrackRecord(id: "3", title: "Live One", artist: "A", album: "One", year: 2020,
                        isLive: true, matchKey: "a|one|live one"),
        ])
        try await db.upsertAudioFeatures([
            DatabaseManager.AudioFeatureRow(matchKey: "a|one|fast", bpm: 128, camelot: "8A",
                                            keyRoot: "C", keyMode: "minor",
                                            energy: 0.8, duration: 200, tags: nil),
            DatabaseManager.AudioFeatureRow(matchKey: "b|two|slow", bpm: 80, camelot: "3B",
                                            keyRoot: "F", keyMode: "major",
                                            energy: 0.2, duration: 240, tags: nil),
            DatabaseManager.AudioFeatureRow(matchKey: "a|one|live one", bpm: 130, camelot: "8A",
                                            keyRoot: "C", keyMode: "minor",
                                            energy: 0.9, duration: 300, tags: nil),
        ])
    }

    func testTempoRuleSelectsOnlyMatchingTracks() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let fast = try await db.smartPlaylistTracks(
            SmartPlaylistRules(bpmRange: .init(min: 120, max: 140)))
        XCTAssertEqual(fast.map(\.title), ["Fast"], "the live 130 BPM track is excluded by default")

        let withLive = try await db.smartPlaylistTracks(
            SmartPlaylistRules(bpmRange: .init(min: 120, max: 140), excludeLive: false))
        XCTAssertEqual(Set(withLive.map(\.title)), ["Fast", "Live One"])
    }

    func testKeyAndEnergyRulesCombineWithAND() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let hit = try await db.smartPlaylistTracks(
            SmartPlaylistRules(camelotKeys: ["8A"], energyRange: .init(min: 0.5)))
        XCTAssertEqual(hit.map(\.title), ["Fast"])

        // Same key, impossible energy → nothing, not "the key match anyway".
        let miss = try await db.smartPlaylistTracks(
            SmartPlaylistRules(camelotKeys: ["8A"], energyRange: .init(max: 0.1)))
        XCTAssertTrue(miss.isEmpty)
    }

    /// A genre nobody in this library has must return nothing. Compiling it to
    /// no clause would return the ENTIRE library — a narrow rule silently
    /// becoming the widest possible one.
    func testUnknownGenreReturnsNothingRatherThanEverything() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        let rows = try await db.smartPlaylistTracks(
            SmartPlaylistRules(genre: ["nonexistent-genre-zzz"]))
        XCTAssertTrue(rows.isEmpty)
    }

    func testMinPlayCountUsesListeningHistory() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        for _ in 0..<3 {
            try await db.logListen(title: "Fast", artist: "A", album: "One",
                                   zoneID: "z", zoneName: "Zone")
        }

        let played = try await db.smartPlaylistTracks(SmartPlaylistRules(minPlayCount: 3))
        XCTAssertEqual(played.map(\.title), ["Fast"])
        let tooMany = try await db.smartPlaylistTracks(SmartPlaylistRules(minPlayCount: 4))
        XCTAssertTrue(tooMany.isEmpty)
    }

    /// The dormancy rule has to surface tracks with no history at all.
    func testDormancyRuleIncludesNeverPlayedTracks() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        try await db.logListen(title: "Fast", artist: "A", album: "One",
                               zoneID: "z", zoneName: "Zone")

        let dormant = try await db.smartPlaylistTracks(SmartPlaylistRules(lastPlayedDaysAgo: 30))
        XCTAssertEqual(dormant.map(\.title), ["Slow"],
                       "never-played tracks qualify; the one played today does not")
    }

    // MARK: - Recaps

    func testWeeklyPeriodsAreCompleteWeeksNewestFirst() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let service = RecapService(database: db, calendar: calendar,
                                   locale: Locale(identifier: "nl_NL"))

        // A Thursday, mid-week.
        let now = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                 year: 2026, month: 8, day: 20, hour: 12).date!
        let weeks = service.recentWeeks(now: now)
        XCTAssertEqual(weeks.count, RecapService.weeksKept)
        // The week in progress is excluded: every window must end at or before now.
        for week in weeks {
            XCTAssertLessThanOrEqual(week.end, now)
            XCTAssertLessThan(week.start, week.end)
        }
        // Newest first, and no two periods share an identity.
        XCTAssertEqual(weeks, weeks.sorted { $0.start > $1.start })
        XCTAssertEqual(Set(weeks.map(\.externalID)).count, weeks.count)
    }

    /// The identity has to be stable across regenerations, or every run would
    /// insert a duplicate instead of replacing.
    func testPeriodIdentityIsStableAcrossRuns() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let service = RecapService(database: db, calendar: calendar, locale: Locale(identifier: "nl_NL"))

        let monday = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                    year: 2026, month: 8, day: 17, hour: 1).date!
        let friday = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                    year: 2026, month: 8, day: 21, hour: 23).date!
        XCTAssertEqual(service.recentWeeks(now: monday).map(\.externalID),
                       service.recentWeeks(now: friday).map(\.externalID),
                       "the same week must produce the same id whenever it is generated")
        XCTAssertTrue(service.recentWeeks(now: monday).allSatisfy {
            $0.externalID.hasPrefix(RecapService.sourcePrefix)
        })
    }

    /// A quiet period must not become an empty playlist claiming to be a
    /// summary — and the reconcile must leave user playlists alone.
    func testRegenerateSkipsQuietPeriodsAndSparesUserPlaylists() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)
        _ = try await db.savePlaylist(name: "Mijn eigen lijst", tracks: [
            TrackRecord(id: "1", title: "Fast", artist: "A", album: "One"),
        ])

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let service = RecapService(database: db, calendar: calendar, locale: Locale(identifier: "nl_NL"))
        let written = await service.regenerate()
        XCTAssertTrue(written.isEmpty, "no history → no recaps")

        let playlists = try await db.listPlaylists()
        XCTAssertEqual(playlists.map(\.name), ["Mijn eigen lijst"])
        XCTAssertNil(playlists.first?.source, "a user playlist has no source badge")
    }

    /// A period with enough plays becomes one playlist, badged as a recap, and
    /// regenerating replaces it rather than adding a second copy.
    func testRegenerateIsIdempotentAndBadged() async throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try await seed(db)

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) else {
            throw XCTSkip("calendar could not produce last week")
        }
        // Plant enough plays inside last week to clear the threshold. Each one
        // needs its OWN timestamp: `appendImportedListens` dedupes on
        // (source, played_at, artist), so ten identical stamps insert one row.
        let formatter = ISO8601DateFormatter()
        try await db.appendImportedListens(
            (0..<RecapService.minPlaysPerPeriod).map { i in
                DatabaseManager.ImportedListen(
                    title: "Fast", artist: "A", album: "One",
                    playedAt: formatter.string(from: lastWeek.addingTimeInterval(3600 + Double(i) * 60)))
            }, source: "test", zoneName: "Test")

        let service = RecapService(database: db, calendar: calendar, locale: Locale(identifier: "nl_NL"))
        let first = await service.regenerate(now: now)
        XCTAssertEqual(first.count, 1)

        let second = await service.regenerate(now: now)
        XCTAssertEqual(second, first)

        let playlists = try await db.listPlaylists()
        XCTAssertEqual(playlists.count, 1, "regenerating must replace, never duplicate")
        XCTAssertEqual(playlists.first?.source, "recap")
        XCTAssertGreaterThan(playlists.first?.trackCount ?? 0, 0)
    }
}
