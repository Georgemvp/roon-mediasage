import Foundation

#if os(macOS)
/// Wiring for the server build: register the health checks and schedule the
/// backup + housekeeping jobs. Client apps don't run these — they ask the
/// server-of-record over `/health/detail`.
@MainActor
extension RoonClient {

    public static let backupTaskName = "database-backup"
    public static let housekeepingTaskName = "housekeeping"

    public static let healthWatchTaskName = "health-watch"
    public static let librarySyncTaskName = "library-sync"

    /// Whether a scheduled library walk should start now. Pure, so the guards are
    /// testable: skipping while a manual sync runs, and waiting rather than
    /// failing when the Core isn't attached yet.
    enum ScheduledSyncDecision: Equatable { case run, skipBusy, waitForCore }

    /// `nonisolated`: it reads nothing, so it needn't inherit this extension's
    /// @MainActor — otherwise the tests can't call it off the main actor.
    nonisolated static func shouldRunScheduledSync(isSyncing: Bool, isConnected: Bool) -> ScheduledSyncDecision {
        if isSyncing { return .skipBusy }
        if !isConnected { return .waitForCore }
        return .run
    }

    /// Called from `startServerBackgroundWork`.
    func startMaintenance() {
        registerHealthChecks()

        // Periodic library walk. Until now `startSync()` only fired on an empty
        // library, a changed Core, NULL match_keys, or a manual button — so once
        // the library was populated it was never re-walked. The health check found
        // this server 39 days stale on 2026-08-08: everything added to Roon after
        // 30 June was missing from library.db, and therefore from discovery, DJ
        // and sonic.
        //
        // Weekly, not daily: a Browse walk is expensive and the Roon Browse API is
        // single-session (see PROJECT.md#roon-api-constraints), so it competes with
        // every other browse the server does. An interrupted walk resumes from
        // `sync_album_checkpoints`, and the whole thing is visible and triggerable
        // on /system/tasks.
        Task {
            await TaskScheduler.shared.register(
                name: Self.librarySyncTaskName,
                title: "Bibliotheek synchroniseren",
                interval: 7 * 24 * 60 * 60,
                // Well after launch: the startup rush already reads the library.
                initialDelay: 30 * 60
            ) { [weak self] in
                guard let self else { return .skipped }
                return await self.runScheduledLibrarySync()
            }
        }

        // Health only helps if someone finds out. This runs the checks on a slow
        // cadence and notifies when something is actually wrong; the service's own
        // repeat window keeps a persistent problem from becoming hourly spam.
        Task {
            await TaskScheduler.shared.register(
                name: Self.healthWatchTaskName,
                title: "Gezondheidscontrole",
                interval: 60 * 60,
                initialDelay: 5 * 60
            ) {
                let results = await HealthCheckService.shared.results(force: true)
                let bad = results.filter { $0.level == .error }
                guard !bad.isEmpty else { return .completed }
                let summary = bad.map { "\($0.title): \($0.message)" }.joined(separator: " · ")
                await NotificationService.shared.notify(.healthDegraded, message: summary)
                return .completed
            }
        }

        Task { [weak self] in
            await TaskScheduler.shared.register(
                name: Self.backupTaskName,
                title: "Databaseback-up",
                interval: 24 * 60 * 60,
                // After the launch rush, so the backup isn't competing with the
                // library sync for the same write lock.
                initialDelay: 10 * 60
            ) { [weak self] in
                guard let self, let db = await self.database else { return .skipped }
                do {
                    let file = try await db.runBackup(databaseURL: Self.databaseURL)
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                    Log.info("back-up geschreven: \(file.lastPathComponent) (\((size ?? 0) / 1_048_576) MB)", category: .db)
                    return .completed
                } catch {
                    return .failed("back-up mislukt: \(error.localizedDescription)")
                }
            }

            await TaskScheduler.shared.register(
                name: Self.housekeepingTaskName,
                title: "Opruimen",
                interval: 7 * 24 * 60 * 60,
                initialDelay: 30 * 60
            ) { [weak self] in
                guard let self, let db = await self.database else { return .skipped }
                do {
                    let r = try await db.runHousekeeping()
                    Log.info("opruiming: \(r.expiredEditorial) editorial, \(r.oldBatches) batches, \(r.oldBatchItems) items", category: .db)
                    return .completed
                } catch {
                    return .failed("opruimen mislukt: \(error.localizedDescription)")
                }
            }
        }
    }

    /// One scheduled library walk, awaited so the scheduler records a real
    /// duration and a real outcome instead of "started something".
    private func runScheduledLibrarySync() async -> TaskScheduler.Outcome {
        let connected: Bool
        if case .connected = connectionState { connected = true } else { connected = false }

        switch Self.shouldRunScheduledSync(isSyncing: isSyncing, isConnected: connected) {
        case .skipBusy:
            // A manual sync is already walking; a second one would fight it for
            // the single-session Browse API.
            return .skipped
        case .waitForCore:
            return .retry(after: 30 * 60)
        case .run:
            break
        }

        let before = trackCount
        startSync()
        await syncTask?.value
        let after = trackCount
        let delta = after - before
        Log.info("geplande bibliotheeksync klaar: \(after) tracks (\(delta >= 0 ? "+" : "")\(delta))", category: .sync)
        return .completed
    }

    private func registerHealthChecks() {
        Task { [weak self] in
            let service = HealthCheckService.shared

            await service.register(id: "roon", title: "Roon") { [weak self] in
                guard let self else { return HealthChecks.roonConnection(isConnected: false, coreName: nil) }
                let (connected, name) = await self.roonConnectionSummary()
                return HealthChecks.roonConnection(isConnected: connected, coreName: name)
            }

            // `databaseURL` is main-actor isolated; read it once here rather than
            // from inside the @Sendable check body.
            let dbURL = Self.databaseURL
            await service.register(id: "disk", title: "Schijfruimte") {
                let free = HealthChecks.freeBytes(at: dbURL) ?? Int64.max
                return HealthChecks.diskSpace(freeBytes: free)
            }

            await service.register(id: "sync", title: "Bibliotheeksync") { [weak self] in
                let raw = await self?.database.flatMap { try? $0.syncStateValue(forKey: "last_sync") } ?? nil
                return HealthChecks.syncAge(lastSync: raw.flatMap(DatabaseManager.isoFormatter.date(from:)))
            }

            await service.register(id: "features", title: "Audiokenmerken") { [weak self] in
                guard let db = await self?.database else {
                    return HealthChecks.featureCoverage(features: 0, tracks: 0)
                }
                let features = (try? await db.audioFeatureCount()) ?? 0
                let tracks = (try? await db.trackCount()) ?? 0
                return HealthChecks.featureCoverage(features: features, tracks: tracks)
            }

            await service.register(id: "tasks", title: "Geplande taken") { [weak self] in
                // `flatMap` takes a synchronous closure, so the await is hoisted.
                guard let db = await self?.database else {
                    return HealthChecks.scheduledTasks([])
                }
                let tasks = (try? await db.allScheduledTasks()) ?? []
                return HealthChecks.scheduledTasks(tasks)
            }

            await service.register(id: "devices", title: "Apparaten") {
                HealthChecks.pendingDevices(count: LibraryShareServer.pendingDevices().count)
            }

            await service.register(id: "discovery", title: "Ontdekkingen") { [weak self] in
                guard let db = await self?.database else {
                    return HealthChecks.discoveryHealth(lastBatchDegraded: nil)
                }
                let degraded = (try? await db.lastBatchDegraded()) ?? nil
                return HealthChecks.discoveryHealth(lastBatchDegraded: degraded)
            }
        }
    }

    /// Connection state flattened for the health check.
    nonisolated func roonConnectionSummary() async -> (Bool, String?) {
        await MainActor.run {
            if case let .connected(coreName) = self.connectionState { return (true, coreName) }
            return (false, nil)
        }
    }
}
#endif
