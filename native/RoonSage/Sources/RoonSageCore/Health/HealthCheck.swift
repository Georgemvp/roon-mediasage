import Foundation

/// What the server can say about its own condition.
///
/// `/health` only ever answered `{status:"ok", tracks:n}`, which is true right up
/// until it isn't: a Roon core that went away, an expired Qobuz session, a disk
/// with no room for `library.db`, a feature match-rate that collapsed after a
/// resync — all of those showed up as an empty list in the UI and nothing else.
/// Lidarr's answer is a registry of small independent checks whose results the UI
/// surfaces; this is the same shape, rebuilt.
///
/// The decision in every check is a pure function over already-gathered values
/// (see `HealthChecks`), so the thresholds are unit-testable without a Roon
/// session, a network or the Keychain.
public struct HealthResult: Codable, Sendable, Identifiable, Equatable {
    public enum Level: String, Codable, Sendable, Comparable {
        case ok, warning, error

        private var rank: Int {
            switch self {
            case .ok: return 0
            case .warning: return 1
            case .error: return 2
            }
        }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public var id: String { checkID }
    public let checkID: String
    public let title: String
    public let level: Level
    public let message: String
    /// What the user can actually do about it. nil when there is nothing to do.
    public let hint: String?

    public init(checkID: String, title: String, level: Level, message: String, hint: String? = nil) {
        self.checkID = checkID
        self.title = title
        self.level = level
        self.message = message
        self.hint = hint
    }
}

/// Registry + runner. Results are cached briefly so a UI that polls, and the
/// health endpoint, don't re-probe the network on every call.
public actor HealthCheckService {

    public static let shared = HealthCheckService()

    /// How long a result stays fresh. Long enough that a screen refresh is free,
    /// short enough that a fixed problem clears quickly.
    static let cacheWindow: TimeInterval = 30

    private struct Check {
        let id: String
        let title: String
        let run: @Sendable () async -> HealthResult
    }

    private var checks: [String: Check] = [:]
    private var cached: [HealthResult] = []
    private var cachedAt = Date.distantPast

    public init() {}

    public func register(id: String, title: String,
                         run: @escaping @Sendable () async -> HealthResult) {
        checks[id] = Check(id: id, title: title, run: run)
        cachedAt = .distantPast          // a new check must not wait out the window
    }

    public func unregister(id: String) {
        checks[id] = nil
        cachedAt = .distantPast
    }

    public var registeredCount: Int { checks.count }

    /// Run every check (concurrently) unless a fresh result set is cached.
    public func results(force: Bool = false, now: Date = Date()) async -> [HealthResult] {
        if !force, now.timeIntervalSince(cachedAt) < Self.cacheWindow, !cached.isEmpty {
            return cached
        }
        let all = checks.values
        var out: [HealthResult] = []
        await withTaskGroup(of: HealthResult.self) { group in
            for check in all {
                group.addTask { await check.run() }
            }
            for await result in group { out.append(result) }
        }
        // Worst first: the thing that needs attention should not be buried.
        out.sort { ($0.level, $1.checkID) > ($1.level, $0.checkID) }
        cached = out
        cachedAt = now
        return out
    }

    /// The single worst level across all checks — what a menu-bar badge needs.
    public func worstLevel(now: Date = Date()) async -> HealthResult.Level {
        await results(now: now).map(\.level).max() ?? .ok
    }
}
