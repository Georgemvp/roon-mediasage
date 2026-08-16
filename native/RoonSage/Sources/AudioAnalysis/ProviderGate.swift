import Foundation

/// Central outgoing rate-limiting and provider degradation tracking (S5).
/// Shared across AnalyzerCore (MusicBrainz, Deezer) and RoonSageCore (Discogs, Qobuz, LRCLIB).
///
/// Semantics:
/// - Maintains a minimum interval between requests per provider (token-bucket / slot reservation)
///   to respect published API limits.
/// - Tracks consecutive failures per provider (429, 503, connection refused/timeouts).
/// - When consecutive failures reach `failureThreshold`, the provider enters a cooldown
///   period (`disabled_until`) with exponential backoff.
/// - A successful request clears the consecutive failures and resets backoff.
public actor ProviderGate {
    public static let shared = ProviderGate()

    public struct ProviderConfig: Sendable {
        public var minInterval: TimeInterval
        public var failureThreshold: Int
        public var initialCooldown: TimeInterval
        public var maxCooldown: TimeInterval

        public init(minInterval: TimeInterval,
                    failureThreshold: Int = 3,
                    initialCooldown: TimeInterval = 10,
                    maxCooldown: TimeInterval = 300) {
            self.minInterval = max(0, minInterval)
            self.failureThreshold = max(1, failureThreshold)
            self.initialCooldown = max(1, initialCooldown)
            self.maxCooldown = max(initialCooldown, maxCooldown)
        }
    }

    public struct ProviderStatus: Sendable, Equatable {
        public var provider: String
        public var consecutiveFailures: Int
        public var disabledUntil: Date?
        public var lastError: String?
        public var isAvailable: Bool

        public init(provider: String,
                    consecutiveFailures: Int = 0,
                    disabledUntil: Date? = nil,
                    lastError: String? = nil,
                    isAvailable: Bool = true) {
            self.provider = provider
            self.consecutiveFailures = consecutiveFailures
            self.disabledUntil = disabledUntil
            self.lastError = lastError
            self.isAvailable = isAvailable
        }
    }

    private struct State {
        var nextSlot: Date = .distantPast
        var consecutiveFailures: Int = 0
        var disabledUntil: Date?
        var lastError: String?
    }

    private var configs: [String: ProviderConfig] = [
        "musicbrainz": ProviderConfig(minInterval: 1.0, failureThreshold: 3, initialCooldown: 15, maxCooldown: 300),
        "deezer": ProviderConfig(minInterval: 0.17, failureThreshold: 5, initialCooldown: 5, maxCooldown: 120),
        "discogs": ProviderConfig(minInterval: 1.0, failureThreshold: 3, initialCooldown: 15, maxCooldown: 300),
        "qobuz": ProviderConfig(minInterval: 0.20, failureThreshold: 4, initialCooldown: 10, maxCooldown: 180),
        "lrclib": ProviderConfig(minInterval: 0.25, failureThreshold: 4, initialCooldown: 10, maxCooldown: 180),
    ]

    private var states: [String: State] = [:]

    public init() {}

    public func configure(provider: String, config: ProviderConfig) {
        configs[provider.lowercased()] = config
    }

    /// Block until a slot is available for this provider.
    /// Returns true if execution may proceed, false if the provider is currently disabled due to failures.
    @discardableResult
    public func awaitSlot(for provider: String, now: Date = Date()) async -> Bool {
        let key = provider.lowercased()
        let config = configs[key] ?? ProviderConfig(minInterval: 0.5)
        var state = states[key] ?? State()

        if let until = state.disabledUntil {
            if now < until {
                return false
            }
            state.disabledUntil = nil
            states[key] = state
        }

        let slot = max(now, state.nextSlot)
        state.nextSlot = slot.addingTimeInterval(config.minInterval)
        states[key] = state

        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        return true
    }

    public func recordSuccess(for provider: String) {
        let key = provider.lowercased()
        var state = states[key] ?? State()
        state.consecutiveFailures = 0
        state.disabledUntil = nil
        state.lastError = nil
        states[key] = state
    }

    public func recordFailure(for provider: String, error: String? = nil, now: Date = Date()) {
        let key = provider.lowercased()
        let config = configs[key] ?? ProviderConfig(minInterval: 0.5)
        var state = states[key] ?? State()
        state.consecutiveFailures += 1
        state.lastError = error

        if state.consecutiveFailures >= config.failureThreshold {
            let exponent = Double(state.consecutiveFailures - config.failureThreshold)
            let cooldown = min(config.maxCooldown, config.initialCooldown * pow(2.0, exponent))
            state.disabledUntil = now.addingTimeInterval(cooldown)
        }
        states[key] = state
    }

    public func status(for provider: String, now: Date = Date()) -> ProviderStatus {
        let key = provider.lowercased()
        let state = states[key] ?? State()
        let isAvail: Bool
        if let until = state.disabledUntil {
            isAvail = now >= until
        } else {
            isAvail = true
        }
        return ProviderStatus(
            provider: key,
            consecutiveFailures: state.consecutiveFailures,
            disabledUntil: state.disabledUntil,
            lastError: state.lastError,
            isAvailable: isAvail
        )
    }

    public func reset(for provider: String? = nil) {
        if let provider {
            states.removeValue(forKey: provider.lowercased())
        } else {
            states.removeAll()
        }
    }
}
