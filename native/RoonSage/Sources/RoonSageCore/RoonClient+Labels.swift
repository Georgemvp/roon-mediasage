import Foundation

/// Thin-client accessors for the record-label browse dimension. Labels are seeded
/// from the locally-synced `track_audio_features.label` column, so this works the
/// same on the server and on a thin client (both hold the features after a sync).
@MainActor
extension RoonClient {
    public func labels(sortedBy sort: LabelSort = .albumCount) async -> [DatabaseManager.LabelRow] {
        guard let db = database else { return [] }
        return await LabelStore(database: db).labels(sortedBy: sort)
    }

    public func albumsForLabel(_ id: Int64) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return await LabelStore(database: db).albums(forLabel: id)
    }

    public func labelOfTheWeek(on date: Date = Date()) async -> DatabaseManager.LabelRow? {
        guard let db = database else { return nil }
        return await LabelStore(database: db).labelOfTheWeek(for: date)
    }

    public func mergeLabels(from: Int64, into: Int64) async {
        guard let db = database else { return }
        await LabelStore(database: db).mergeLabels(from: from, into: into)
    }

    public func undoLabelMerge(from: Int64) async {
        guard let db = database else { return }
        await LabelStore(database: db).undoMerge(from: from)
    }

    /// Seed the label tables from the dataset column on first open (no-op if
    /// already populated). Returns the current label count.
    @discardableResult
    public func ensureLabelsBuilt() async -> Int {
        guard let db = database else { return 0 }
        let store = LabelStore(database: db)
        let existing = await store.labels()
        if !existing.isEmpty { return existing.count }
        return await store.rebuild()
    }

    /// Force a re-seed (e.g. after a fresh feature sync brought new labels in).
    @discardableResult
    public func rebuildLabels() async -> Int {
        guard let db = database else { return 0 }
        return await LabelStore(database: db).rebuild()
    }
}
