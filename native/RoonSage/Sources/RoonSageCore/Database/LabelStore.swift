import Foundation

public enum LabelSort: Sendable {
    case name
    case albumCount
}

/// Record label as a browse dimension over the local library. Thin orchestration
/// on top of the DatabaseManager label queries (backfill, listing, merge/undo),
/// plus a deterministic "label of the week". Distinct from sonic discovery — this
/// is catalogue navigation. Enrichment (file-tags, MusicBrainz, Discogs, logos)
/// lands in the same tables in a follow-up.
public struct LabelStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func labels(sortedBy sort: LabelSort = .albumCount) async -> [DatabaseManager.LabelRow] {
        await database.labelList(sortedBy: sort)
    }

    public func albums(forLabel id: Int64) async -> [DatabaseManager.AlbumResult] {
        await database.albumsForLabel(id)
    }

    public func mergeLabels(from: Int64, into: Int64) async { await database.mergeLabels(from: from, into: into) }

    public func undoMerge(from: Int64) async { await database.undoLabelMerge(from: from) }

    @discardableResult
    public func rebuild() async -> Int { await database.rebuildLabelsFromFeatures() }

    /// Deterministic label-of-the-week: the same ISO week always yields the same
    /// label (drawn from the biggest catalogues), the next week a different one.
    public func labelOfTheWeek(for date: Date) async -> DatabaseManager.LabelRow? {
        let all = await database.labelList(sortedBy: .albumCount)
        guard !all.isEmpty else { return nil }
        let pool = Array(all.prefix(30))
        return pool[LabelStore.weekIndex(for: date, count: pool.count)]
    }

    /// Pure, TZ-stable index for a given ISO week. Seed = weekOfYear + ISO
    /// year-for-week (correct across the New-Year boundary).
    static func weekIndex(for date: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        let seed = week &+ year
        return ((seed % count) + count) % count
    }
}
