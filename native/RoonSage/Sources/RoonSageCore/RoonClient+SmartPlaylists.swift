import Foundation

@MainActor
extension RoonClient {

    // MARK: - Smart playlists

    /// Evaluate a declarative playlist against the library.
    ///
    /// Two stages, because the rules are two different kinds of question. The
    /// scalar rules (genre, tempo, key, energy, play history) go to SQLite,
    /// which is where a 66.000-row filter belongs. `sonic_similarity` compares
    /// CLAP embeddings, which SQLite holds as opaque blobs and cannot rank — so
    /// the SQL stage over-fetches (`SmartPlaylistEngine.sonicOverfetch`) and
    /// this ranks and trims what comes back.
    ///
    /// Library-first by construction: every row comes out of the `tracks` table.
    /// Nothing here can invent a track.
    public func smartPlaylistTracks(_ rules: SmartPlaylistRules) async -> [DatabaseManager.LibraryTrackRow] {
        guard let db = database else { return [] }
        guard let rows = try? await db.smartPlaylistTracks(rules), !rows.isEmpty else { return [] }

        let compiled = SmartPlaylistEngine.compile(rules)
        guard let seed = compiled.sonicSeed else { return Array(rows.prefix(max(1, rules.limit))) }

        // A similarity rule the library cannot answer — no embeddings yet, or a
        // seed that was never analysed — returns nothing rather than silently
        // handing back the unranked SQL result. A playlist that ignores half its
        // definition is worse than an empty one, because it looks like it worked.
        guard let index = await activeIndex(db),
              let seedID = index.tracks.first(where: { $0.matchKey == seed.matchKey })?.id,
              let seedVector = index.centroid(ofIds: [seedID]) else { return [] }

        var rowByID: [String: DatabaseManager.LibraryTrackRow] = [:]
        for row in rows { rowByID[row.id] = row }

        // Score each candidate against the seed. Both vectors come back
        // L2-normalised, so cosine is the plain dot product.
        let scored: [(row: DatabaseManager.LibraryTrackRow, score: Float)] = rows.compactMap { row in
            guard let mk = row.matchKey, !mk.isEmpty,
                  let id = index.tracks.first(where: { $0.matchKey == mk })?.id,
                  let vector = index.embedding(forId: id) else { return nil }
            let normalised = Self.l2Normalised(vector)
            var dot: Float = 0
            for i in 0..<Swift.min(normalised.count, seedVector.count) { dot += normalised[i] * seedVector[i] }
            return dot >= Float(seed.minScore) ? (row, dot) : nil
        }
        return scored.sorted { $0.score > $1.score }
            .prefix(max(1, rules.limit))
            .map(\.row)
    }

    /// `VectorIndex` normalises on the way in but `embedding(forId:)` returns
    /// the row as stored, so a raw vector has to be normalised before a dot
    /// product means cosine.
    private static func l2Normalised(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Save a smart playlist's current result as an ordinary playlist.
    ///
    /// A snapshot on purpose: the rules describe a moment, and the saved list is
    /// what you can then reorder, share and play without it changing under you.
    /// Re-running the rules is one tap away.
    public func saveSmartPlaylist(name: String, rules: SmartPlaylistRules) async -> Int64? {
        let rows = await smartPlaylistTracks(rules)
        guard !rows.isEmpty, let db = database else { return nil }
        // Mapped here rather than via `LibraryTrackRow.asTrackRecord`: that
        // convenience lives in `RoonSageUI`, above this module.
        let records = rows.map {
            TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album,
                        year: $0.year, isLive: $0.isLive, matchKey: $0.matchKey, imageKey: $0.imageKey)
        }
        return try? await db.savePlaylist(name: name, tracks: records)
    }

    // MARK: - Automatic recaps

    public static let recapTaskName = "recaps"

    /// Regenerate the weekly + monthly recaps, daily, on the server-of-record.
    ///
    /// Server-only (`.direct`) for the same reason playlists are: the analyser
    /// owns the playlist table and every client reads it, so generating them on
    /// each device would produce N copies of the same four lists.
    ///
    /// Daily rather than weekly, and cheap because of it: a period that has
    /// already been summarised produces byte-identical rows, and
    /// `syncExternalPlaylists` replaces them in place. The gain is that a recap
    /// appears the day a week closes instead of up to seven days later.
    public func startRecapGeneration() {
        guard controlMode == .direct else { return }
        Task {
            await TaskScheduler.shared.register(
                name: Self.recapTaskName,
                title: "Terugblikken bijwerken",
                interval: 24 * 60 * 60,
                // After the library sync — a recap resolves history to library
                // rows, so it wants the rows to be there.
                initialDelay: 300
            ) { [weak self] in
                guard let self, let db = await self.database else { return .skipped }
                let names = await RecapService(database: db).regenerate()
                Log.info("Terugblikken: \(names.count) lijsten bijgewerkt", category: .network)
                return .completed
            }
        }
    }

    public func stopRecapGeneration() {
        Task { await TaskScheduler.shared.unregister(Self.recapTaskName) }
    }

    /// Build the recaps once, now — for a "ververs" button and for the first
    /// launch after this shipped, when waiting five minutes for the scheduler
    /// would look like the feature is missing.
    @discardableResult
    public func regenerateRecaps() async -> [String] {
        guard let db = database else { return [] }
        return await RecapService(database: db).regenerate()
    }
}
