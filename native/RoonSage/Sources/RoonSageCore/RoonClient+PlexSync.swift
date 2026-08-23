import Foundation

// MARK: - Plex library sync (server build only)
//
// Fase 1 of moving the catalogue off Roon's Browse walk. `ingestPlexTracks`
// existed but nothing called it; this is the caller.
//
// Runs only on the always-on server build (`.direct`) — the Plex token lives in
// the local server's Preferences.xml, which only exists on the machine running
// Plex. Thin clients receive the resulting rows over the :5767 share like every
// other library row, and never talk to Plex.

extension RoonClient {

    /// Where the Plex Media Server lives. Defaults to loopback because the
    /// server build runs on the same machine as Plex.
    public var plexBaseURL: String {
        get { UserDefaults.standard.string(forKey: "plex_base_url") ?? "http://127.0.0.1:32400" }
        set { UserDefaults.standard.set(newValue, forKey: "plex_base_url") }
    }

    /// Master switch for the Plex catalogue import.
    ///
    /// **Default off, deliberately.** `ingestPlexTracks` displaces the Roon rows
    /// it now owns (that is the point — one recording, one row), and on a 65k
    /// library the first run rewrites most of the catalogue. That must be a
    /// choice, never something a version bump starts on its own.
    public var plexSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "plex_sync_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "plex_sync_enabled") }
    }

    public static let plexSyncTaskName = "plex-library-sync"

    /// Outcome of one import pass — returned so callers (Settings, tests) can
    /// report without re-reading the database.
    public enum PlexSyncOutcome: Sendable, Equatable {
        case disabled
        case noToken
        case noMusicSection
        case failed(String)
        case imported(DatabaseManager.PlexIngestResult)
    }

    public func startPlexSync() {
        guard controlMode == .direct else { return }
        Task {
            await TaskScheduler.shared.register(
                name: Self.plexSyncTaskName,
                title: "Plex-bibliotheek importeren",
                interval: 6 * 60 * 60,
                // Let the Roon connect + library sync settle first, exactly like
                // the feature sync does.
                initialDelay: 120
            ) { [weak self] in
                guard let self else { return .skipped }
                switch await self.runPlexSync() {
                case .disabled:
                    return .skipped
                case .noToken:
                    // Plex not installed here, or Preferences.xml unreadable.
                    // Retry slowly rather than failing loudly: this is opt-in.
                    return .retry(after: 60 * 60)
                case .noMusicSection:
                    return .failed("Plex heeft geen muzieksectie")
                case let .failed(message):
                    return .failed(message, retryAfter: 15 * 60)
                case let .imported(result):
                    Log.info("Plex-sync: \(result.inserted) nieuw, \(result.refreshed) ververst, "
                             + "\(result.reclaimed) Roon-rijen verdrongen, \(result.pruned) verwijderd, "
                             + "\(result.total) totaal", category: .network)
                    return .completed
                }
            }
        }
    }

    public func stopPlexSync() {
        Task { await TaskScheduler.shared.unregister(Self.plexSyncTaskName) }
    }

    /// One import pass: enumerate Plex's music section and ingest it.
    ///
    /// Collects every page before ingesting rather than writing per page,
    /// because `ingestPlexTracks` prunes what Plex no longer offers — it needs
    /// the complete set to tell "gone" from "not in this page". 65.738 rows of
    /// this struct is roughly 13 MB, which the server can hold; the alternative
    /// is a two-pass protocol that buys nothing here.
    @discardableResult
    public func runPlexSync() async -> PlexSyncOutcome {
        guard plexSyncEnabled else { return .disabled }
        guard let db = database else { return .failed("geen database") }
        guard let token = PlexClient.localToken() else { return .noToken }
        guard let base = URL(string: plexBaseURL.trimmingCharacters(in: .whitespaces)) else {
            return .failed("ongeldige Plex-URL")
        }

        let client = PlexClient(baseURL: base, token: token)
        let section: PlexClient.Section
        do {
            guard let found = try await client.musicSection() else { return .noMusicSection }
            section = found
        } catch {
            return .failed("secties ophalen mislukt: \(error)")
        }

        var rows: [DatabaseManager.PlexTrackRow] = []
        do {
            try await client.allTracks(inSection: section.key) { page in
                rows.append(contentsOf: page.map(Self.libraryRow))
            }
        } catch {
            // A partial read must NEVER be ingested: the prune step would read
            // the missing tail as "Plex dropped these" and delete real rows. The
            // 50%-collapse brake inside ingestPlexTracks is a backstop, not a
            // licence to feed it truncated input.
            return .failed("tracks ophalen mislukt na \(rows.count) rijen: \(error)")
        }
        guard !rows.isEmpty else { return .failed("Plex gaf 0 tracks terug") }

        do {
            let result = try await db.ingestPlexTracks(rows)
            try? await db.setSyncState(key: "plex_synced_at", value: Self.isoNow())
            return .imported(result)
        } catch {
            return .failed("importeren mislukt: \(error)")
        }
    }

    // MARK: - Fase 2: sonic similarity from Plex

    /// Use Plex Pass's Sonic Analysis for "vergelijkbare nummers" instead of the
    /// local embedding k-NN.
    ///
    /// Default off. `/nearest` is undocumented and can break on a Plex update, so
    /// this is opt-in and every call falls back to `RadioEngine` when Plex has no
    /// answer — a wrong result is worse than a slower one.
    public var plexSonicEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "plex_sonic_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "plex_sonic_enabled") }
    }

    /// Sonically similar library tracks to `seed`, via Plex.
    ///
    /// nil (not empty) means "Plex could not answer" — the caller must then run
    /// its own ranking. Empty means Plex answered and nothing survived, which is
    /// a real answer.
    ///
    /// Three things happen to Plex's raw list, all of them necessary:
    ///   1. the seed is filtered out defensively. Plex already excludes it
    ///      (measured 10/10, 2026-08-23) — but a `distance` of 0 is NOT the seed,
    ///      it is another identical copy, so the guard must key on the rating key
    ///      and never on the distance;
    ///   2. hits are resolved back to library rows by `plex::<ratingKey>` — a hit
    ///      Plex knows but our library does not is skipped, not faked;
    ///   3. `SonicSelection.dropNearDuplicates` runs over the result. Plex does
    ///      no duplicate hygiene at all: measured 2026-08-23, a seed returned
    ///      five further copies of that same recording plus three of one other.
    func plexSimilarTracks(seed: DatabaseManager.SonicTrack,
                           library: [DatabaseManager.SonicTrack],
                           index: VectorIndex?,
                           limit: Int) async -> [DatabaseManager.SonicTrack]? {
        // `availableToken`, not `localToken`: on a client the device's own
        // PlexAuth token is what makes this path work at all. On the server the
        // admin token still resolves, so nothing changes there.
        guard plexSonicEnabled,
              seed.id.hasPrefix(DatabaseManager.plexKeyPrefix),
              let token = PlexClient.availableToken(),
              let base = URL(string: plexBaseURL.trimmingCharacters(in: .whitespaces))
        else { return nil }

        let ratingKey = String(seed.id.dropFirst(DatabaseManager.plexKeyPrefix.count))
        guard !ratingKey.isEmpty else { return nil }

        let client = PlexClient(baseURL: base, token: token)
        // Oversample: the seed, the unknown-to-us hits and the near-duplicate
        // collapse all eat into the list before `limit` is reached.
        guard let hits = try? await client.nearest(ratingKey: ratingKey, limit: limit * 4) else {
            return nil                                   // Plex unreachable / endpoint changed
        }
        guard !hits.isEmpty else { return nil }

        var byID = [String: DatabaseManager.SonicTrack](minimumCapacity: library.count)
        for t in library { byID[t.id] = t }

        var ordered: [VectorIndex.Hit] = []
        ordered.reserveCapacity(hits.count)
        for h in hits where h.ratingKey != ratingKey {
            guard let track = byID[DatabaseManager.plexTrackID(ratingKey: h.ratingKey)] else { continue }
            guard track.matchKey != seed.matchKey else { continue }
            // Plex reports distance; the hygiene layer speaks similarity.
            ordered.append(VectorIndex.Hit(track: track, score: Float(max(0, 1 - h.distance))))
        }
        guard !ordered.isEmpty else { return nil }

        // dropNearDuplicates needs an index for its embedding check; without one
        // it still collapses on title/artist, which is the important half here.
        if let index {
            return SonicSelection.dropNearDuplicates(ordered, index: index, limit: limit).map(\.track)
        }
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert(SonicSelection.titleKey($0.track)).inserted }
            .prefix(limit).map(\.track))
    }

    /// Map the wire type to the database row type. Separate so the parsing
    /// (PlexClient) and the storage shape (DatabaseManager) stay independent.
    ///
    /// `nonisolated`: a pure mapping with no actor state, called from the paging
    /// callback off the main actor (and from tests).
    nonisolated static func libraryRow(_ t: PlexClient.Track) -> DatabaseManager.PlexTrackRow {
        DatabaseManager.PlexTrackRow(
            ratingKey: t.ratingKey,
            title: t.title,
            artist: t.artist,
            album: t.album,
            albumRatingKey: t.albumRatingKey,
            year: t.year,
            filePath: t.filePath,
            thumb: t.thumb)
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
