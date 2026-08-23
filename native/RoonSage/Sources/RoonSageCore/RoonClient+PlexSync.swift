import Foundation

// MARK: - Plex library sync
//
// Fase 1 of moving the catalogue off Roon's Browse walk. `ingestPlexTracks`
// existed but nothing called it; this is the caller.
//
// Two places run it, for different reasons:
//
//   • the always-on **server** build (`.direct`), which reads the admin token out
//     of the local Preferences.xml and feeds the :5767 share every client pulls
//     from — the original arrangement;
//   • a **standalone client** (`plexStandalone`): signed in to Plex through
//     `PlexAuth`, with no RoonSage server configured. There Plex IS the library,
//     so the client builds it itself and the analyser is optional (user,
//     2026-08-23). Nothing changes for a client that does have a server.

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

    /// This device runs on Plex alone: signed in to Plex, with no RoonSage server
    /// configured.
    ///
    /// The mode the product is aiming at (user, 2026-08-23): *"als je de ios
    /// client start, moet je de eerste keer worden gevraagd in te loggen op plex
    /// en dan moet de app werkende zijn … de analyzer is dus optioneel."* In this
    /// mode the client builds its own library straight from Plex instead of
    /// pulling `/library` off the share server, and analyser-only features ask to
    /// connect rather than blocking the app.
    public var plexStandalone: Bool {
        guard plexLinked else { return false }
        let server = UserDefaults.standard.string(forKey: "library_import_url") ?? ""
        return server.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Re-read the Keychain into the observable `plexLinked`, and start or stop
    /// the import to match. Call after every sign-in and sign-out.
    public func refreshPlexLinkState() {
        plexLinked = PlexAuth.storedToken() != nil
        guard plexLinked else { stopPlexSync(); return }
        Task { [weak self] in
            // Find out where Plex actually IS before syncing. The default is
            // loopback, which on a phone means the phone — a linked device would
            // otherwise sync 0 tracks and say nothing about why.
            await self?.resolvePlexServer()
            guard let self, self.plexStandalone else { return }
            self.startPlexSync()
            // Don't make a fresh sign-in wait out the 120 s start-up delay before
            // the library appears — that delay exists to let the server's Roon
            // connect settle, which a standalone client does not have.
            await self.runPlexSync()
        }
    }

    /// Point `plexBaseURL` at a route that answers, via plex.tv.
    ///
    /// Skipped when Plex runs on this machine (the server build reads the admin
    /// token locally and loopback is genuinely correct there). Leaves the current
    /// value alone when nothing answers, so a working manual address is never
    /// replaced by a failed probe.
    @discardableResult
    public func resolvePlexServer() async -> Bool {
        guard PlexClient.localToken() == nil else { return false }
        guard let found = await PlexAuth.reachableServer() else { return false }
        plexBaseURL = found.baseURL
        Log.info("Plex-server gevonden op \(found.baseURL)", category: .network)
        return true
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
        // Ook op een standalone client: dáár IS Plex de bibliotheek, en zonder
        // deze taak blijft hij na het inloggen leeg.
        guard controlMode == .direct || plexStandalone else { return }
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
        let outcome = await performPlexSync()
        plexLastSyncMessage = Self.describe(outcome)
        return outcome
    }

    /// Leesbare samenvatting voor de lege-bibliotheek-melding.
    static func describe(_ outcome: PlexSyncOutcome) -> String? {
        switch outcome {
        case .disabled:        return nil
        case .noToken:         return CoreStrings.s("core.plex.noToken", "Nog niet met Plex gekoppeld.")
        case .noMusicSection:  return CoreStrings.s("core.plex.noSection", "Deze Plex-server heeft geen muzieksectie.")
        case let .failed(msg): return String(format: CoreStrings.s("core.plex.failed", "Plex-import mislukt: %@"), msg)
        case let .imported(r): return r.total == 0
            ? CoreStrings.s("core.plex.empty", "Plex gaf geen nummers terug.")
            : nil
        }
    }

    private func performPlexSync() async -> PlexSyncOutcome {
        // De schakelaar beschermt een BESTAANDE Roon-catalogus tegen verdringing.
        // Een standalone client heeft die niet — daar is Plex de enige bron, dus
        // daar hoort de import gewoon te lopen zonder dat je eerst een vinkje moet
        // vinden. Anders is "log in en het werkt" niet waar.
        guard plexSyncEnabled || plexStandalone else { return .disabled }
        guard let db = database else { return .failed("geen database") }
        guard let token = PlexClient.availableToken() else { return .noToken }
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

    // MARK: - Fase 4: direct afspelen vanaf Plex

    /// Stream audio straight from Plex instead of through the analyser's `/audio`.
    ///
    /// Default off. Needs a Plex sign-in on this device (`PlexAuth`) — without one
    /// `availableToken()` is nil on a client and every track falls back to the
    /// analyser, which is the behaviour we have today.
    public var plexDirectPlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "plex_direct_play_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "plex_direct_play_enabled") }
    }

    /// Direct-play URLs for the Plex rows among `records`, keyed by content key.
    ///
    /// Empty when direct play is off, no Plex token is available, or none of the
    /// records is a Plex row — the caller then queues them the old way. One
    /// batched request for the whole queue; a failure yields an empty map rather
    /// than a half-filled one, so a queue never silently splits across two
    /// transports mid-album.
    func plexStreamURLs(for records: [TrackRecord]) async -> [String: (url: URL, format: String)] {
        guard plexDirectPlayEnabled,
              let token = PlexClient.availableToken(),
              let base = URL(string: plexBaseURL.trimmingCharacters(in: .whitespaces))
        else { return [:] }

        // content key → rating key, for the Plex rows only.
        var ratingKeyByContentKey: [String: String] = [:]
        for rec in records where rec.id.hasPrefix(DatabaseManager.plexKeyPrefix) {
            let rk = String(rec.id.dropFirst(DatabaseManager.plexKeyPrefix.count))
            guard !rk.isEmpty else { continue }
            ratingKeyByContentKey[LocalPlayability.matchKey(for: rec)] = rk
        }
        guard !ratingKeyByContentKey.isEmpty else { return [:] }

        let client = PlexClient(baseURL: base, token: token)
        guard let parts = try? await client.parts(
            ratingKeys: Array(Set(ratingKeyByContentKey.values))) else { return [:] }

        var out: [String: (url: URL, format: String)] = [:]
        for (contentKey, rk) in ratingKeyByContentKey {
            guard let info = parts[rk], let url = client.streamURL(partKey: info.key) else { continue }
            out[contentKey] = (url, info.summary)
        }
        return out
    }

    /// Neighbour pool for a station, straight from Plex's Sonic Analysis.
    ///
    /// This is the speed path (user, 2026-08-23: *"Er moet gebruikt worden van
    /// plex eigen analyse functie, zodat dit allemaal sneller gaat qua mixes,
    /// radio's en slimme queues"*). The local route ranks 66k CLAP vectors; Plex
    /// answers the same question with one HTTP call per seed, because it did the
    /// analysis server-side and keeps its own index.
    ///
    /// Empty means "Plex had nothing usable" — the caller then runs the local
    /// engine exactly as before. Never a partial answer dressed up as a full one.
    func plexStationPool(seedIds: [String],
                         library: [DatabaseManager.SonicTrack],
                         limit: Int) async -> [DatabaseManager.SonicTrack] {
        guard plexSonicEnabled,
              let token = PlexClient.availableToken(),
              let base = URL(string: plexBaseURL.trimmingCharacters(in: .whitespaces))
        else { return [] }

        // Only the Plex-sourced seeds can be asked about. Cap the fan-out: a
        // station seeded on 60 of an artist's tracks does not need 60 round-trips
        // to know what that artist sounds like.
        let ratingKeys = seedIds
            .filter { $0.hasPrefix(DatabaseManager.plexKeyPrefix) }
            .prefix(Self.plexStationSeedCap)
            .map { String($0.dropFirst(DatabaseManager.plexKeyPrefix.count)) }
        guard !ratingKeys.isEmpty else { return [] }

        let client = PlexClient(baseURL: base, token: token)
        var byID = [String: DatabaseManager.SonicTrack](minimumCapacity: library.count)
        for t in library { byID[t.id] = t }
        let seedSet = Set(seedIds)

        // Best score wins when several seeds return the same track — that is what
        // makes this a POOL and not a concatenation of k-NN lists.
        var best: [String: (track: DatabaseManager.SonicTrack, score: Float)] = [:]
        for rk in ratingKeys {
            guard let hits = try? await client.nearest(ratingKey: rk, limit: limit) else { continue }
            for h in hits {
                let id = DatabaseManager.plexTrackID(ratingKey: h.ratingKey)
                guard !seedSet.contains(id), let track = byID[id] else { continue }
                let score = Float(max(0, 1 - h.distance))
                if let existing = best[id], existing.score >= score { continue }
                best[id] = (track, score)
            }
        }
        guard !best.isEmpty else { return [] }

        // Plex does no duplicate hygiene at all; without this a station happily
        // plays the same recording from three different albums.
        let ordered = best.values.sorted { $0.score > $1.score }
            .map { VectorIndex.Hit(track: $0.track, score: $0.score) }
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert(SonicSelection.titleKey($0.track)).inserted }
            .prefix(limit).map(\.track))
    }

    /// How many seed tracks a station asks Plex about. Beyond a handful the extra
    /// round-trips buy nothing: the neighbourhoods overlap heavily.
    static let plexStationSeedCap = 6

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
