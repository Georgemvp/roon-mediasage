import Foundation

// MARK: - "Aanbevelingen" — discovery results as a Qobuz playlist
//
// The Ontdek feed ("Nieuw voor jou") shows recommendations one card at a time,
// which only works while you're sitting in the app. This mirrors the same batch
// into a plain Qobuz playlist so the recommendations are listenable from Roon
// like any other RoonSage station (user, 2026-08-07: "aanbevelingen").
//
// Source of truth is the newest COMPLETE discovery batch — the same rows the feed
// renders — so the playlist can never disagree with what the app shows. Since
// 2026-08-07 that batch is seeded on RECENT listening (see
// `RoonClient.mergeRecentFirst`), which is what makes this "recommendations based
// on what I've been playing" rather than a static all-time-taste list.
//
// Only ALBUM recommendations are usable: an artist card carries no Qobuz album id,
// and picking "some track by this artist" would be a different (and much weaker)
// recommendation than the one that was actually scored.

extension RoonClient {

    /// Stable, literal playlist title — this is a station you look up BY NAME, so
    /// it is never LLM-titled (same reasoning as `fixedMeta`).
    public nonisolated static let recommendationsPlaylistTitle = "Aanbevelingen"

    /// Qobuz playlist name, inside the shared "RoonSage · " namespace.
    nonisolated static var recommendationsQobuzName: String {
        qobuzPlaylistName(for: recommendationsPlaylistTitle)
    }

    private static let recommendationsQobuzIDKey = "recommendations.qobuzid.v1"

    /// How many recommended albums feed the playlist, and how many tracks we take
    /// from each. Two per album keeps a 20-album batch at a listenable ~40 tracks
    /// while still representing every recommendation.
    nonisolated static let recommendationsAlbumLimit = 20
    nonisolated static let recommendationsTracksPerAlbum = 2

    /// Names/ids the shared AI-radio reconcile must NOT prune. Without this the
    /// reconcile — which deletes every "RoonSage · " playlist outside its keep set
    /// — would delete this playlist immediately after each sync creates it.
    func recommendationsQobuzKeep() -> (names: Set<String>, ids: Set<String>) {
        var ids = Set<String>()
        if let id = UserDefaults.standard.string(forKey: Self.recommendationsQobuzIDKey), !id.isEmpty {
            ids.insert(id)
        }
        return ([Self.recommendationsQobuzName], ids)
    }

    /// Pick the tracks for the playlist from the batch's album recommendations,
    /// preserving batch order (already best-score-first).
    ///
    /// Pure so the selection rules are testable without Qobuz or a database:
    /// `tracksByAlbumID` is what `albumTrackTitles` returned per album id.
    nonisolated static func recommendationsTrackList(
        albums: [(qobuzAlbumID: String, artist: String, album: String)],
        tracksByAlbumID: [String: [(title: String, artist: String?)]],
        perAlbum: Int
    ) -> [(title: String, artist: String?, album: String?)] {
        var out: [(title: String, artist: String?, album: String?)] = []
        var seen = Set<String>()
        for a in albums {
            let picked = (tracksByAlbumID[a.qobuzAlbumID] ?? []).prefix(perAlbum)
            for t in picked where !t.title.isEmpty {
                // The same track can appear on several recommended albums (a single
                // plus the album it's from); one Qobuz playlist slot each.
                let key = "\(t.title.lowercased())\u{1f}\((t.artist ?? a.artist).lowercased())"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append((title: t.title, artist: t.artist ?? a.artist, album: a.album))
            }
        }
        return out
    }

    /// Build/refresh the "Aanbevelingen" playlist on Qobuz from the newest complete
    /// discovery batch. Returns the number of tracks synced (0 = nothing to do).
    ///
    /// No-op without Qobuz credentials or when the batch has no actionable album
    /// recommendations — in both cases any existing playlist is left untouched
    /// rather than emptied (`syncPlaylist` refuses to clear a playlist too).
    @discardableResult
    public func syncRecommendationsToQobuz() async -> Int {
        guard controlMode == .direct, let db = database else { return 0 }
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return 0 }

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

        // Sequential on purpose: album/get is the same endpoint the radio sync
        // hammers, and this runs right after it. Parallel fan-out here is what
        // provoked the 503s documented in the Qobuz open item.
        var tracksByAlbum: [String: [(title: String, artist: String?)]] = [:]
        for a in albums {
            let titles = await QobuzClient.shared.albumTrackTitles(
                albumID: a.qobuzAlbumID, email: email, password: pw)
            if !titles.isEmpty { tracksByAlbum[a.qobuzAlbumID] = titles }
        }

        let tracks = Self.recommendationsTrackList(
            albums: albums, tracksByAlbumID: tracksByAlbum,
            perAlbum: Self.recommendationsTracksPerAlbum)
        guard !tracks.isEmpty else {
            Log.warning("Aanbevelingen-playlist: 0 tracks opgehaald voor \(albums.count) album(s) — playlist ongemoeid gelaten",
                        category: .network)
            return 0
        }

        let known = UserDefaults.standard.string(forKey: Self.recommendationsQobuzIDKey)
        let result = await QobuzClient.shared.syncPlaylist(
            name: Self.recommendationsQobuzName,
            description: "Aanbevelingen op basis van wat je recent hebt geluisterd — samengesteld door RoonSage.",
            tracks: tracks, email: email, password: pw,
            knownPlaylistID: known?.isEmpty == false ? known : nil)
        guard let result else { return 0 }
        UserDefaults.standard.set(result.playlistID, forKey: Self.recommendationsQobuzIDKey)
        Log.info("Aanbevelingen-playlist gesynct naar Qobuz: \(tracks.count) tracks uit \(albums.count) aanbevolen album(s)",
                 category: .network)
        return tracks.count
    }
}
