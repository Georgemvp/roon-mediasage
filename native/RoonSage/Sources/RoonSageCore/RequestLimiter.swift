import Foundation

/// Per-client request budget for the share server.
///
/// `AuthThrottler` already stops someone guessing tokens, but a client holding a
/// *valid* token had no limit at all — and the expensive routes are wide open
/// work triggers: `POST /generate` starts a full LLM pipeline, `POST
/// /discovery/run` a pass that takes about two minutes, `GET /library`
/// serialises the whole library. One approved device stuck in a retry loop could
/// therefore flatten the mini, which also runs Docker, Plex, rclone and the *arr
/// stack.
///
/// Token bucket per (client, class): `rate` tokens trickle back per second up to
/// `capacity`, so ordinary bursts pass untouched and only sustained hammering is
/// refused. Refusal is a 429 with `Retry-After`, never a silent drop.
public actor RequestLimiter {

    public struct Budget: Sendable {
        /// Tokens restored per second.
        public let rate: Double
        /// Maximum tokens held — i.e. the largest burst allowed from cold.
        public let capacity: Double

        public init(rate: Double, capacity: Double) {
            self.rate = rate
            self.capacity = capacity
        }
    }

    /// Ordinary reads and small mutations. Generous: the apps legitimately fan out
    /// several calls when a screen opens.
    public static let defaultBudget = Budget(rate: 5, capacity: 60)

    /// Routes that kick off minutes of work or serialise the whole library.
    /// Deliberately tight — a human pressing "ververs" twice is fine, a loop isn't.
    public static let heavyBudget = Budget(rate: 1.0 / 30.0, capacity: 3)

    /// Which budget a path falls under. `/health` and `/events` are exempt:
    /// discovery must work before pairing, and the event stream is one long-lived
    /// connection rather than a stream of requests.
    public static func budget(forPath path: String) -> Budget? {
        if path.hasPrefix("/health") || path.hasPrefix("/events") { return nil }
        if path.hasPrefix("/generate") || path.hasPrefix("/discovery/run")
            || path.hasPrefix("/library") || path.hasPrefix("/discover-weekly/refresh") {
            return heavyBudget
        }
        return defaultBudget
    }

    /// Path → bucket class, so all heavy routes share one budget per client
    /// instead of each getting its own (three loops on three routes would
    /// otherwise still be three times the load).
    public static func bucketClass(forPath path: String) -> String {
        budget(forPath: path).map { $0.rate == heavyBudget.rate ? "heavy" : "default" } ?? "exempt"
    }

    private struct Bucket {
        var tokens: Double
        var updated: Date
    }

    /// Bounded like `AuthThrottler`: an attacker rotating tokens must not be able
    /// to grow this without limit.
    static let maxBuckets = 500

    private var buckets: [String: Bucket] = [:]

    public init() {}

    /// Spend one token. Returns nil when allowed, or the seconds to wait when the
    /// budget is exhausted.
    public func consume(client: String, path: String, now: Date = Date()) -> Double? {
        guard let budget = Self.budget(forPath: path) else { return nil }
        let key = "\(client)|\(Self.bucketClass(forPath: path))"

        var bucket = buckets[key] ?? Bucket(tokens: budget.capacity, updated: now)
        // Refill for the time elapsed, capped at capacity.
        let elapsed = max(0, now.timeIntervalSince(bucket.updated))
        bucket.tokens = min(budget.capacity, bucket.tokens + elapsed * budget.rate)
        bucket.updated = now

        if bucket.tokens < 1 {
            let wait = (1 - bucket.tokens) / budget.rate
            buckets[key] = bucket
            return max(1, wait.rounded(.up))
        }

        bucket.tokens -= 1
        if buckets[key] == nil, buckets.count >= Self.maxBuckets {
            // Evict the stalest entry rather than growing without bound.
            if let stalest = buckets.min(by: { $0.value.updated < $1.value.updated })?.key {
                buckets.removeValue(forKey: stalest)
            }
        }
        buckets[key] = bucket
        return nil
    }

    /// Test/diagnostics hook.
    public func bucketCount() -> Int { buckets.count }
}
