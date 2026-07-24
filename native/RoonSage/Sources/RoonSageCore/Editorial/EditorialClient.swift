import Foundation
import GRDB

/// A piece of editorial text (bio or review) plus where it came from, for
/// attribution on the detail page.
public struct Editorial: Sendable, Equatable {
    public let body: String
    public let source: String
    public init(body: String, source: String) {
        self.body = body
        self.source = source
    }
}

// MARK: - Cache accessors (editorial_cache, TTL-gated, negative-caching)

extension DatabaseManager {
    public enum CachedEditorial: Sendable {
        case fresh(Editorial?)   // within TTL; nil = known-absent (negative cache)
        case stale
        case missing
    }

    public func cachedEditorial(entityType: String, entityKey: String, kind: String,
                                maxAgeDays: Int) async -> CachedEditorial {
        (try? await pool.read { db -> CachedEditorial in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT body, source, fetched_at FROM editorial_cache
                WHERE entity_type = ? AND entity_key = ? AND kind = ?
                """, arguments: [entityType, entityKey, kind]) else { return .missing }
            let fetched = (row["fetched_at"] as String?).flatMap { Self.isoFormatter.date(from: $0) }
            let age = fetched.map { Date().timeIntervalSince($0) } ?? .infinity
            guard age < Double(maxAgeDays) * 86_400 else { return .stale }
            if let body = row["body"] as String? {
                return .fresh(Editorial(body: body, source: (row["source"] as String?) ?? ""))
            }
            return .fresh(nil)   // negative cache: we looked and there was nothing
        }) ?? .missing
    }

    public func saveEditorial(entityType: String, entityKey: String, kind: String,
                              editorial: Editorial?) async {
        let now = Self.isoFormatter.string(from: Date())
        try? await pool.write { db in
            try db.execute(sql: """
                INSERT INTO editorial_cache (entity_type, entity_key, kind, body, source, fetched_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(entity_type, entity_key, kind)
                DO UPDATE SET body = excluded.body, source = excluded.source, fetched_at = excluded.fetched_at
                """, arguments: [entityType, entityKey, kind, editorial?.body, editorial?.source, now])
        }
    }
}

// MARK: - Orchestration

@MainActor
extension RoonClient {
    /// Artist biography for the detail page: cached editorial refreshed after 30
    /// days, Wikipedia primary → Last.fm fallback. Negative results cache too, so a
    /// missing artist isn't re-fetched from every source on every visit.
    public func artistEditorial(name: String) async -> Editorial? {
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let db = database {
            switch await db.cachedEditorial(entityType: "artist", entityKey: key, kind: "bio", maxAgeDays: 30) {
            case .fresh(let editorial): return editorial
            case .stale, .missing: break
            }
        }
        var result: Editorial?
        if let wiki = await WikipediaClient.shared.summary(title: name) {
            result = Editorial(body: wiki.text, source: "Wikipedia")
        } else if let apiKey = KeychainStore.load(key: "lastfm_api_key"), !apiKey.isEmpty,
                  let bio = await LastfmClient.shared.getArtistBio(artist: name, apiKey: apiKey) {
            result = Editorial(body: bio, source: "Last.fm")
        }
        if let db = database {
            await db.saveEditorial(entityType: "artist", entityKey: key, kind: "bio", editorial: result)
        }
        return result
    }

    /// Album review/description for the detail page: cached 30 days, from Wikipedia
    /// (Qobuz editorial is a future source). Tries the "<Album> (<Artist> album)"
    /// disambiguation title first, then the bare title. Negative results cache too.
    public func albumReview(album: String, artist: String?) async -> Editorial? {
        guard !album.isEmpty else { return nil }
        let key = "\(album.lowercased())|\((artist ?? "").lowercased())"
        if let db = database {
            switch await db.cachedEditorial(entityType: "album", entityKey: key, kind: "review", maxAgeDays: 30) {
            case .fresh(let editorial): return editorial
            case .stale, .missing: break
            }
        }
        var result: Editorial?
        let titles: [String] = artist.map { ["\(album) (\($0) album)", album] } ?? [album]
        for title in titles {
            if let wiki = await WikipediaClient.shared.summary(title: title) {
                result = Editorial(body: wiki.text, source: "Wikipedia")
                break
            }
        }
        if let db = database {
            await db.saveEditorial(entityType: "album", entityKey: key, kind: "review", editorial: result)
        }
        return result
    }
}
