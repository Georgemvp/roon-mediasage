import Foundation

// MARK: - Plex sign-in (plex.tv PIN flow)
//
// Fase 4 of PLEX_MIGRATION starts here, and only here.
//
// Streaming audio straight from Plex needs the CLIENT to hold a Plex token.
// `PlexClient.localToken()` reads the *admin* token out of the server's
// Preferences.xml — that only exists on the machine running Plex, and shipping it
// to an iPhone would put a full-access server credential on the network. So each
// device earns its own token through Plex's PIN flow:
//
//   1. `requestPin` → a 4-character code, valid 15 minutes.
//   2. The user types it at https://plex.tv/link.
//   3. `pollPin` returns that device's own token once they have.
//
// Verified against the live plex.tv API on 2026-08-23: `POST /api/v2/pins`
// answers with `id` + a 4-char `code` + `authToken: null` and `expiresIn: 900`.
// (Passing `strong=true` yields a 25-character code instead — unusable for
// someone typing it in, so this deliberately does not.)

public enum PlexAuth {

    /// Keychain key for this device's Plex token.
    public static let tokenKey = "plex_auth_token"
    /// Keychain key for the stable per-install client identifier.
    public static let clientIDKey = "plex_client_identifier"

    /// Where the user types the code.
    public static let linkURL = URL(string: "https://plex.tv/link")!

    /// Product name Plex shows in the user's "authorised devices" list.
    public static let product = "RoonSage"

    public enum AuthError: Error, Sendable, Equatable {
        case http(Int)
        case malformedResponse(String)
        case transport(String)
    }

    public struct Pin: Sendable, Equatable {
        /// Plex's pin id — needed to poll.
        public let id: Int
        /// What the user types at plex.tv/link.
        public let code: String
        /// Seconds until the code expires (900 at the time of writing).
        public let expiresIn: Int

        public init(id: Int, code: String, expiresIn: Int) {
            self.id = id; self.code = code; self.expiresIn = expiresIn
        }
    }

    // MARK: - Identity

    /// Stable identifier for this install, minted once and kept in the Keychain.
    ///
    /// Plex ties an authorised token to the client identifier that requested it,
    /// so a new id on every launch would mean a new sign-in on every launch — and
    /// a growing list of stale devices in the user's Plex account.
    public static func clientIdentifier() -> String {
        if let existing = KeychainStore.load(key: clientIDKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        _ = KeychainStore.save(key: clientIDKey, value: fresh)
        return fresh
    }

    /// This device's Plex token, or nil when it has not signed in.
    public static func storedToken() -> String? {
        let t = KeychainStore.load(key: tokenKey)
        return (t?.isEmpty ?? true) ? nil : t
    }

    public static func store(token: String) -> Bool {
        KeychainStore.save(key: tokenKey, value: token)
    }

    @discardableResult
    public static func signOut() -> Bool {
        KeychainStore.delete(key: tokenKey)
    }

    // MARK: - The flow

    /// Ask plex.tv for a fresh link code.
    public static func requestPin(session: URLSession = .shared) async throws -> Pin {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        applyHeaders(&req)
        let json = try await json(for: req, session: session)
        guard let pin = parsePin(json) else {
            throw AuthError.malformedResponse("pins: no id/code")
        }
        return pin
    }

    /// Has the user linked the code yet? Returns the device token once they have,
    /// nil while `authToken` is still null (which is the normal state until they do).
    public static func pollPin(id: Int, session: URLSession = .shared) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(id)")!)
        req.timeoutInterval = 20
        applyHeaders(&req)
        let json = try await json(for: req, session: session)
        return parseToken(json)
    }

    /// Sign in end to end: hand the code to `onCode`, then poll until the user has
    /// linked it or the code expires. Stores the token in the Keychain and returns it.
    ///
    /// nil = the code expired without being linked, which is a normal outcome
    /// (the user walked away), not an error.
    public static func signIn(pollEvery seconds: UInt64 = 2,
                              session: URLSession = .shared,
                              onCode: @Sendable (Pin) -> Void) async throws -> String? {
        let pin = try await requestPin(session: session)
        onCode(pin)
        let deadline = Date().addingTimeInterval(Double(pin.expiresIn))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            try Task.checkCancellation()
            // A transient poll failure must not abort a sign-in the user is
            // halfway through typing; keep trying until the code itself expires.
            guard let token = try? await pollPin(id: pin.id, session: session) else { continue }
            _ = store(token: token)
            return token
        }
        return nil
    }

    // MARK: - Server discovery
    //
    // Without this a signed-in phone syncs nothing, and the failure is silent:
    // `plexBaseURL` defaults to `http://127.0.0.1:32400`, which is right on the
    // machine running Plex and is the PHONE ITSELF everywhere else. Measured
    // 2026-08-23 — a device that had linked correctly still showed 0 tracks.
    //
    // plex.tv knows where the server actually is. For this account it returns
    // three routes: two local (`10-94-184-22…` over ZeroTier, `192-168-178-59…`
    // over the LAN) and one external on a different port — that last one is Plex
    // Remote Access, which is exactly what makes the app work away from home
    // without ZeroTier.

    public struct Connection: Sendable, Equatable {
        public let uri: String
        public let local: Bool
        public let relay: Bool
    }

    public struct Server: Sendable, Equatable {
        public let name: String
        /// Token scoped to THIS server. Not always the account token, so prefer it.
        public let accessToken: String?
        public let connections: [Connection]
    }

    /// Servers this account can reach.
    public static func servers(session: URLSession = .shared) async throws -> [Server] {
        guard let token = storedToken() else { throw AuthError.malformedResponse("not signed in") }
        var comps = URLComponents(string: "https://plex.tv/api/v2/resources")!
        comps.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        applyHeaders(&req)
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            throw AuthError.transport(error.localizedDescription)
        }
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw AuthError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(code) else { throw AuthError.http(code) }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AuthError.malformedResponse("resources: not a JSON array")
        }
        return parseServers(raw)
    }

    /// Split out so the wire shape is testable without plex.tv.
    static func parseServers(_ raw: [[String: Any]]) -> [Server] {
        raw.compactMap { r in
            // `provides` is a comma list; a Plex account also returns players and
            // controllers, which have no library to talk to.
            guard (r["provides"] as? String)?.contains("server") == true else { return nil }
            let conns = (r["connections"] as? [[String: Any]] ?? []).compactMap { c -> Connection? in
                guard let uri = c["uri"] as? String, !uri.isEmpty else { return nil }
                return Connection(uri: uri,
                                  local: (c["local"] as? Bool) ?? false,
                                  relay: (c["relay"] as? Bool) ?? false)
            }
            guard !conns.isEmpty else { return nil }
            return Server(name: (r["name"] as? String) ?? "Plex",
                          accessToken: r["accessToken"] as? String,
                          connections: conns)
        }
    }

    /// Order to try connections in: local first (fast, no relay hop), then a
    /// direct external address, and only then a relayed one — a relay works
    /// everywhere but goes through Plex's infrastructure and is the slowest.
    static func ranked(_ connections: [Connection]) -> [Connection] {
        connections.sorted { a, b in
            func rank(_ c: Connection) -> Int { c.relay ? 2 : (c.local ? 0 : 1) }
            return rank(a) < rank(b)
        }
    }

    /// First connection that actually answers, with the token to use for it.
    ///
    /// Probes `/identity`, which needs no auth and is the cheapest thing a Plex
    /// server serves. A short timeout per candidate: an unreachable LAN address
    /// from a phone on mobile data should cost a second, not thirty.
    public static func reachableServer(session: URLSession = .shared,
                                       timeout: TimeInterval = 3) async
    -> (baseURL: String, token: String)? {
        guard let account = storedToken(), let list = try? await servers(session: session) else { return nil }
        for server in list {
            let token = server.accessToken ?? account
            for conn in ranked(server.connections) {
                guard let url = URL(string: conn.uri + "/identity") else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                guard let (_, resp) = try? await session.data(for: req),
                      let code = (resp as? HTTPURLResponse)?.statusCode,
                      (200..<300).contains(code) else { continue }
                return (conn.uri, token)
            }
        }
        return nil
    }

    // MARK: - Parsing (split out so the wire shape is testable without plex.tv)

    static func parsePin(_ json: [String: Any]) -> Pin? {
        guard let id = PlexClient.intValue(json["id"]),
              let code = json["code"] as? String, !code.isEmpty else { return nil }
        return Pin(id: id, code: code, expiresIn: PlexClient.intValue(json["expiresIn"]) ?? 900)
    }

    /// `authToken` is explicitly null until the user links the code — that is the
    /// expected state, not a parse failure.
    static func parseToken(_ json: [String: Any]) -> String? {
        guard let token = json["authToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Transport

    static func applyHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        req.setValue(clientIdentifier(), forHTTPHeaderField: "X-Plex-Client-Identifier")
    }

    private static func json(for req: URLRequest, session: URLSession) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AuthError.transport(error.localizedDescription)
        }
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw AuthError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(code) else { throw AuthError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformedResponse("not a JSON object")
        }
        return obj
    }
}
