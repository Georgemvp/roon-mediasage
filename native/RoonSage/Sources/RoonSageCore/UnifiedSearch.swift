import Foundation

/// Relevance ranking for one search box across tracks, albums and artists
/// (readiness P7, and the same gap as `KOEL_AUDIT` K3 / `JELLYFIN_AUDIT` J6).
///
/// This exists because of a concrete defect, not for tidiness. `searchAlbums`
/// and `searchArtists` order by `artist, year, album` — **alphabetically**, not
/// by how well the row matches. That is harmless while the screen shows all 100
/// hits and you scroll, and actively wrong the moment a combined view shows the
/// top few per section: searching "Sultans" would show five albums that merely
/// contain the word somewhere, sorted A–Z, while the exact match sits at
/// position 40 and never appears.
///
/// So the fix is to over-fetch and re-rank here. Pure and `nonisolated` — no
/// database, no actor — so the ordering is testable without a library.
public enum UnifiedSearch {

    /// How well one field answers the query. Higher wins.
    ///
    /// The tiers are deliberately coarse. Fine-grained scoring (edit distance,
    /// TF-IDF) would reorder near-equal candidates in ways nobody can predict
    /// from the query they typed; a listener searching "dire" expects
    /// "Dire Straits" first because it *starts* with what they typed, and that
    /// is the whole of the intuition worth encoding.
    public enum Tier: Int, Sendable, Comparable {
        case none = 0
        /// The field merely contains the query somewhere ("Sultans of Swing"
        /// for a query of "wing").
        case contains = 1
        /// A word inside the field starts with the query ("Sultans of Swing"
        /// for "swi").
        case wordPrefix = 2
        /// The field itself starts with the query ("Dire Straits" for "dire").
        case prefix = 3
        /// The field is exactly the query.
        case exact = 4

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public static func tier(_ field: String?, matching query: String) -> Tier {
        guard let field, !field.isEmpty else { return .none }
        let f = field.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .none }
        if f == q { return .exact }
        if f.hasPrefix(q) { return .prefix }
        // Word boundaries, not just spaces: "Sultans of Swing (Live)" should
        // match "live", and hyphenated or bracketed titles are ordinary here.
        let words = f.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return .wordPrefix }
        if f.contains(q) { return .contains }
        return .none
    }

    /// The best tier across several fields — an album matches on its own title
    /// or on its artist, and the stronger of the two is what should rank it.
    public static func bestTier(_ fields: [String?], matching query: String) -> Tier {
        fields.reduce(Tier.none) { best, field in max(best, tier(field, matching: query)) }
    }

    /// Re-rank by relevance, keeping the source order as the tiebreak.
    ///
    /// The stable tiebreak matters: within one tier the caller's ordering is
    /// usually meaningful already (FTS rank for tracks, alphabetical for
    /// albums), and an unstable sort would shuffle equally-good hits on every
    /// keystroke — the list would visibly jitter while you type.
    ///
    /// Rows that match nothing are dropped: with an over-fetched candidate set
    /// they are the rows SQL returned for a reason we can't see, and showing
    /// them under "best matches" is worse than showing fewer results.
    public static func rank<T>(_ items: [T], query: String, limit: Int,
                               fields: (T) -> [String?]) -> [T] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(items.prefix(limit))
        }
        // Written out rather than chained: the fluent version made the type
        // checker give up ("unable to type-check this expression in reasonable
        // time"), and a generic closure-taking function is exactly where that
        // bites.
        var scored: [(offset: Int, item: T, tier: Tier)] = []
        scored.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let tier = bestTier(fields(item), matching: query)
            if tier > .none { scored.append((offset, item, tier)) }
        }
        scored.sort { a, b in
            a.tier == b.tier ? a.offset < b.offset : a.tier > b.tier
        }
        return scored.prefix(limit).map { $0.item }
    }

    /// How many candidates to pull per section before ranking.
    ///
    /// Over-fetching is the point: ranking can only reorder what SQL handed
    /// over, so asking for exactly the number we intend to show would re-create
    /// the alphabetical-cap bug this type exists to fix.
    public static let candidatePool = 120

    /// How many of each kind a combined result shows. Small on purpose — the
    /// combined view answers "which of these did you mean", and the per-kind
    /// screens are one tap away for the full list.
    public static let sectionLimit = 5
}
