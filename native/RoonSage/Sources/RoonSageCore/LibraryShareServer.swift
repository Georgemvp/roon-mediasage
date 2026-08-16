import AudioAnalysis
import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Minimal HTTP server the client apps talk to. Exposes the synced library (so
/// the iPhone can import it instead of an hours-long Browse walk), the synced
/// settings, and — for the playback proxy — live playback state plus a command
/// endpoint so client apps control Roon through this server (only this process
/// registers a Roon extension).
///   GET  /library  → exportLibraryJSON()
///   GET  /history  → ListenSnapshot (taste-profile totals/top-artists/recent)
///   GET  /taste-analysis → TasteAnalysis (time/genre/decade + like/dislike summary)
///   GET  /settings → SyncableSettings
///   GET  /playback?zone=… → PlaybackSnapshot (live zones/now-playing/queue)
///   GET  /events?zone=… → text/event-stream: `playback`-events zodra de snapshot
///                         wijzigt, plus een keepalive-comment elke 30 s. Vervangt
///                         de poll van elke 1,5 s per client (zie PlaybackEventHub)
///   POST /command  → RemoteCommand (play/pause/volume/curate/…)
///   POST /track-feedback → TrackFeedback (like/dislike/clear a track)
///   GET  /feedback → [FeedbackEntry] (all like/dislike verdicts)
///   GET  /playlists → [PlaylistSummary] (all saved playlists)
///   POST /playlists → SavePlaylistRequest → {"id": n} (save a new playlist)
///   DELETE /playlists?id=n → delete a saved playlist
///   GET  /playlist-tracks?id=n → [TrackRecord] (stored tracks of a playlist)
///   GET  /radio-configs → [RadioConfig] (user-composed sonic radios)
///   POST /radio-configs → RadioConfig → {"id":"…"} (create OR update; upsert)
///   DELETE /radio-configs?id=… → delete a custom radio config
///   GET  /ai-radios → AIRadioManagement (auto radios + on/off selection state)
///   POST /ai-radio-selection → AIRadioSelectionRequest (toggle a radio / master / hide)
///   GET  /radio-hidden → [String] (radio ids hidden from the main Radio's screen)
///   GET  /artist-radios → [SonicRadioPlaylist] (last synced AI radios → Qobuz)
///   GET  /discover-weekly → DiscoverWeeklyPlaylist? (library-first weekly, or null)
///   POST /discover-weekly/refresh → rebuild this week now → DiscoverWeeklyPlaylist?
///   GET  /discovery/recommendations?kind=&limit= → [RecommendationItemDTO]
///   POST /discovery/accept | /discovery/play | /discovery/reject → DiscoveryActionRequest
///   POST /discovery/run    → kick a pipeline pass ({"ok":true})
///   GET  /discovery/run-status → DiscoveryRunStatus
///   GET  /system/tasks → [TaskScheduler.TaskInfo] (cadans + laatste uitkomst per job)
///   POST /system/tasks/{name}/run → trigger een job nu (409 als hij al draait)
private actor LibraryCacheStore {
    private var cache: (sig: String, data: Data)?

    func get(for sig: String) -> Data? {
        if let cache, cache.sig == sig { return cache.data }
        return nil
    }

    func set(sig: String, data: Data) {
        cache = (sig, data)
    }
}

public final class LibraryShareServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 5767   // 5766 is the analyzer

    /// Bonjour service type this server advertises on the LAN so clients can find
    /// it by name instead of a hard-coded IP — a browse resolves to our *current*
    /// address, so a changed DHCP lease no longer strands the clients.
    public static let bonjourType = "_roonsage._tcp"

    // MARK: - Access token
    //
    // The server exposes the full library AND the synced settings — which carry
    // secrets (API keys, Last.fm session, Qobuz password). Binding on all
    // interfaces with no auth would hand those to anyone on the network. Every
    // endpoint but /health requires a shared secret, sent in `tokenHeader` (kept
    // out of the URL so it never lands in access logs). Same-machine (loopback)
    // callers are exempt; see `route`.

    /// Header a client sends its shared secret in.
    public static let tokenHeader = "X-RoonSage-Token"

    /// Per-IP brute-force throttle (5 consecutive bad tokens → 3 s of 429s).
    static let authThrottler = AuthThrottler()

    /// Per-client request budget for callers that DO hold a valid token — the
    /// throttle above only covers guessing. See `RequestLimiter`.
    static let requestLimiter = RequestLimiter()
    private static let tokenKey = "share_token"
    private static var cachedToken: String?

    /// The server's shared secret — generated once and persisted in the Keychain.
    /// Warmed in `start()` so request handling is a cache hit.
    public static func currentToken() -> String {
        if let c = cachedToken { return c }
        if let t = KeychainStore.load(key: tokenKey), !t.isEmpty { cachedToken = t; return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = .random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        KeychainStore.save(key: tokenKey, value: token)
        cachedToken = token
        return token
    }

    /// Token configured on this device — the server's generated one, or (on a
    /// client) the value the user pasted from the server. nil if unset.
    public static var configuredToken: String? { KeychainStore.load(key: tokenKey) }

    /// Set/clear the token on this device (client pairing UI).
    public static func setConfiguredToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.delete(key: tokenKey); cachedToken = nil }
        else { KeychainStore.save(key: tokenKey, value: t); cachedToken = t }
    }

    /// When false unauthenticated requests are still served but logged — a grace
    /// window so existing clients keep working until they're paired. A *wrong*
    /// token is always rejected.
    ///
    /// Defaults to **true**: a fresh install must not hand `/library` and
    /// `/history` (the full listening profile) to anyone on the network while the
    /// user has not paired a device yet. The pending-approval queue is the
    /// intended way in — an unknown client is queued, not stranded. Same
    /// `object(forKey:) as? Bool ?? default` shape as `library_share_enabled`
    /// (RoonClient.swift), because `bool(forKey:)` cannot express "unset".
    public static var enforceToken: Bool {
        get { UserDefaults.standard.object(forKey: "share_token_enforce") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "share_token_enforce") }
    }

    // MARK: - Device approval (zero-config pairing)
    //
    // Instead of copy-pasting the master token onto every client, each client
    // mints its OWN random token (see `ensureDeviceToken`) and sends it plus a
    // friendly name in `deviceHeader`. An unknown token isn't a dead-end 401 any
    // more: the server files it in a pending queue that the analyzer app shows,
    // where the user taps "Accepteer" to move it into the approved set. The
    // master token still validates (existing paired clients keep working).

    /// Header a client sends its human-readable device name in.
    public static let deviceHeader = "X-RoonSage-Device"

    /// A client token the user has approved on the server. Stores only the
    /// SHA-256 of the token: the server never needs the clear text (it only ever
    /// *compares*), so a leaked store yields nothing usable.
    public struct ApprovedDevice: Codable, Sendable, Identifiable {
        public var id: String { tokenHash }
        public let tokenHash: String
        public var name: String
        public var approvedAt: Date
    }

    /// A client that has knocked with an unknown token and is awaiting approval.
    public struct PendingDevice: Codable, Sendable, Identifiable {
        public var id: String { token }
        public let token: String
        public var name: String
        public var ip: String
        public var firstSeen: Date
        public var lastSeen: Date
    }

    private static let deviceLock = NSLock()
    private static var _pending: [String: PendingDevice] = [:]
    /// Keyed on token hash, never on the token itself.
    private static var _approvedCache: [String: ApprovedDevice]?
    private static let approvedKey = "approved_devices"

    /// Caller must hold `deviceLock`.
    ///
    /// Devices approved by an older build were stored with their clear-text
    /// token; those are hashed in place on first read — a one-way migration that
    /// runs at most once and keeps every already-paired client working.
    ///
    /// Deliberately still UserDefaults, not the Keychain: once only the hash is
    /// stored, a reader of the store learns nothing usable (authenticating needs
    /// the pre-image), while a Keychain read on this path — which
    /// `isApprovedDevice` hits per request — risks the blocking SecurityAgent ACL
    /// prompt documented in `KeychainStore`. The master token stays in the
    /// Keychain because it IS a usable credential.
    private static func loadApprovedLocked() -> [String: ApprovedDevice] {
        if let c = _approvedCache { return c }
        let raw = UserDefaults.standard.data(forKey: approvedKey)
        var map: [String: ApprovedDevice] = [:]
        if let raw, let arr = try? JSONDecoder().decode([ApprovedDevice].self, from: raw) {
            map = Dictionary(arr.map { ($0.tokenHash, $0) }, uniquingKeysWith: { a, _ in a })
            _approvedCache = map
            return map
        }
        if let raw, let legacy = try? JSONDecoder().decode([LegacyApprovedDevice].self, from: raw) {
            for d in legacy where !d.token.isEmpty {
                let hash = SecretsEnvelope.tokenHash(d.token)
                map[hash] = ApprovedDevice(tokenHash: hash, name: d.name, approvedAt: d.approvedAt)
            }
            persistApprovedLocked(map)          // rewrites the store hashed-only
            Log.info("share-server: \(map.count) goedgekeurde apparaten omgezet naar hash-opslag", category: .network)
            return map
        }
        _approvedCache = map
        return map
    }

    /// The pre-migration on-disk shape: clear-text token. Decoded only to migrate.
    private struct LegacyApprovedDevice: Codable {
        let token: String
        var name: String
        var approvedAt: Date
    }

    /// Caller must hold `deviceLock`.
    private static func persistApprovedLocked(_ map: [String: ApprovedDevice]) {
        _approvedCache = map
        if let data = try? JSONEncoder().encode(Array(map.values)) {
            UserDefaults.standard.set(data, forKey: approvedKey)
        }
    }

    /// True when `token` has been approved on this server. Compares hashes, so
    /// the clear-text token is never stored anywhere to compare against.
    public static func isApprovedDevice(_ token: String) -> Bool {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return loadApprovedLocked()[SecretsEnvelope.tokenHash(token)] != nil
    }

    /// True once at least one client has been paired. After the first approval the
    /// read grace window closes: every non-/health request then needs a valid
    /// token, so an un-paired peer can no longer read the library/history at all.
    public static func hasApprovedDevices() -> Bool {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return !loadApprovedLocked().isEmpty
    }

    /// Hard cap on the pending-approval queue so an attacker rotating tokens/IPs
    /// can't grow it without bound (memory + a flooded "Apparaten" list).
    private static let maxPending = 50

    /// File (or refresh) an unknown-token client in the pending queue.
    static func recordPending(token: String, name: String, ip: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        if loadApprovedLocked()[SecretsEnvelope.tokenHash(token)] != nil { return }
        let now = Date()
        let display = name.isEmpty ? "Onbekend apparaat" : name
        if var p = _pending[token] {
            p.lastSeen = now
            if !name.isEmpty { p.name = name }
            if !ip.isEmpty { p.ip = ip }
            _pending[token] = p
        } else {
            // Evict the stalest entry when full (like AuthThrottler.maxEntries) so
            // the queue can't be flooded past a bounded size.
            if _pending.count >= Self.maxPending,
               let stalest = _pending.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                _pending.removeValue(forKey: stalest)
            }
            _pending[token] = PendingDevice(token: token, name: display, ip: ip,
                                            firstSeen: now, lastSeen: now)
        }
    }

    /// Clients awaiting approval, oldest first.
    public static func pendingDevices() -> [PendingDevice] {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return _pending.values.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// Approved clients, oldest first.
    public static func approvedDevices() -> [ApprovedDevice] {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return loadApprovedLocked().values.sorted { $0.approvedAt < $1.approvedAt }
    }

    /// Move a pending device into the approved set. Its next poll (~1.5s) succeeds.
    /// Takes the clear-text token (the pending queue is in-memory only) and stores
    /// its hash.
    @discardableResult
    public static func approveDevice(token: String) -> Bool {
        deviceLock.lock(); defer { deviceLock.unlock() }
        guard let p = _pending[token] else { return false }
        let hash = SecretsEnvelope.tokenHash(token)
        var map = loadApprovedLocked()
        map[hash] = ApprovedDevice(tokenHash: hash, name: p.name, approvedAt: Date())
        persistApprovedLocked(map)
        _pending[token] = nil
        return true
    }

    /// Drop a device from the pending queue without approving it.
    public static func rejectDevice(token: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        _pending[token] = nil
    }

    /// Revoke a previously approved device (it drops back to 401 on its next
    /// poll). Keyed on the stored hash — the UI has the `ApprovedDevice`, not the
    /// token.
    public static func revokeDevice(tokenHash: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        var map = loadApprovedLocked()
        map[tokenHash] = nil
        persistApprovedLocked(map)
    }

    /// This device's token for talking to a server: the configured one (master on
    /// the server, or a previously-set value on a client), or a freshly minted
    /// random client token persisted for next time. Lets clients pair with zero
    /// manual token entry — they just show up as "pending" on the server.
    public static func ensureDeviceToken() -> String {
        if let t = configuredToken, !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = .random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        setConfiguredToken(token)
        return token
    }

    /// Friendly name this device advertises to the server for the approval list.
    public static var thisDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private let port: UInt16
    private let database: DatabaseManager
    private var listener: NWListener?

    // /library is rebuilt (tens of MB for a large library) on each request, and
    // clients re-pull it whenever the /playback libraryRevision shifts (its
    // featuresRevision part changes during analysis) — though library CONTENT only
    // changes on a sync. Cache it, keyed on `last_sync`, so those re-pulls don't
    private let libCache = LibraryCacheStore()

    public init(port: UInt16 = LibraryShareServer.defaultPort, database: DatabaseManager) {
        self.port = port
        self.database = database
    }

    public func start() throws {
        _ = Self.currentToken()   // warm the token cache before any request
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Advertise on the LAN so clients auto-discover us at our current IP even
        // after a DHCP address change (see BonjourDiscovery). Named after the
        // device so a user with several servers can tell them apart.
        listener.service = NWListener.Service(name: Self.thisDeviceName, type: Self.bonjourType)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global())
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        let loopback = Self.endpointIsLoopback(conn.endpoint)
        let peerIP = Self.endpointHost(conn.endpoint)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(conn, accumulated: Data(), loopback: loopback, peerIP: peerIP)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    /// Accumulate until the full request (headers + any POST body) has arrived,
    /// then route. POST bodies don't always land in the first read.
    private func receive(_ conn: NWConnection, accumulated: Data, loopback: Bool, peerIP: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            guard let headerEnd = Self.rangeOfHeaderEnd(buf) else {
                if isComplete { conn.cancel() } else { self.receive(conn, accumulated: buf, loopback: loopback, peerIP: peerIP) }
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = Self.contentLength(header)
            let bodyReceived = buf.count - (bodyStart - buf.startIndex)
            if bodyReceived < contentLength, !isComplete {
                self.receive(conn, accumulated: buf, loopback: loopback, peerIP: peerIP)
                return
            }
            // `contentLength` is clamped to [0, 32 MB] (see `contentLength`), so
            // this range can never invert — a negative/overflowing header value
            // used to trap here and crash the always-on extension process.
            let bodyEnd = min(bodyStart + contentLength, buf.endIndex)
            let body = buf.subdata(in: min(bodyStart, bodyEnd)..<bodyEnd)
            // Anything after this request's body is the start of the next one on a
            // kept-alive connection (HTTP pipelining, and the ordinary case where
            // two requests land in one read).
            let leftover = bodyEnd < buf.endIndex ? buf.subdata(in: bodyEnd..<buf.endIndex) : Data()

            // The event stream never produces a single body, so it cannot go
            // through `route`/`send`; it takes the connection over entirely.
            if Self.requestTarget(header).path.hasPrefix("/events") {
                self.startEventStream(conn, header: header, loopback: loopback, peerIP: peerIP)
                return
            }

            Task {
                let (status, respBody, ctype) = await self.route(header: header, body: body, loopback: loopback, peerIP: peerIP)
                self.send(conn, status: status, body: respBody, ctype: ctype,
                          requestHeader: header, leftover: leftover,
                          loopback: loopback, peerIP: peerIP)
            }
        }
    }

    /// Method + path + full target of a raw request header.
    static func requestTarget(_ header: String) -> (method: String, path: String, target: String) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? target
        return (method, path, target)
    }

    /// True when this request may reuse the connection: HTTP/1.1 defaults to
    /// persistent, and only an explicit `Connection: close` opts out. Every poll
    /// used to pay for a fresh TCP handshake — cheap on the LAN, not over ZeroTier.
    static func wantsKeepAlive(_ header: String) -> Bool {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        guard requestLine.contains("HTTP/1.1") else { return false }
        let connection = headerValue("Connection", in: header)?.lowercased() ?? ""
        return !connection.contains("close")
    }

    // MARK: - Server-sent events (GET /events)

    /// Hand this connection to `PlaybackEventHub` and keep it open. Auth is the
    /// same gate every other route uses; a rejection is written as a normal
    /// response and the connection closed.
    private func startEventStream(_ conn: NWConnection, header: String, loopback: Bool, peerIP: String) {
        let (method, path, target) = Self.requestTarget(header)
        if let denial = Self.authorize(method: method, path: path, header: header,
                                       loopback: loopback, peerIP: peerIP) {
            send(conn, status: denial.0, body: denial.1, ctype: denial.2, requestHeader: header)
            return
        }
        let zone = Self.queryValue("zone", in: target)

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        // No Content-Length: the body is open-ended. Keep the socket alive.
        head += "Connection: keep-alive\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        Task {
            let id = await PlaybackEventHub.shared.subscribe(zone: zone) { frame in
                conn.send(content: frame, completion: .contentProcessed { _ in })
            }
            // The connection's own state handler is what ends the subscription:
            // a phone that walks out of Wi-Fi never sends a goodbye.
            conn.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    Task { await PlaybackEventHub.shared.unsubscribe(id) }
                    conn.cancel()
                default: break
                }
            }
            Log.info("share-server: eventstream geopend voor \(peerIP)\(zone.map { " (zone \($0))" } ?? "")", category: .network)
        }
    }

    /// Paths whose body must never be stored anywhere, not even revalidated from
    /// a local copy — it carries credentials.
    private static func mustNotStore(_ requestHeader: String) -> Bool {
        let requestLine = requestHeader.split(separator: "\r\n").first.map(String.init) ?? ""
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return target.hasPrefix("/settings")
    }

    private func send(_ conn: NWConnection, status: String, body: Data, ctype: String,
                      requestHeader: String = "", leftover: Data = Data(),
                      loopback: Bool = false, peerIP: String = "") {
        var payload = body
        var status = status
        var extraHeaders = ""

        // Conditional GET. `/library` is tens of MB and clients re-pull it on every
        // libraryRevision shift — which moves during analysis while the library
        // CONTENT only changes on a sync. A matching validator turns that into an
        // empty 304. Only for successful bodies: a 401 or 500 must never be cached.
        let isCacheable = status.hasPrefix("200") && !Self.mustNotStore(requestHeader)
        var etag: String?
        if isCacheable, !payload.isEmpty {
            let tag = HTTPPayload.etag(for: payload)
            etag = tag
            if let inm = Self.headerValue("If-None-Match", in: requestHeader), inm == tag {
                status = "304 Not Modified"
                payload = Data()
            }
        }

        // gzip when the client advertised it and the body is worth compressing.
        // URLSession sends `Accept-Encoding: gzip` and decompresses transparently,
        // so this needs no client change.
        if status.hasPrefix("200"), !payload.isEmpty,
           HTTPPayload.clientAcceptsGzip(requestHeader),
           let zipped = HTTPPayload.gzip(payload) {
            payload = zipped
            extraHeaders += "Content-Encoding: gzip\r\n"
            extraHeaders += "Vary: Accept-Encoding\r\n"
        }

        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(ctype)\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        if let etag { header += "ETag: \(etag)\r\n" }
        // Everything here is either personal (library, history, taste) or
        // credential-bearing (/settings). `/settings` may not be stored at all;
        // the rest may be held locally but must be revalidated before use, which
        // is what makes the ETag above useful. `private` keeps both out of shared
        // caches. `nosniff` stops a JSON body being re-interpreted as something
        // executable if a browser ever points at this server.
        header += Self.mustNotStore(requestHeader)
            ? "Cache-Control: no-store\r\n"
            : "Cache-Control: private, no-cache\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        header += extraHeaders

        // Reuse the connection when the client speaks HTTP/1.1 and didn't ask to
        // close. Every response used to end in a teardown, so a client doing any
        // sequence of calls paid a TCP handshake each time — noticeable over
        // ZeroTier, where the round trip can be relayed.
        let keepAlive = Self.wantsKeepAlive(requestHeader)
        header += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"

        // A HEAD response carries the headers a GET would produce — including
        // Content-Length and ETag — but never a body. `route` doesn't distinguish
        // the method, so the body is dropped here, after the length is stamped.
        var out = Data(header.utf8)
        if Self.requestTarget(requestHeader).method != "HEAD" { out.append(payload) }
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard keepAlive, let self else {
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            // Carry any already-buffered next request straight into the next read.
            self.receive(conn, accumulated: leftover, loopback: loopback, peerIP: peerIP)
        })
    }

    /// The token gate, shared by `route` and the `/events` stream (which cannot go
    /// through `route` — it never returns a single body). Returns the response to
    /// send when the request must be rejected, or nil when it may proceed.
    static func authorize(method: String, path: String, header: String,
                          loopback: Bool, peerIP: String) -> (String, Data, String)? {
        // /settings carries secrets, and any state-changing request (POST
        // /command, /track-feedback, /playlists, /radio-configs, /discovery/run,
        // DELETE …) can drive Roon or mutate data. HEAD counts as a read: it is
        // GET without the body, so gating it while GET is open only made
        // `curl -I` return 401 on an otherwise-public route.
        let readOnly = method == "GET" || method == "HEAD"
        let sensitive = path.hasPrefix("/settings") || !readOnly

        // Everything but /health needs a valid token, unless the peer is loopback
        // or we're in the grace window. A token is valid when it matches the master
        // token OR the client has been approved in the analyzer's "Apparaten" list.
        // An unknown token isn't a dead-end: it's filed in the pending queue for
        // one-tap approval.
        //
        // The loopback exemption covers read-only GETs only. It used to cover
        // everything, which meant any process or user on the server machine could
        // read `/settings` (API keys, Last.fm session, Qobuz password) and drive
        // Roon without a token — and that machine also runs Docker, Plex, rclone
        // and the *arr stack. The client apps never target loopback anyway
        // (`startServerMode` drops a loopback base URL on purpose), so nothing
        // legitimate depended on it.
        // Exactly `/health`, not a prefix: `/health/detail` names task failures,
        // disk pressure and host addresses, so it must NOT inherit the open
        // discovery probe's exemption.
        guard path != "/health", !loopback || sensitive else { return nil }

        // Brute-force throttle: after 5 consecutive bad tokens an IP gets
        // 429s for a few seconds — no token comparison, no oracle.
        if authThrottler.isThrottled(peerIP) {
            Log.warning("share-server: throttled \(method) \(path) from \(peerIP) (too many bad tokens)", category: .network)
            return ("429 Too Many Requests", Data("too many attempts; retry later".utf8), "text/plain")
        }
        // Grace mode NEVER applies to a sensitive request. Read-only GETs keep the
        // grace window only until the first device is paired, after which
        // enforcement is automatic (hasApprovedDevices), so an un-paired peer can't
        // read PII. `enforceToken` defaults to true, so the window is opt-in rather
        // than the starting state.
        let enforcing = enforceToken || hasApprovedDevices()
        let provided = headerValue(tokenHeader, in: header)
        let deviceName = headerValue(deviceHeader, in: header) ?? ""
        if let provided {
            let valid = constantTimeEquals(provided, currentToken()) || isApprovedDevice(provided)
            if !valid {
                authThrottler.recordFailure(peerIP)
                recordPending(token: provided, name: deviceName, ip: peerIP)
                Log.warning("share-server: rejected \(method) \(path) — unapproved device ‘\(deviceName.isEmpty ? "?" : deviceName)’ (\(peerIP)); approve it under Apparaten", category: .network)
                return ("401 Unauthorized", Data("unauthorized; awaiting approval".utf8), "text/plain")
            }
            authThrottler.recordSuccess(peerIP)
        } else if enforcing || sensitive {
            let why = sensitive ? "secrets/mutation endpoint requires a token" : "pair this client via Apparaten"
            Log.warning("share-server: rejected \(method) \(path) — no token; \(why)", category: .network)
            return ("401 Unauthorized", Data("unauthorized".utf8), "text/plain")
        } else {
            Log.warning("share-server: serving \(method) \(path) WITHOUT a token (grace mode) — pair clients, then enable enforcement in Settings", category: .network)
        }
        return nil
    }

    private func route(header: String, body: Data, loopback: Bool, peerIP: String = "") async -> (String, Data, String) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? target

        // CSRF hardening: a POST (the only CORS-"simple" state-changing method —
        // GET is read-only, DELETE is always preflighted) must declare JSON. A
        // browser cross-origin fetch with application/json triggers a CORS preflight
        // this server never answers, so a malicious web page can't drive Roon or
        // mutate data even through the loopback auth-exemption. Legit native clients
        // already send application/json on every POST.
        if method == "POST" {
            let ctype = Self.headerValue("Content-Type", in: header)?.lowercased() ?? ""
            if !ctype.contains("application/json") {
                Log.warning("share-server: rejected POST \(path) — non-JSON Content-Type ‘\(ctype)’ (CSRF guard)", category: .network)
                return ("415 Unsupported Media Type", Data("json content-type required".utf8), "text/plain")
            }
        }

        if let denial = Self.authorize(method: method, path: path, header: header,
                                       loopback: loopback, peerIP: peerIP) {
            return denial
        }

        // Budget check, AFTER auth so an unauthorised caller can't spend an
        // approved client's tokens. Keyed on the client's own token (falling back
        // to its IP) so one misbehaving device can't starve the others.
        let client = Self.headerValue(Self.tokenHeader, in: header).map(SecretsEnvelope.tokenHash)
            ?? peerIP
        if let wait = await Self.requestLimiter.consume(client: client, path: path) {
            Log.warning("share-server: budget op voor \(method) \(path) (\(peerIP)) — \(Int(wait))s wachten", category: .network)
            return ("429 Too Many Requests",
                    Data("{\"error\":\"rate limited\",\"retryAfter\":\(Int(wait))}".utf8),
                    "application/json")
        }

        if method == "POST", path.hasPrefix("/command") {
            let ok = await RoonClient.shared.runRemoteCommandData(body)
            return ok ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                      : ("400 Bad Request", Data("bad command".utf8), "text/plain")
        }
        // Server-side AI playlist generation: runs the full pipeline on the
        // server-of-record and logs its trace centrally. Token-gated (non-GET).
        if method == "POST", path.hasPrefix("/generate") {
            return await RoonClient.shared.generatePlaylistData(body)
        }
        if method == "POST", path.hasPrefix("/track-feedback") {
            guard let fb = try? JSONDecoder().decode(TrackFeedback.self, from: body), !fb.matchKey.isEmpty else {
                return ("400 Bad Request", Data("bad feedback".utf8), "text/plain")
            }
            do {
                if let kind = fb.kind, !kind.isEmpty {
                    try await database.setFeedback(matchKey: fb.matchKey, title: fb.title, artist: fb.artist, kind: kind)
                } else {
                    try await database.clearFeedback(matchKey: fb.matchKey)
                }
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            } catch {
                return ("500 Internal Server Error", Data("feedback failed".utf8), "text/plain")
            }
        }
        if path.hasPrefix("/feedback") {
            if let entries = try? await database.allFeedback(),
               let body = try? JSONEncoder().encode(entries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("feedback failed".utf8), "text/plain")
        }
        // Favorites (starred albums/artists) — same server-of-record shape as
        // track feedback: POST one toggle, GET the whole set.
        if method == "POST", path.hasPrefix("/favorite") {
            guard let req = try? JSONDecoder().decode(FavoriteToggle.self, from: body),
                  !req.kind.isEmpty, !req.key.isEmpty else {
                return ("400 Bad Request", Data("bad favorite".utf8), "text/plain")
            }
            do {
                if req.on {
                    try await database.setFavorite(.init(kind: req.kind, key: req.key,
                                                         title: req.title, artist: req.artist))
                } else {
                    try await database.removeFavorite(kind: req.kind, key: req.key)
                }
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            } catch {
                return ("500 Internal Server Error", Data("favorite failed".utf8), "text/plain")
            }
        }
        if path.hasPrefix("/favorites") {
            if let entries = try? await database.allFavorites(),
               let body = try? JSONEncoder().encode(entries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("favorites failed".utf8), "text/plain")
        }
        // Bookmarks ("Bewaar voor later") — same server-of-record shape as
        // favorites: POST one toggle, GET the whole set.
        if method == "POST", path.hasPrefix("/bookmark"), !path.hasPrefix("/bookmarks") {
            guard let req = try? JSONDecoder().decode(BookmarkToggle.self, from: body),
                  !req.kind.isEmpty, !req.key.isEmpty else {
                return ("400 Bad Request", Data("bad bookmark".utf8), "text/plain")
            }
            do {
                if req.on {
                    try await database.setBookmark(.init(kind: req.kind, key: req.key,
                                                         title: req.title, artist: req.artist, album: req.album))
                } else {
                    try await database.removeBookmark(kind: req.kind, key: req.key)
                }
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            } catch {
                return ("500 Internal Server Error", Data("bookmark failed".utf8), "text/plain")
            }
        }
        if path.hasPrefix("/bookmarks") {
            if let entries = try? await database.allBookmarks(),
               let body = try? JSONEncoder().encode(entries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("bookmarks failed".utf8), "text/plain")
        }
        // Saved playlists live on the server-of-record so every client app sees
        // the same set (was client-local — each device kept its own).
        if method == "POST", path == "/playlists" {
            guard let req = try? JSONDecoder().decode(SavePlaylistRequest.self, from: body),
                  !req.name.isEmpty else {
                return ("400 Bad Request", Data("bad playlist".utf8), "text/plain")
            }
            if let id = try? await database.savePlaylist(name: req.name, tracks: req.tracks) {
                return ("200 OK", Data("{\"id\":\(id)}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("save failed".utf8), "text/plain")
        }
        if method == "DELETE", path == "/playlists" {
            guard let id = Int64(Self.queryValue("id", in: target) ?? "") else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            if (try? await database.deletePlaylist(id: id)) != nil {
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("delete failed".utf8), "text/plain")
        }
        if method == "GET", path == "/playlists" {
            if let summaries = try? await database.listPlaylists(),
               let body = try? JSONEncoder().encode(summaries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("playlists failed".utf8), "text/plain")
        }
        if path.hasPrefix("/playlist-tracks") {
            guard let id = Int64(Self.queryValue("id", in: target) ?? "") else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            if let tracks = try? await database.playlistTracks(id: id),
               let body = try? JSONEncoder().encode(tracks) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("playlist tracks failed".utf8), "text/plain")
        }
        // User-composed sonic radios (RadioConfig) — server-of-record like saved
        // playlists. POST doubles as create AND update (upsert on the config id),
        // so there's no need for a PUT verb (which nothing else here uses).
        if method == "POST", path == "/radio-configs" {
            guard let cfg = try? JSONDecoder().decode(RadioConfig.self, from: body),
                  !cfg.name.isEmpty, !cfg.id.isEmpty else {
                return ("400 Bad Request", Data("bad radio config".utf8), "text/plain")
            }
            if (try? await database.upsertRadioConfig(cfg)) != nil {
                return ("200 OK", Data("{\"id\":\"\(cfg.id)\"}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("save failed".utf8), "text/plain")
        }
        if method == "DELETE", path == "/radio-configs" {
            guard let id = Self.queryValue("id", in: target), !id.isEmpty else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            if (try? await database.deleteRadioConfig(id: id)) != nil {
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("delete failed".utf8), "text/plain")
        }
        if method == "GET", path == "/radio-configs" {
            if let configs = try? await database.listRadioConfigs(),
               let body = try? JSONEncoder().encode(configs) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("radio configs failed".utf8), "text/plain")
        }
        // AI-radio management: the auto radios' on/off (Qobuz mirror) selection,
        // exposed so any client can manage them in the unified "Mijn radio's" view.
        if method == "POST", path == "/ai-radio-selection" {
            guard let req = try? JSONDecoder().decode(AIRadioSelectionRequest.self, from: body),
                  await RoonClient.shared.applyAIRadioChange(req) else {
                return ("400 Bad Request", Data("bad selection".utf8), "text/plain")
            }
            return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
        }
        if method == "GET", path == "/ai-radios" {
            return ("200 OK", await RoonClient.shared.aiRadioManagementData(), "application/json")
        }
        if method == "GET", path == "/radio-hidden" {
            return ("200 OK", await RoonClient.shared.hiddenRadioIDsData(), "application/json")
        }
        if path.hasPrefix("/playback") {
            let zone = Self.queryValue("zone", in: target)
            let data = await RoonClient.shared.snapshotData(forZone: zone)
            return ("200 OK", data, "application/json")
        }
        if path.hasPrefix("/library") {
            let sig = ((try? database.syncStateValue(forKey: "last_sync")) ?? nil) ?? ""
            if let cached = await libCache.get(for: sig) {
                return ("200 OK", cached, "application/json")
            }
            if let body = try? await database.exportLibraryJSON() {
                await libCache.set(sig: sig, data: body)
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/history") {
            if let snap = try? await database.listenSnapshot(),
               let body = try? JSONEncoder().encode(snap) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("history failed".utf8), "text/plain")
        }
        // Track-level play stats (content key → count + last played). Thin clients
        // have no local `listening_history`, so Sonic DNA and the personal taste
        // vector pull these from here. `since` (ISO8601) restricts the window.
        if path.hasPrefix("/play-stats") {
            let since = Self.queryValue("since", in: target)
            if let rows = try? await database.playStatsByMatchKey(since: since) {
                let stats = rows.map { SonicDNA.PlayStat(matchKey: $0.matchKey, count: $0.count, lastPlayed: $0.lastPlayed) }
                if let body = try? JSONEncoder().encode(stats) {
                    return ("200 OK", body, "application/json")
                }
            }
            return ("500 Internal Server Error", Data("play-stats failed".utf8), "text/plain")
        }
        if path.hasPrefix("/taste-analysis") {
            if let analysis = try? await database.tasteAnalysis(),
               let body = try? JSONEncoder().encode(analysis) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("taste-analysis failed".utf8), "text/plain")
        }
        if path.hasPrefix("/year-review") {
            let year = Int(Self.queryValue("year", in: target) ?? "") ?? Calendar.current.component(.year, from: Date())
            if let stats = try? await database.yearInReview(year: year),
               let body = try? JSONEncoder().encode(stats) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("year-review failed".utf8), "text/plain")
        }
        // "Op deze dag": plays from today's month-day in earlier years. Thin clients
        // have no local listening_history, so they pull it from the server-of-record.
        if path.hasPrefix("/on-this-day") {
            if let entries = try? await database.onThisDay(),
               let body = try? JSONEncoder().encode(entries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("on-this-day failed".utf8), "text/plain")
        }
        // Taste time machine: top artists per year. Thin clients pull it from the
        // server-of-record (they have no local listening_history).
        if path.hasPrefix("/taste-timemachine") {
            if let periods = try? await database.tasteTimeMachine(),
               let body = try? JSONEncoder().encode(periods) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("taste-timemachine failed".utf8), "text/plain")
        }
        if path.hasPrefix("/settings") {
            // Seal the credential half for the caller's token (see SecretsEnvelope).
            // The route is token-gated for every peer including loopback, so a
            // token is always present here; a missing one means "no secrets in the
            // payload" rather than "secrets in the clear".
            let callerToken = Self.headerValue(Self.tokenHeader, in: header)
            if let body = try? JSONEncoder().encode(SyncableSettings.exportCurrent(encryptingFor: callerToken)) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/artist-radios") {
            let raw = Self.queryValue("category", in: target) ?? "artist"
            // "all" → every radio currently mirrored to Qobuz, across all categories.
            if raw == "all" {
                return ("200 OK", await RoonClient.shared.mirroredRadiosData(), "application/json")
            }
            let category = RoonClient.RadioCategory(rawValue: raw) ?? .artist
            let data = await RoonClient.shared.artistRadiosData(category: category)
            return ("200 OK", data, "application/json")
        }
        // "Ontdek Wekelijks" — the library-first weekly discovery playlist (see
        // RoonClient+DiscoverWeekly). GET serves the latest built playlist (or null);
        // POST .../refresh rebuilds this week now and returns the fresh set. The
        // refresh prefix is checked FIRST (it also matches "/discover-weekly").
        if method == "POST", path.hasPrefix("/discover-weekly/refresh") {
            let pl = await RoonClient.shared.refreshDiscoverWeekly()
            return ("200 OK", (try? JSONEncoder().encode(pl)) ?? Data("null".utf8), "application/json")
        }
        if path.hasPrefix("/discover-weekly") {
            return ("200 OK", await RoonClient.shared.discoverWeeklyData(), "application/json")
        }
        // Discovery engine (see RoonClient+Discovery). accept/play/reject run the
        // side-effects against the server's live Roon+Qobuz session; run kicks a
        // detached pipeline pass; recommendations/run-status serve the feed.
        if method == "POST",
           path.hasPrefix("/discovery/accept") || path.hasPrefix("/discovery/play") || path.hasPrefix("/discovery/reject") {
            let ok = await RoonClient.shared.handleDiscoveryAction(path, body: body)
            return ok ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                      : ("400 Bad Request", Data("bad discovery action".utf8), "text/plain")
        }
        // Scheduled-job introspection + manual trigger (TaskScheduler). Read-only
        // GET; the POST is deduped by the scheduler itself, so hammering it
        // cannot stack pipelines.
        if method == "GET", path == "/system/tasks" {
            let tasks = await TaskScheduler.shared.info()
            if let body = try? JSONEncoder().encode(tasks) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("tasks failed".utf8), "text/plain")
        }
        if method == "POST", path.hasPrefix("/system/tasks/") {
            let name = String(path.dropFirst("/system/tasks/".count))
                .replacingOccurrences(of: "/run", with: "")
            guard !name.isEmpty else {
                return ("400 Bad Request", Data("bad task name".utf8), "text/plain")
            }
            guard await TaskScheduler.shared.isRegistered(name) else {
                return ("404 Not Found", Data("unknown task".utf8), "text/plain")
            }
            let started = await TaskScheduler.shared.runNow(name)
            return started
                ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                : ("409 Conflict", Data("{\"ok\":false,\"reason\":\"already running\"}".utf8), "application/json")
        }
        if method == "POST", path.hasPrefix("/discovery/run") {
            // F12a: an optional mood seed rides along in the body; fase 2: an
            // optional free-text vibe query. Absent/undecodable body → both nil,
            // identical to the pre-F12a behaviour.
            let req = try? JSONDecoder().decode(RoonClient.DiscoveryRunRequest.self, from: body)
            await RoonClient.shared.runDiscoveryNow(mood: req?.mood, textQuery: req?.textQuery)
            return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
        }
        if path.hasPrefix("/discovery/run-status") {
            return ("200 OK", await RoonClient.shared.discoveryRunStatusData(), "application/json")
        }
        if path.hasPrefix("/discovery/recommendations") {
            let kind = RecommendationKind(rawValue: Self.queryValue("kind", in: target) ?? "all")  // nil = all
            let limit = Int(Self.queryValue("limit", in: target) ?? "") ?? 60
            return ("200 OK", await RoonClient.shared.discoveryRecommendationsData(kind: kind, limit: limit), "application/json")
        }
        if path.hasPrefix("/discovery/stats") {
            return ("200 OK", await RoonClient.shared.discoveryStatsData(), "application/json")
        }
        if path.hasPrefix("/discovery/digest-status") {
            return ("200 OK", await RoonClient.shared.discoveryDigestStatusData(), "application/json")
        }
        // Songtekst-zoek (gap C) — MOET vóór de algemene "/lyrics"-prefix-check
        // staan, anders slokt die deze route op.
        if path.hasPrefix("/lyrics/search") {
            let q = Self.queryValue("q", in: target) ?? ""
            let limit = min(200, max(1, Int(Self.queryValue("limit", in: target) ?? "") ?? 60))
            let data = await RoonClient.shared.lyricsSearchData(query: q, limit: limit)
            return ("200 OK", data, "application/json")
        }
        // Lyrics for the now-playing track. The server checks its DB, fetches from
        // LRCLIB on a miss, stores the result, and returns it — so a played track is
        // populated on demand while the background backfill fills the rest.
        if path.hasPrefix("/lyrics") {
            let title = Self.queryValue("title", in: target) ?? ""
            let artist = Self.queryValue("artist", in: target)
            let album = Self.queryValue("album", in: target)
            let duration = Int(Self.queryValue("duration", in: target) ?? "")
            let data = await RoonClient.shared.lyricsData(
                title: title, artist: artist, album: album, durationSec: duration)
            return ("200 OK", data, "application/json")
        }
        // Notification destinations: list, upsert, delete, and the Test button —
        // which is the part that decides whether anyone ever configures this right.
        if method == "GET", path == "/system/notifications" {
            let list = await NotificationService.shared.destinations()
            if let body = try? JSONEncoder().encode(list) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("notifications failed".utf8), "text/plain")
        }
        if method == "POST", path == "/system/notifications/test" {
            let id = Self.queryValue("id", in: target)
            let accepted = await NotificationService.shared.sendTest(to: id)
            return ("200 OK", Data("{\"accepted\":\(accepted)}".utf8), "application/json")
        }
        if method == "POST", path == "/system/notifications" {
            guard let dest = try? JSONDecoder().decode(NotificationDestination.self, from: body),
                  !dest.url.isEmpty else {
                return ("400 Bad Request", Data("bad destination".utf8), "text/plain")
            }
            await NotificationService.shared.upsert(dest)
            return ("200 OK", Data("{\"id\":\"\(dest.id)\"}".utf8), "application/json")
        }
        if method == "DELETE", path == "/system/notifications" {
            guard let id = Self.queryValue("id", in: target), !id.isEmpty else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            await NotificationService.shared.remove(id: id)
            return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
        }

        // Detailed condition report. Sits under /health for discoverability but is
        // token-gated unlike bare /health: it names hosts, task failures and how
        // full the disk is — useful to an operator, and to nobody else.
        if method == "GET", path.hasPrefix("/health/detail") {
            let results = await HealthCheckService.shared.results()
            if let body = try? JSONEncoder().encode(results) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("health failed".utf8), "text/plain")
        }
        if path.hasPrefix("/health") {
            let n = (try? await database.trackCount()) ?? 0
            // Advertise every address this machine answers on (LAN + ZeroTier).
            // Clients remember them all, so a phone that leaves the house can
            // reach us on the ZeroTier address over 4G/5G — where Bonjour can't
            // help and the LAN address is dead. Addresses only, no secrets;
            // /health is deliberately token-free for discovery.
            let hosts = Self.localIPv4Addresses()
            let obj: [String: Any] = ["status": "ok", "tracks": n, "hosts": hosts]
            let data = (try? JSONSerialization.data(withJSONObject: obj))
                ?? Data("{\"status\":\"ok\",\"tracks\":\(n)}".utf8)
            return ("200 OK", data, "application/json")
        }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }

    /// All IPv4 addresses of active interfaces, loopback and link-local
    /// excluded. Includes VPN/overlay interfaces (ZeroTier's feth/utun), which
    /// is the point: it's the address a remote client needs when off-LAN.
    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return addresses }
        defer { freeifaddrs(first) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            guard !addr.isEmpty, !addr.hasPrefix("169.254.") else { continue }
            if !addresses.contains(addr) { addresses.append(addr) }
        }
        return addresses
    }

    // MARK: - Tiny HTTP parse helpers

    private static func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
    }

    static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                let n = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                // Clamp: a negative or overflowing value would invert the body
                // slice range and trap. 32 MB is far above any real command body.
                return max(0, min(n, 32 * 1024 * 1024))
            }
        }
        return 0
    }

    /// Constant-time string compare — plain `==`/`!=` short-circuits on the first
    /// differing byte, leaking the match length via timing. Used for the token.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        for i in 0..<Swift.max(ab.count, bb.count) {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    static func headerValue(_ name: String, in header: String) -> String? {
        let lname = name.lowercased()
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == lname {
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// True when the connecting peer is on this machine (127.0.0.0/8, ::1, the
    /// v4-mapped loopback, or "localhost"). Such callers skip the token check.
    private static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            if b[10] == 0xff, b[11] == 0xff, b[12] == 127 { return true }        // ::ffff:127.x.x.x
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    /// Human-readable host/IP of the connecting peer, for the approval list.
    static func endpointHost(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let addr):
            return dottedIPv4([UInt8](addr.rawValue))
        case .ipv6(let addr):
            // IPv4-mapped (::ffff:a.b.c.d) reads nicer as its v4 form.
            let b = [UInt8](addr.rawValue)
            if b.count == 16, b[10] == 0xff, b[11] == 0xff {
                return dottedIPv4(Array(b[12..<16]))
            }
            return addr.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return ""
        }
    }

    private static func dottedIPv4(_ b: [UInt8]) -> String {
        b.count == 4 ? "\(b[0]).\(b[1]).\(b[2]).\(b[3])" : ""
    }

    private static func queryValue(_ name: String, in target: String) -> String? {
        guard let q = target.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name {
                return kv[1].removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}
