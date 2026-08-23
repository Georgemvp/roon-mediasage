import Foundation
import GRDB

/// A declarative playlist: a set of rules, evaluated against the library,
/// rather than a frozen list of tracks.
///
/// Navidrome's smart playlists in RoonSage's own vocabulary. The rules that can
/// be answered by SQL are compiled into one `WHERE` clause and run in SQLite —
/// not fetched and filtered in Swift, which on a 66.000-row library means
/// reading the whole table to keep forty rows.
///
/// `sonic_similarity` is the deliberate exception. It compares 512-dimension
/// CLAP embeddings, which SQLite stores as opaque blobs and cannot rank; it is
/// applied afterwards, over the (already small) SQL result, by
/// `RoonClient.smartPlaylistTracks`. The compiler says so explicitly via
/// `needsSonicRanking` instead of silently dropping the rule.
///
/// The JSON spelling is snake_case because these documents are written by hand
/// and stored as text — `bpm_range` is what someone editing a rule expects to
/// type, and matching Navidrome's flavour of the idea costs nothing.
public struct SmartPlaylistRules: Codable, Sendable, Equatable {

    /// An inclusive numeric window. Either end may be omitted, so
    /// `{"min": 120}` means "120 and up".
    public struct Range: Codable, Sendable, Equatable {
        public var min: Double?
        public var max: Double?
        public init(min: Double? = nil, max: Double? = nil) {
            self.min = min
            self.max = max
        }
        var isEmpty: Bool { min == nil && max == nil }
    }

    /// "Sounds like this track." `matchKey` names the seed; `minScore` is the
    /// cosine floor below which a candidate is dropped.
    public struct SonicSimilarity: Codable, Sendable, Equatable {
        public var matchKey: String
        public var minScore: Double
        public init(matchKey: String, minScore: Double = 0.5) {
            self.matchKey = matchKey
            self.minScore = minScore
        }
        enum CodingKeys: String, CodingKey {
            case matchKey = "match_key"
            case minScore = "min_score"
        }
    }

    /// Genres, matched against BOTH sources the library has — Roon's own
    /// `track_genres` and the MusicBrainz/Deezer `track_mb_genres` — and
    /// expanded down the taxonomy, so "electronic" also catches "techno".
    public var genre: [String]?
    public var bpmRange: Range?
    /// Camelot wheel keys ("8A", "11B"). Harmonic mixing is the whole reason
    /// the analyser computes them.
    public var camelotKeys: [String]?
    public var energyRange: Range?
    /// Only tracks last played at least this many days ago — or never played at
    /// all. `0` is meaningless here and is treated as "no rule".
    public var lastPlayedDaysAgo: Int?
    public var minPlayCount: Int?
    public var sonicSimilarity: SonicSimilarity?
    /// Live recordings out by default: a "rules" playlist that quietly fills
    /// with concert versions of the same songs is the first complaint every
    /// generator here has had.
    public var excludeLive: Bool
    public var limit: Int

    public init(genre: [String]? = nil, bpmRange: Range? = nil, camelotKeys: [String]? = nil,
                energyRange: Range? = nil, lastPlayedDaysAgo: Int? = nil, minPlayCount: Int? = nil,
                sonicSimilarity: SonicSimilarity? = nil, excludeLive: Bool = true, limit: Int = 100) {
        self.genre = genre
        self.bpmRange = bpmRange
        self.camelotKeys = camelotKeys
        self.energyRange = energyRange
        self.lastPlayedDaysAgo = lastPlayedDaysAgo
        self.minPlayCount = minPlayCount
        self.sonicSimilarity = sonicSimilarity
        self.excludeLive = excludeLive
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case genre
        case bpmRange          = "bpm_range"
        case camelotKeys       = "camelot_keys"
        case energyRange       = "energy_range"
        case lastPlayedDaysAgo = "last_played_days_ago"
        case minPlayCount      = "min_play_count"
        case sonicSimilarity   = "sonic_similarity"
        case excludeLive       = "exclude_live"
        case limit
    }

    /// Decoding fills the two defaults a hand-written document usually omits.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genre = try c.decodeIfPresent([String].self, forKey: .genre)
        bpmRange = try c.decodeIfPresent(Range.self, forKey: .bpmRange)
        camelotKeys = try c.decodeIfPresent([String].self, forKey: .camelotKeys)
        energyRange = try c.decodeIfPresent(Range.self, forKey: .energyRange)
        lastPlayedDaysAgo = try c.decodeIfPresent(Int.self, forKey: .lastPlayedDaysAgo)
        minPlayCount = try c.decodeIfPresent(Int.self, forKey: .minPlayCount)
        sonicSimilarity = try c.decodeIfPresent(SonicSimilarity.self, forKey: .sonicSimilarity)
        excludeLive = try c.decodeIfPresent(Bool.self, forKey: .excludeLive) ?? true
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100
    }

    public static func decode(json: String) throws -> SmartPlaylistRules {
        try JSONDecoder().decode(SmartPlaylistRules.self, from: Data(json.utf8))
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(self), encoding: .utf8) ?? "{}"
    }
}

// MARK: - Compilation

/// Turns rules into SQL. Split from execution so the interesting half — which
/// clause each rule produces, and which rules SQL cannot answer — is testable
/// without a database.
public enum SmartPlaylistEngine {

    /// A compiled query: the `WHERE` fragments plus their bound arguments, in
    /// matching order, and what the caller still has to do afterwards.
    public struct Compiled: Sendable, Equatable {
        public var whereClauses: [String]
        /// Bound as `DatabaseValue`, not `DatabaseValueConvertible`.
        ///
        /// The existential is not `Sendable` (GRDB v6.29.3 does not mark the
        /// protocol), so a `Compiled` holding one is only `Sendable` by
        /// assertion — which the release build says out loud and Swift 6 mode
        /// would reject. `DatabaseValue` is a concrete `Sendable` struct and is
        /// what SQLite binds anyway, so this is the honest type rather than a
        /// `@preconcurrency` suppression.
        public var arguments: [DatabaseValue]
        /// The play-stat sub-select is not free; only joined when a rule uses it.
        public var needsPlayStats: Bool
        /// Set when a `sonic_similarity` rule survives into the result and the
        /// caller must rank by embedding. Never silently dropped.
        public var sonicSeed: SmartPlaylistRules.SonicSimilarity?
        public var limit: Int

        public var needsSonicRanking: Bool { sonicSeed != nil }

    }

    /// How many extra candidates to fetch when a sonic rule will thin the
    /// result afterwards. Without it a `limit: 40` playlist with a similarity
    /// floor returns far fewer than forty and looks broken.
    static let sonicOverfetch = 8

    /// Compile everything except the genre rule, whose descendant expansion
    /// needs a live database (`DatabaseManager.expandGenres`) and is therefore
    /// added by the executor. Pure otherwise.
    ///
    /// `expandedGenres` is passed in rather than looked up, so a test can hand
    /// over an explicit list and this stays a function of its arguments.
    public static func compile(_ rules: SmartPlaylistRules,
                               expandedGenres: [String] = [],
                               now: Date = Date()) -> Compiled {
        var clauses: [String] = []
        var args: [DatabaseValue] = []
        var needsPlayStats = false

        if !expandedGenres.isEmpty {
            // Both genre sources, exactly as `filterTracks` matches them: Roon's
            // by track id, MusicBrainz/Deezer's by content match key. A track
            // that only one source knows about must still qualify.
            let placeholders = expandedGenres.map { _ in "?" }.joined(separator: ",")
            clauses.append("""
                (t.id IN (SELECT track_id FROM track_genres WHERE LOWER(genre) IN (\(placeholders)))
                 OR t.match_key IN (SELECT match_key FROM track_mb_genres WHERE genre IN (\(placeholders))))
                """)
            args.append(contentsOf: expandedGenres.map(\.databaseValue))
            args.append(contentsOf: expandedGenres.map(\.databaseValue))
        }

        // A NULL bpm/energy/camelot means "not analysed", which is not the same
        // as "outside the range" — but a rule about tempo cannot be satisfied by
        // a track whose tempo is unknown, so those rows are excluded by the
        // comparison itself rather than by an extra IS NOT NULL.
        appendRange(rules.bpmRange, column: "f.bpm", to: &clauses, args: &args)
        appendRange(rules.energyRange, column: "f.energy", to: &clauses, args: &args)

        if let keys = rules.camelotKeys?.filter({ !$0.isEmpty }), !keys.isEmpty {
            let placeholders = keys.map { _ in "?" }.joined(separator: ",")
            clauses.append("UPPER(f.camelot) IN (\(placeholders))")
            args.append(contentsOf: keys.map { $0.uppercased().databaseValue })
        }

        if let days = rules.lastPlayedDaysAgo, days > 0 {
            needsPlayStats = true
            let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(days) * 86_400))
            // "Or never played" is the point of the rule — a track with no
            // history row has by definition not been played in the last N days,
            // and a plain `<` comparison against NULL would drop exactly the
            // tracks the user is trying to resurface.
            clauses.append("(ps.last_played IS NULL OR ps.last_played < ?)")
            args.append(cutoff.databaseValue)
        }

        if let count = rules.minPlayCount, count > 0 {
            needsPlayStats = true
            clauses.append("COALESCE(ps.plays, 0) >= ?")
            args.append(count.databaseValue)
        }

        if rules.excludeLive { clauses.append("t.is_live = 0") }

        // Only a seed that could actually be ranked survives: an empty match key
        // would silently rank against nothing.
        let seed = rules.sonicSimilarity.flatMap { $0.matchKey.isEmpty ? nil : $0 }

        return Compiled(whereClauses: clauses, arguments: args, needsPlayStats: needsPlayStats,
                        sonicSeed: seed,
                        limit: seed == nil ? Swift.max(1, rules.limit)
                                           : Swift.max(1, rules.limit) * sonicOverfetch)
    }

    private static func appendRange(_ range: SmartPlaylistRules.Range?, column: String,
                                    to clauses: inout [String],
                                    args: inout [DatabaseValue]) {
        guard let range, !range.isEmpty else { return }
        if let min = range.min {
            clauses.append("\(column) >= ?")
            args.append(min.databaseValue)
        }
        if let max = range.max {
            clauses.append("\(column) <= ?")
            args.append(max.databaseValue)
        }
    }
}
