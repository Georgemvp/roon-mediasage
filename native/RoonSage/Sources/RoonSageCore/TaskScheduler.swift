import Foundation

/// One place where the server's recurring work lives.
///
/// Before this, every periodic job was its own retained
/// `Task { while true { sleep; work } }` — a dozen of them across RoonClient and
/// its extensions. That shape has three problems the scheduler fixes:
///
///  1. **A restart forgot everything.** Each loop began with a startup grace
///     (60–90 s) and then ran immediately, so a server that restarted twice in an
///     evening ran its daily jobs twice. `lastExecution` is persisted, so the
///     cadence resumes instead of restarting.
///  2. **Nothing could report on them.** There was no way to ask "when did the
///     feature sync last succeed" other than grepping the log. Every run now
///     records duration, status and error (`scheduled_tasks`), which is what
///     `/system/tasks` and the health checks read.
///  3. **No dedupe.** A manual trigger could run alongside the scheduled one.
///     `runNow` returns false when the job is already in flight, which is how the
///     share server answers 409 instead of starting a second pipeline.
///
/// Deliberately NOT a general job queue: it schedules recurring work with a known
/// cadence. The Roon connect loop stays a hand-written state machine — its waits
/// depend on connection state (3/5/6 s) and it carries local retry counters, so
/// folding it in here would be a rewrite with real behaviour risk and no gain.
public actor TaskScheduler {

    public enum Status: String, Codable, Sendable {
        /// Registered, never executed yet.
        case never
        /// The last run finished normally.
        case completed
        /// The last run threw or reported failure; `lastError` says why.
        case failed
        /// The job ran but decided there was nothing to do (not due, disabled).
        case skipped
    }

    /// What a job reports back. `nextInterval` lets a job steer its own cadence —
    /// the feature sync idles 6 h once settled but retries every 5 min while the
    /// analyzer is still warming up, and the discovery run retries in 30 min when
    /// it produced nothing. Returning nil keeps the registered interval.
    public struct Outcome: Sendable {
        public var status: Status
        public var nextInterval: TimeInterval?
        public var error: String?

        public init(status: Status = .completed, nextInterval: TimeInterval? = nil, error: String? = nil) {
            self.status = status
            self.nextInterval = nextInterval
            self.error = error
        }

        public static let completed = Outcome(status: .completed)
        public static let skipped = Outcome(status: .skipped)
        public static func retry(after seconds: TimeInterval) -> Outcome {
            Outcome(status: .completed, nextInterval: seconds)
        }
        public static func failed(_ message: String, retryAfter: TimeInterval? = nil) -> Outcome {
            Outcome(status: .failed, nextInterval: retryAfter, error: message)
        }
    }

    /// The view `/system/tasks` serves and the UI renders.
    public struct TaskInfo: Codable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let title: String
        public let intervalSeconds: TimeInterval
        public let lastExecution: Date?
        public let lastDurationSeconds: Double?
        public let lastStatus: String
        public let lastError: String?
        public let nextExecution: Date?
        public let isRunning: Bool
        public let runCount: Int
        public let failureCount: Int
    }

    private struct Job {
        let name: String
        let title: String
        let initialDelay: TimeInterval
        /// Fixed anchor for the startup grace — see `nextDue`.
        let registeredAt: Date
        let body: @Sendable () async -> Outcome
        var interval: TimeInterval
        var lastExecution: Date?
        var lastDuration: Double?
        var lastStatus: Status
        var lastError: String?
        var runCount: Int
        var failureCount: Int
        var driver: Task<Void, Never>?
    }

    public static let shared = TaskScheduler()

    private var jobs: [String: Job] = [:]
    private var running: Set<String> = []
    private var database: DatabaseManager?

    /// A single sleep is capped at an hour so a long-cadence job re-evaluates
    /// regularly. `Task.sleep` does not advance while the machine is asleep, and
    /// the mini sleeps its display but not its disks — a 24 h sleep would drift
    /// arbitrarily far. Re-checking hourly against a persisted timestamp does not.
    static let maxSleep: TimeInterval = 3600

    public init() {}

    /// Give the scheduler its store. Registrations made before this still work;
    /// they just have no persisted history to resume from.
    public func attach(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Registration

    /// Register (and start) a recurring job. Re-registering a live name is a
    /// no-op, so the existing `guard xTask == nil` double-start guards keep their
    /// meaning at the call sites.
    ///
    /// - Parameters:
    ///   - initialDelay: startup grace before the FIRST run of a job that has
    ///     never run. A job with persisted history waits out the remainder of its
    ///     interval instead, whichever is later.
    public func register(name: String,
                         title: String,
                         interval: TimeInterval,
                         initialDelay: TimeInterval = 0,
                         body: @escaping @Sendable () async -> Outcome) {
        guard jobs[name] == nil else { return }
        var job = Job(name: name, title: title, initialDelay: initialDelay,
                      registeredAt: Date(), body: body,
                      interval: interval, lastExecution: nil, lastDuration: nil,
                      lastStatus: .never, lastError: nil, runCount: 0, failureCount: 0,
                      driver: nil)
        jobs[name] = job

        job.driver = Task { [weak self] in await self?.drive(name) }
        jobs[name]?.driver = job.driver
    }

    public func isRegistered(_ name: String) -> Bool { jobs[name] != nil }

    /// Stop and forget a job. Mirrors the old `stopX()` functions, which cancelled
    /// the retained Task. Note this cancels the *driver*: a body already in flight
    /// runs to completion, where the old code could tear it down mid-call. Every
    /// converted body re-checks its own enabled-flag first, so a job stopped by a
    /// user toggle no-ops on that last run rather than doing unwanted work.
    public func unregister(_ name: String) {
        jobs[name]?.driver?.cancel()
        jobs[name] = nil
    }

    public func isRunning(_ name: String) -> Bool { running.contains(name) }

    /// Stop every driver. Used on shutdown and by tests.
    public func stopAll() {
        for (name, job) in jobs {
            job.driver?.cancel()
            jobs[name]?.driver = nil
        }
        jobs.removeAll()
        running.removeAll()
    }

    // MARK: - Running

    /// Trigger a job now, out of band. Returns false when it is already in
    /// flight — that is the dedupe the share server turns into a 409, and it is
    /// why a client hammering "ververs" cannot stack pipelines.
    @discardableResult
    public func runNow(_ name: String) -> Bool {
        guard jobs[name] != nil, !running.contains(name) else { return false }
        Task { [weak self] in await self?.execute(name) }
        return true
    }

    /// The per-job driver: wait until due, re-check, run, repeat.
    private func drive(_ name: String) async {
        // Resume the cadence rather than restarting it: a job that ran 20 minutes
        // ago with an hourly interval waits 40 minutes, not the full hour, and
        // certainly not "grace period, then immediately".
        await loadPersistedState(name)

        while !Task.isCancelled {
            guard let due = nextDue(name) else { return }        // job was removed
            let wait = max(0, due.timeIntervalSinceNow)
            let slice = min(wait, Self.maxSleep)
            if slice > 0 {
                try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            }
            if Task.isCancelled { return }
            // Re-check after waking: a manual `runNow` during the sleep moves the
            // due date out, and a capped sleep only covered part of the wait.
            guard let stillDue = nextDue(name), stillDue <= Date() else { continue }
            await execute(name)
        }
    }

    /// When the named job should next run: its last execution plus its current
    /// interval, or now plus the startup grace when it has never run.
    private func nextDue(_ name: String) -> Date? {
        guard let job = jobs[name] else { return nil }
        guard let last = job.lastExecution else {
            // Anchored to REGISTRATION, not to now. Computing `Date() + delay` here
            // moved the target every time the driver re-checked it, so a job that
            // had never run could never become due — it slept, woke, asked again,
            // got a fresh future date, and slept again, forever. Only jobs with a
            // persisted lastExecution ever fired.
            return job.registeredAt.addingTimeInterval(job.initialDelay)
        }
        return max(last.addingTimeInterval(job.interval),
                   Date().addingTimeInterval(-Self.maxSleep))   // never queue far in the past
    }

    private func loadPersistedState(_ name: String) async {
        guard let database, jobs[name] != nil else { return }
        // `try?` on a `T?`-returning throwing call already flattens to one
        // optional, so this single binding covers both "threw" and "no row".
        guard let rec = try? await database.scheduledTask(named: name) else { return }
        jobs[name]?.lastExecution = rec.lastExecution
        jobs[name]?.lastDuration = rec.lastDuration
        jobs[name]?.lastStatus = rec.lastStatus.flatMap(Status.init(rawValue:)) ?? .never
        jobs[name]?.lastError = rec.lastError
        jobs[name]?.runCount = rec.runCount
        jobs[name]?.failureCount = rec.failureCount
    }

    private func execute(_ name: String) async {
        guard let job = jobs[name], !running.contains(name) else { return }
        running.insert(name)
        let started = Date()
        let outcome = await job.body()
        let finished = Date()
        let duration = finished.timeIntervalSince(started)
        running.remove(name)

        // The job may have been unregistered while it ran.
        guard jobs[name] != nil else { return }
        jobs[name]?.lastExecution = finished
        jobs[name]?.lastDuration = duration
        jobs[name]?.lastStatus = outcome.status
        jobs[name]?.lastError = outcome.error
        jobs[name]?.runCount += 1
        if outcome.status == .failed { jobs[name]?.failureCount += 1 }
        if let next = outcome.nextInterval, next > 0 { jobs[name]?.interval = next }

        if let error = outcome.error {
            Log.warning("taak ‘\(name)’ mislukt na \(String(format: "%.1f", duration))s: \(error)", category: .app)
        } else {
            Log.debug("taak ‘\(name)’ \(outcome.status.rawValue) in \(String(format: "%.1f", duration))s", category: .app)
        }

        if let database {
            try? await database.recordTaskRun(name: name, finishedAt: finished, duration: duration,
                                              status: outcome.status.rawValue, error: outcome.error)
        }
    }

    // MARK: - Reporting

    public func info() -> [TaskInfo] {
        jobs.values.map { job in
            TaskInfo(name: job.name,
                     title: job.title,
                     intervalSeconds: job.interval,
                     lastExecution: job.lastExecution,
                     lastDurationSeconds: job.lastDuration,
                     lastStatus: job.lastStatus.rawValue,
                     lastError: job.lastError,
                     // A job that has never run still has a knowable first run:
                     // its registration plus the startup grace. Reporting nil there
                     // made "never" look indistinguishable from "never will".
                     nextExecution: job.lastExecution?.addingTimeInterval(job.interval)
                        ?? job.registeredAt.addingTimeInterval(job.initialDelay),
                     isRunning: running.contains(job.name),
                     runCount: job.runCount,
                     failureCount: job.failureCount)
        }
        .sorted { $0.name < $1.name }
    }
}
