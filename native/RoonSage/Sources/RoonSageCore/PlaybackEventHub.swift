import Foundation

/// Fan-out of playback state to connected clients over one long-lived stream,
/// replacing per-client polling.
///
/// Before this, every remote client asked `GET /playback` every 1.5 s
/// (`RoonClient+Remote.startRemotePolling`) and the server closed the connection
/// after each answer — so one phone cost 40 full snapshots and 40 TCP handshakes
/// a minute, whether or not anything had changed, and a second device doubled it.
///
/// The hub inverts that: **one** internal ticker per distinct zone, and clients
/// only receive bytes when the snapshot actually differs. Idle listening costs a
/// keepalive comment every 30 s instead of 2400 snapshots an hour.
///
/// Honest about what this is: the ticker still *polls* `RoonClient` internally,
/// because the Roon extension API gives no change callback we could subscribe to
/// (see `docs/guardrails/PROJECT.md#roon-api-constraints`). What it removes is the
/// per-client network cost, which is the part that was actually expensive — and
/// it removes it regardless of how many clients connect.
///
/// Subscribers get snapshot-then-deltas: the current state on connect, changes
/// afterwards. A client that reconnects is therefore never left staring at an
/// empty screen waiting for the next change.
public actor PlaybackEventHub {

    public static let shared = PlaybackEventHub()

    /// How often the ticker asks RoonClient for a fresh snapshot. Matches the old
    /// per-client poll cadence, so responsiveness is unchanged — the difference is
    /// that this runs once for everyone instead of once per client.
    static let tickInterval: TimeInterval = 1.5

    /// Idle streams get a comment line this often so proxies, NAT tables and
    /// ZeroTier don't silently drop a connection that looks dead.
    static let keepaliveInterval: TimeInterval = 30

    private struct Subscriber {
        let zoneKey: String                       // "" = no specific zone
        let write: @Sendable (Data) -> Void
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var ticker: Task<Void, Never>?
    /// Last body digest per zone, so we push changes rather than repeats.
    private var lastDigest: [String: String] = [:]
    private var lastKeepalive = Date.distantPast

    public init() {}

    public var subscriberCount: Int { subscribers.count }

    /// Register a stream. `write` receives fully-framed SSE bytes. Returns the id
    /// to pass to `unsubscribe` when the connection dies.
    public func subscribe(zone: String?, write: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        let key = zone ?? ""
        subscribers[id] = Subscriber(zoneKey: key, write: write)
        // Snapshot-then-deltas: hand the newcomer the current state immediately.
        // Also drop this zone's remembered digest so the next tick re-evaluates
        // from scratch rather than assuming the newcomer has seen it.
        lastDigest[key] = nil
        startTickerIfNeeded()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty {
            ticker?.cancel()
            ticker = nil
            lastDigest.removeAll()
        }
    }

    /// SSE frame: `event: <name>` + one `data:` line + a blank line.
    static func frame(event: String, data: Data) -> Data {
        var out = Data("event: \(event)\ndata: ".utf8)
        out.append(data)
        out.append(Data("\n\n".utf8))
        return out
    }

    static let keepaliveFrame = Data(": keepalive\n\n".utf8)

    private func startTickerIfNeeded() {
        guard ticker == nil, !subscribers.isEmpty else { return }
        ticker = Task { [weak self] in await self?.tick() }
    }

    private func tick() async {
        while !Task.isCancelled {
            let zones = Set(subscribers.values.map(\.zoneKey))
            if zones.isEmpty { ticker = nil; return }

            for key in zones {
                let data = await RoonClient.shared.snapshotData(forZone: key.isEmpty ? nil : key)
                let digest = HTTPPayload.etag(for: data)
                guard lastDigest[key] != digest else { continue }
                lastDigest[key] = digest
                let payload = Self.frame(event: "playback", data: data)
                for sub in subscribers.values where sub.zoneKey == key {
                    sub.write(payload)
                }
            }

            if Date().timeIntervalSince(lastKeepalive) >= Self.keepaliveInterval {
                lastKeepalive = Date()
                for sub in subscribers.values { sub.write(Self.keepaliveFrame) }
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
        }
    }
}
