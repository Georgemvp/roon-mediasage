import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Scheduled-task bookkeeping (see TaskScheduler)
    //
    // One row per registered job. The only thing that MUST survive a restart is
    // `last_execution`: without it every startup grace period fires again and the
    // server re-runs a daily job because it forgot it ran an hour ago. The rest
    // (status, duration, counters) exists so /system/tasks and the health checks
    // can say something truthful about a job instead of "it is scheduled".

    /// Persisted state of one scheduled job.
    public struct ScheduledTaskRecord: Codable, Sendable, Equatable {
        public var name: String
        public var lastExecution: Date?
        public var lastDuration: Double?
        public var lastStatus: String?
        public var lastError: String?
        public var runCount: Int
        public var failureCount: Int

        public init(name: String, lastExecution: Date? = nil, lastDuration: Double? = nil,
                    lastStatus: String? = nil, lastError: String? = nil,
                    runCount: Int = 0, failureCount: Int = 0) {
            self.name = name
            self.lastExecution = lastExecution
            self.lastDuration = lastDuration
            self.lastStatus = lastStatus
            self.lastError = lastError
            self.runCount = runCount
            self.failureCount = failureCount
        }
    }

    private static func taskRecord(from row: Row) -> ScheduledTaskRecord {
        ScheduledTaskRecord(
            name: row["name"],
            lastExecution: (row["last_execution"] as String?).flatMap { isoFormatter.date(from: $0) },
            lastDuration: row["last_duration"],
            lastStatus: row["last_status"],
            lastError: row["last_error"],
            runCount: row["run_count"] ?? 0,
            failureCount: row["failure_count"] ?? 0)
    }

    public func scheduledTask(named name: String) async throws -> ScheduledTaskRecord? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM scheduled_tasks WHERE name = ?", arguments: [name])
                .map(Self.taskRecord(from:))
        }
    }

    public func allScheduledTasks() async throws -> [ScheduledTaskRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM scheduled_tasks ORDER BY name")
                .map(Self.taskRecord(from:))
        }
    }

    /// Record the outcome of one run. Counters are incremented in SQL rather than
    /// read-modify-written, so two jobs finishing at once can't lose a count.
    public func recordTaskRun(name: String, finishedAt: Date, duration: Double,
                              status: String, error: String?) async throws {
        let iso = Self.isoFormatter.string(from: finishedAt)
        let failed = (error != nil) ? 1 : 0
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO scheduled_tasks (name, last_execution, last_duration, last_status,
                                             last_error, run_count, failure_count)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(name) DO UPDATE SET
                    last_execution = excluded.last_execution,
                    last_duration  = excluded.last_duration,
                    last_status    = excluded.last_status,
                    last_error     = excluded.last_error,
                    run_count      = scheduled_tasks.run_count + 1,
                    failure_count  = scheduled_tasks.failure_count + ?
                """, arguments: [name, iso, duration, status, error, failed, failed])
        }
    }
}
