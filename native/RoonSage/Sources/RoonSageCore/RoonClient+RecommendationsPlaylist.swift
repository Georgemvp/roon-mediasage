import Foundation

// MARK: - Discovery results as Qobuz playlists
//
// The Ontdek feed shows recommendations one card at a time, which only works
// while you're sitting in the app. These mirror the same batch into plain Qobuz
// playlists so they're listenable from Roon (user, 2026-08-07).
//
// TWO playlists, split the way the feed itself splits (its "Soort" picker):
//
//   • "Nieuw voor jou"  — recommended ARTISTS you don't own, one track each.
//   • "Aanbevelingen"   — recommended ALBUMS you don't own, 1–3 tracks each.
//
// Source of truth is the newest COMPLETE batch — the same rows the feed renders —
// so playlist and app can't disagree. That batch is seeded on RECENT listening
// (see `mergeRecentFirst`), which is what makes these "based on what I've been
// playing" rather than a static all-time-taste list.

extension RoonClient {

    /// Literal, stable playlist titles — these are looked up BY NAME in Roon, so
    /// they are never LLM-titled (same reasoning as `fixedMeta`).
    public nonisolated static let recommendationsPlaylistTitle = "Aanbevelingen"
    public nonisolated static let newForYouPlaylistTitle = "Nieuw voor jou"

    nonisolated static var recommendationsQobuzName: String {
        qobuzPlaylistName(for: recommendationsPlaylistTitle)
    }
    nonisolated static var newForYouQobuzName: String {
        qobuzPlaylistName(for: newForYouPlaylistTitle)
    }

    private static let recommendationsQobuzIDKey = "recommendations.qobuzid.v1"
    private static let newForYouQobuzIDKey       = "newforyou.qobuzid.v1"

    nonisolated static let recommendationsAlbumLimit = 20
    /// How many recommended artists become one track each in "Nieuw voor jou".
    nonisolated static let newForYouArtistLimit = 25

    /// Names/ids the shared AI-radio reconcile must NOT prune. Without this the
    /// reconcile — which deletes every "RoonSage · " playlist outside its keep set
    /// — deletes these moments after each sync creates them.
    func discoveryPlaylistsQobuzKeep() -> (names: Set<String>, ids: Set<String>) {
        let d = UserDefaults.standard
        var ids = Set<String>()
        for key in [Self.recommendationsQobuzIDKey, Self.newForYouQobuzIDKey] {
            if let id = d.string(forKey: key), !id.isEmpty { ids.insert(id) }
        }
        return ([Self.recommendationsQobuzName, Self.newForYouQobuzName], ids)
    }

    // MARK: Track budgeting

    /// How many tracks to take from one recommended release.
    ///
    /// Scales with the release: taking a fixed 2 produced "two tracks off a
    /// single" (user, 2026-08-07 — several recommendations were singles like
    /// "Señorita" and "Jason's Song", where 2-of-1 is meaningless). A single
    /// contributes one track; a real album gets a little more room.
    nonisolated static func tracksToTake(fromReleaseOf trackCount: Int) -> Int {
        switch trackCount {
        case ..<2:  return 1      // single
        case 2...4: return 1      // EP / short release — still just a taster
        case 5...8: return 2
        default:    return 3      // full album
        }
    }

    /// Build the track list for the ALBUM playlist, preserving batch order
    /// (already best-score-first). Pure so the budgeting is testable.
    nonisolated static func recommendationsTrackList(
        albums: [(qobuzAlbumID: String, artist: String, album: String)],
        tracksByAlbumID: [String: [(title: String, artist: String?)]]
    ) -> [(title: String, artist: String?, album: String?)] {
        var out: [(title: String, artist: String?, album: String?)] = []
        var seen = Set<String>()
        for a in albums {
            // Drop unusable rows BEFORE budgeting: a blank title would otherwise
            // consume one of the release's slots and silently shrink its share.
            let all = (tracksByAlbumID[a.qobuzAlbumID] ?? []).filter { !$0.title.isEmpty }
            for t in all.prefix(tracksToTake(fromReleaseOf: all.count)) {
                // The same track can sit on several recommended releases (a single
                // and the album it came from); one playlist slot each.
                let key = "\(t.title.lowercased())\u{1f}\((t.artist ?? a.artist).lowercased())"
                guard seen.insert(key).inserted else { continue }
                out.append((title: t.title, artist: t.artist ?? a.artist, album: a.album))
            }
        }
        return out
    }

    /// One track per recommended artist, batch order preserved. Pure.
    nonisolated static func newForYouTrackList(
        artists: [String],
        trackByArtist: [String: (title: String, album: String?)]
    ) -> [(title: String, artist: String?, album: String?)] {
        var out: [(title: String, artist: String?, album: String?)] = []
        var seen = Set<String>()
        for a in artists {
            guard let t = trackByArtist[a], !t.title.isEmpty else { continue }
            guard seen.insert(a.lowercased()).inserted else { continue }
            out.append((title: t.title, artist: a, album: t.album))
        }
        return out
    }

    // MARK: Sync

    /// Refresh both discovery playlists. Returns the total tracks written.
    @discardableResult
    public func syncDiscoveryPlaylistsToQobuz() async -> Int {
        guard controlMode == .direct, database != nil else { return 0 }
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return 0 }
        let albums = await syncRecommendationsToQobuz(email: email, password: pw)
        let artists = await syncNewForYouToQobuz(email: email, password: pw)
        return albums + artists
    }

    /// "Aanbevelingen" — recommended ALBUMS.
    @discardableResult
    func syncRecommendationsToQobuz(email: String, password: String) async -> Int {
        guard let db = database else { return 0 }
        let rows = (try? await db.latestRecommendationItems(
            kind: .album, limit: Self.recommendationsAlbumLimit, pendingOnly: false)) ?? []
        let albums: [(qobuzAlbumID: String, artist: String, album: String)] = rows.compactMap {
            guard let qid = $0.dto.qobuzAlbumID, !qid.isEmpty,
                  let album = $0.dto.album, !album.isEmpty else { return nil }
            return (qobuzAlbumID: qid, artist: $0.dto.artist, album: album)
        }
        guard !albums.isEmpty else {
            Log.info("Aanbevelingen-playlist: geen album-aanbevelingen met Qobuz-id in de laatste batch — overgeslagen",
                     category: .network)
            return 0
        }
        // Sequential: album/get is the same endpoint the radio sync just hammered,
        // and parallel fan-out is what provoked the 503s in the Qobuz open item.
        var byAlbum: [String: [(title: String, artist: String?)]] = [:]
        for a in albums {
            let t = await QobuzClient.shared.albumTrackTitles(
                albumID: a.qobuzAlbumID, email: email, password: password)
            if !t.isEmpty { byAlbum[a.qobuzAlbumID] = t }
        }
        let tracks = Self.recommendationsTrackList(albums: albums, tracksByAlbumID: byAlbum)
        return await write(tracks: tracks, name: Self.recommendationsQobuzName,
                           description: "Aanbevolen albums op basis van wat je recent hebt geluisterd — samengesteld door RoonSage.",
                           idKey: Self.recommendationsQobuzIDKey,
                           label: "Aanbevelingen", email: email, password: password)
    }

    /// "Nieuw voor jou" — recommended ARTISTS, one track each.
    ///
    /// Artist recommendations carry no `qobuzAlbumID` (there's no album to point
    /// at), so each artist is resolved through their best-matching Qobuz album and
    /// that album's opening track stands in for them.
    @discardableResult
    func syncNewForYouToQobuz(email: String, password: String) async -> Int {
        guard let db = database else { return 0 }
        let rows = (try? await db.latestRecommendationItems(
            kind: .artist, limit: Self.newForYouArtistLimit, pendingOnly: false)) ?? []
        let names = rows.map(\.dto.artist).filter { !$0.isEmpty }
        guard !names.isEmpty else {
            Log.info("Nieuw voor jou-playlist: geen artiest-aanbevelingen in de laatste batch — overgeslagen",
                     category: .network)
            return 0
        }
        var trackByArtist: [String: (title: String, album: String?)] = [:]
        for name in names {
            let found = await QobuzClient.shared.searchArtistAlbums(
                artist: name, email: email, password: password, limit: 1)
            guard let album = found.first else { continue }
            let titles = await QobuzClient.shared.albumTrackTitles(
                albumID: album.id, email: email, password: password)
            guard let first = titles.first(where: { !$0.title.isEmpty }) else { continue }
            trackByArtist[name] = (title: first.title, album: album.title)
        }
        let tracks = Self.newForYouTrackList(artists: names, trackByArtist: trackByArtist)
        return await write(tracks: tracks, name: Self.newForYouQobuzName,
                           description: "Nieuwe artiesten die passen bij wat je recent hebt geluisterd — samengesteld door RoonSage.",
                           idKey: Self.newForYouQobuzIDKey,
                           label: "Nieuw voor jou", email: email, password: password)
    }

    /// Shared write path: never clears an existing playlist on an empty resolve.
    private func write(tracks: [(title: String, artist: String?, album: String?)],
                       name: String, description: String, idKey: String,
                       label: String, email: String, password: String) async -> Int {
        guard !tracks.isEmpty else {
            Log.warning("\(label)-playlist: 0 bruikbare tracks opgehaald — playlist ongemoeid gelaten",
                        category: .network)
            return 0
        }
        let known = UserDefaults.standard.string(forKey: idKey)
        guard let result = await QobuzClient.shared.syncPlaylist(
            name: name, description: description, tracks: tracks,
            email: email, password: password,
            knownPlaylistID: known?.isEmpty == false ? known : nil)
        else {
            // syncPlaylist returning nil is a real outcome (no match, shrink guard,
            // API failure) and it logs its own reason — but returning 0 silently
            // here left the caller's log showing NOTHING for this playlist, which
            // is how a guard-blocked sync went unnoticed.
            Log.warning("\(label)-playlist: Qobuz-sync leverde niets op voor \(tracks.count) track(s) — zie de Qobuz-regel hierboven",
                        category: .network)
            return 0
        }
        UserDefaults.standard.set(result.playlistID, forKey: idKey)
        Log.info("\(label)-playlist gesynct naar Qobuz: \(tracks.count) tracks", category: .network)
        return tracks.count
    }
}
