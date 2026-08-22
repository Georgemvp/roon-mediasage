import Foundation

/// Bookkeeping for the Roon websocket reconnect loop — pure value type so the
/// timing rules are testable without a socket.
///
/// **Why the attempt counter does NOT reset on open.** It used to (`handleOpen`
/// set it to 0), which is right for an ordinary drop but catastrophic for a
/// *kick loop*: on 2026-08-22 two copies of the analyzer ran on the mini, both
/// registering as extension `com.roonsage.server`. A Roon Core keeps one
/// connection per extension id, so each registration kicked the other, and
/// because every open reset the backoff the pair reconnected every ~2 s —
/// 1.046 closes in a single hour. Each close wiped the zone list, so on every
/// client the zone kept disappearing. Resetting only after the link has proven
/// itself (`stableAfter`) turns that into a slowing 2 → 4 → 8 → 16 → 30 s
/// retry, which is survivable while the real cause is fixed.
struct ReconnectPolicy: Sendable {

    /// Backoff ladder; stays at the last value once exhausted.
    static let delaysSeconds: [UInt64] = [2, 4, 8, 16, 30]
    /// How long a connection must survive before it counts as healthy (and the
    /// ladder starts from the beginning again).
    static let stableAfter: TimeInterval = 60
    /// Window + count that make a link "flapping" — worth naming in the log,
    /// because the usual cause (a second instance) is invisible from inside.
    static let flapWindow: TimeInterval = 120
    static let flapThreshold = 5

    struct Outcome: Equatable {
        /// Seconds to wait before the next connect attempt.
        let delaySeconds: UInt64
        /// Closes seen inside `flapWindow`, this one included.
        let closesInWindow: Int
        var isFlapping: Bool { closesInWindow >= ReconnectPolicy.flapThreshold }
    }

    private(set) var attempt = 0
    private var closes: [Date] = []

    /// Record a dropped connection and decide how long to wait.
    /// - Parameters:
    ///   - openedAt: when this connection opened, or nil if it never did.
    ///   - now: injected so tests don't have to sleep.
    mutating func connectionClosed(openedAt: Date?, now: Date = Date()) -> Outcome {
        if let openedAt, now.timeIntervalSince(openedAt) >= Self.stableAfter {
            attempt = 0     // the link held long enough to trust it again
        }
        closes.append(now)
        closes.removeAll { now.timeIntervalSince($0) > Self.flapWindow }
        let delay = Self.delaysSeconds[min(attempt, Self.delaysSeconds.count - 1)]
        attempt += 1
        return Outcome(delaySeconds: delay, closesInWindow: closes.count)
    }

    /// A deliberate (re)connect from the user — foreground tap, "verbind
    /// opnieuw", a fresh host. Starts the ladder over.
    mutating func reset() {
        attempt = 0
        closes.removeAll()
    }
}
