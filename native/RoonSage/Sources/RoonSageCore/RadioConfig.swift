import Foundation
import GRDB

// MARK: - Custom radio config (user-composed sonic radio)
//
// A `RadioConfig` is a NAMED bundle of seed facets the user assembles themselves:
// any mix of artists, tracks, genres, moods and activities (optionally decades).
// Unlike the engine's auto-generated stations (`RadioCategory`), these are
// first-class, editable entities that live on the server-of-record so every
// client sees the same set — and that the always-on analyzer materialises into a
// stable Qobuz playlist. The same definition also plays as an endless station.
//
// Facet roles (see RoonClient+CustomRadio):
//   • artists / tracks   — SEED-ONLY (proximity is the definition; no gate).
//   • genres / moods / activities / decades — SEED **and** a measured GATE that
//     is AND-ed together (with relaxation) so the station stays true to its name.
//
// Array facets are stored as JSON-text columns (GRDB encodes non-scalar Codable
// properties as JSON automatically); the same struct doubles as the wire DTO the
// client POSTs/GETs over `/radio-configs`, so client and server share one shape.

public struct RadioConfig: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "radio_configs"

    public var id: String                 // uuid; the radio id is "custom:<id>"
    public var name: String
    public var enabled: Bool
    public var syncToQobuz: Bool
    public var artists: [String]          // artist display names (seed-only)
    public var trackKeys: [String]        // match_keys (seed-only)
    public var genres: [String]           // lowercased genre keys (seed + gate)
    public var moods: [String]            // CLAP mood keys (seed + gate)
    public var activities: [String]       // activity profile keys (seed + gate)
    public var decades: [Int]             // release decades, e.g. 1980 (seed + gate)
    public var adventurousness: Double    // 0…1, mirrors RoonClient.radioAdventurousness
    public var targetCount: Int           // playlist / first-batch size
    public var qobuzPlaylistID: String?   // resolved once mirrored (rename-in-place)
    public var updatedAt: String          // ISO-8601, bumped on every save

    /// Stable radio id used by playback + the gate lookup ("custom:<uuid>").
    public var radioID: String { "custom:\(id)" }

    /// True when at least one facet is set — an empty config can't seed anything.
    public var hasFacets: Bool {
        !artists.isEmpty || !trackKeys.isEmpty || !genres.isEmpty
            || !moods.isEmpty || !activities.isEmpty || !decades.isEmpty
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        syncToQobuz: Bool = true,
        artists: [String] = [],
        trackKeys: [String] = [],
        genres: [String] = [],
        moods: [String] = [],
        activities: [String] = [],
        decades: [Int] = [],
        adventurousness: Double = RoonClient.defaultAdventurousness,
        targetCount: Int = 25,
        qobuzPlaylistID: String? = nil,
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.syncToQobuz = syncToQobuz
        self.artists = artists
        self.trackKeys = trackKeys
        self.genres = genres
        self.moods = moods
        self.activities = activities
        self.decades = decades
        self.adventurousness = adventurousness
        self.targetCount = targetCount
        self.qobuzPlaylistID = qobuzPlaylistID
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, artists, genres, moods, activities, decades
        case syncToQobuz     = "sync_to_qobuz"
        case trackKeys       = "track_keys"
        case adventurousness
        case targetCount     = "target_count"
        case qobuzPlaylistID = "qobuz_playlist_id"
        case updatedAt       = "updated_at"
    }
}

// MARK: - From an automatic station

public extension RadioConfig {
    /// Turn one of the engine's automatic stations into an editable, saveable
    /// config — "keep this one".
    ///
    /// **This is the whole point of the plan's fase 4 in one function.** A
    /// `RadioConfig` is the general case: an artist station is
    /// `RadioConfig(artists: [...])`, `genre:house` is
    /// `RadioConfig(genres: ["house"])`, and a station with no metadata facet at
    /// all (a sonic cluster, an album) is one with its seed tracks pinned. The
    /// automatic stations were a second, parallel notion of the same thing;
    /// this maps one onto the other.
    ///
    /// `seedMatchKeys` is only consulted for the id prefixes that carry no facet
    /// of their own — a cluster or an album has no genre to name it by, so its
    /// seeds ARE its definition.
    ///
    /// Returns nil when the id has a shape we don't know, rather than inventing
    /// a config that would build a different station than the one you heard.
    static func fromStation(
        id radioID: String,
        name: String,
        adventurousness: Double = RoonClient.defaultAdventurousness,
        seedMatchKeys: [String] = []
    ) -> RadioConfig? {
        var config = RadioConfig(name: name, adventurousness: adventurousness)

        // `RadioCategory` already owns the id-prefix vocabulary; parsing it a
        // second time here is how two mappings drift apart.
        if let category = RoonClient.RadioCategory(radioID: radioID) {
            let value = String(radioID.dropFirst(category.idPrefix.count))
            // "genre:" with nothing after it is not a genre. Without this an
            // empty facet passes `hasFacets` and yields a station that resolves
            // to nothing — caught by `testUnknownOrMalformedIdsAreRefused`.
            let facetless: Set<RoonClient.RadioCategory> = [.sonic, .recent]
            guard !value.isEmpty || facetless.contains(category) else { return nil }
            switch category {
            case .artist:
                // The id lowercases the artist; the display name is what the
                // seed resolver matches on.
                config.artists = [name]
            case .genre:    config.genres = [value.lowercased()]
            case .mood:     config.moods = [value.lowercased()]
            case .activity: config.activities = [value.lowercased()]
            case .decade:
                guard let year = Int(value) else { return nil }
                config.decades = [year]
            case .sonic, .recent:
                // An embedding neighbourhood and a recency slice have no facet
                // that names them — their seeds ARE the definition.
                config.trackKeys = seedMatchKeys
            }
        } else if radioID.contains(":") {
            // "album:", "track:" and friends: no facet either, same treatment.
            config.trackKeys = seedMatchKeys
        } else {
            return nil
        }

        return config.hasFacets ? config : nil
    }
}
