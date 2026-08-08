import Foundation

/// The configuration the Mac can hand to the iPhone so the phone works like a
/// remote without re-entering everything by hand. Exported by the Mac's
/// `LibraryShareServer` (`GET /settings`) and applied on the phone via
/// `RoonClient.importSettings(fromMac:)`. Mirrors the one-tap library import.
///
/// Every field is optional: a service the Mac hasn't configured stays `nil` and
/// `apply()` leaves whatever the phone already has untouched — importing never
/// wipes a credential the phone set up itself.
///
/// Note: this carries secrets (API keys, Last.fm session, Qobuz password). The
/// share server speaks plain HTTP over LAN/ZeroTier, so those fields are NOT sent
/// in the clear: `exportCurrent(encryptingFor:)` moves them into
/// `encryptedSecrets` (AES-GCM, key derived from the caller's approved device
/// token — see `SecretsEnvelope`) and the client calls `decryptSecrets(withToken:)`
/// before `apply()`. A client that can't decrypt simply sees `nil` secrets, and
/// `apply()`'s nil-skips leave its existing credentials untouched.
public struct SyncableSettings: Codable, Sendable {
    public var roonHost: String?
    public var roonPort: Int?

    public var llmProvider: String?
    public var llmBaseURL: String?
    public var llmModel: String?
    public var llmApiKey: String?

    public var analyzerURL: String?

    public var listenbrainzToken: String?

    public var lastfmApiKey: String?
    public var lastfmApiSecret: String?
    public var lastfmSessionKey: String?
    public var lastfmUsername: String?
    public var lastfmScrobbleEnabled: Bool?

    public var qobuzEmail: String?
    public var qobuzPassword: String?

    /// Base64 AES-GCM envelope holding `Secrets`, sealed for the requesting
    /// device's token. Set instead of the plain credential fields whenever the
    /// caller identified itself; see `SecretsEnvelope`.
    public var encryptedSecrets: String?
    /// Format version of `encryptedSecrets` (`SecretsEnvelope.version`).
    public var secretsVersion: Int?

    public init() {}

    /// The credential half of the settings — everything an eavesdropper must not
    /// read. Kept as a separate Codable so it can be sealed as one unit.
    public struct Secrets: Codable, Sendable {
        public var llmApiKey: String?
        public var listenbrainzToken: String?
        public var lastfmApiKey: String?
        public var lastfmApiSecret: String?
        public var lastfmSessionKey: String?
        public var qobuzEmail: String?
        public var qobuzPassword: String?
    }

    /// Lift the credential fields out of `self` (leaving them nil) and return them.
    private mutating func takeSecrets() -> Secrets {
        var s = Secrets()
        s.llmApiKey = llmApiKey;                 llmApiKey = nil
        s.listenbrainzToken = listenbrainzToken; listenbrainzToken = nil
        s.lastfmApiKey = lastfmApiKey;           lastfmApiKey = nil
        s.lastfmApiSecret = lastfmApiSecret;     lastfmApiSecret = nil
        s.lastfmSessionKey = lastfmSessionKey;   lastfmSessionKey = nil
        s.qobuzEmail = qobuzEmail;               qobuzEmail = nil
        s.qobuzPassword = qobuzPassword;         qobuzPassword = nil
        return s
    }

    /// Undo `takeSecrets` on the receiving side. Only non-nil fields are written,
    /// matching `apply()`'s rule that an unset field never clears a local value.
    private mutating func merge(_ s: Secrets) {
        if let v = s.llmApiKey { llmApiKey = v }
        if let v = s.listenbrainzToken { listenbrainzToken = v }
        if let v = s.lastfmApiKey { lastfmApiKey = v }
        if let v = s.lastfmApiSecret { lastfmApiSecret = v }
        if let v = s.lastfmSessionKey { lastfmSessionKey = v }
        if let v = s.qobuzEmail { qobuzEmail = v }
        if let v = s.qobuzPassword { qobuzPassword = v }
    }

    /// Seal the credential half for the holder of `token`. A nil/empty token or a
    /// failing seal leaves the secrets **out** of the payload entirely — the
    /// fallback is "no credentials", never "credentials in the clear".
    public mutating func encryptSecrets(for token: String?) {
        let secrets = takeSecrets()
        guard let token, !token.isEmpty,
              let sealed = SecretsEnvelope.seal(secrets, token: token) else { return }
        encryptedSecrets = sealed
        secretsVersion = SecretsEnvelope.version
    }

    /// Open the envelope with this device's token and fold the credentials back
    /// into the plain fields, so `apply()` needs no special case. Returns whether
    /// an envelope was present *and* opened; a wrong token or a newer format
    /// version yields false and leaves the credentials nil.
    @discardableResult
    public mutating func decryptSecrets(withToken token: String) -> Bool {
        guard let blob = encryptedSecrets, !blob.isEmpty else { return false }
        guard (secretsVersion ?? SecretsEnvelope.version) <= SecretsEnvelope.version,
              let secrets = SecretsEnvelope.open(Secrets.self, from: blob, token: token)
        else { return false }
        merge(secrets)
        return true
    }

    /// Snapshot the current device's settings from UserDefaults + Keychain.
    /// Reads only thread-safe stores (no main-actor isolation), so the share
    /// server can call this straight from its connection queue.
    ///
    /// `encryptingFor` is the requesting client's token: when set, the credential
    /// fields are sealed into `encryptedSecrets` instead of being sent in the
    /// clear. Callers that legitimately need the raw snapshot on this device
    /// (nothing crosses a wire) pass nil.
    public static func exportCurrent(encryptingFor token: String? = nil) -> SyncableSettings {
        let d = UserDefaults.standard
        var s = SyncableSettings()

        s.roonHost = d.string(forKey: "lastRoonHost")
        let port = d.integer(forKey: "lastRoonPort")
        s.roonPort = port > 0 ? port : nil

        let llm = LLMConfigStore.load()
        s.llmProvider = llm.provider.rawValue
        s.llmBaseURL = llm.baseURL
        s.llmModel = llm.model
        s.llmApiKey = llm.apiKey.isEmpty ? nil : llm.apiKey

        s.analyzerURL = d.string(forKey: "analyzer_url").flatMap { $0.isEmpty ? nil : $0 }

        s.listenbrainzToken = KeychainStore.load(key: "listenbrainz_token")

        s.lastfmApiKey = KeychainStore.load(key: "lastfm_api_key")
        s.lastfmApiSecret = KeychainStore.load(key: "lastfm_api_secret")
        s.lastfmSessionKey = KeychainStore.load(key: "lastfm_session_key")
        s.lastfmUsername = KeychainStore.load(key: "lastfm_username")
        s.lastfmScrobbleEnabled = d.object(forKey: "lastfm_scrobble_enabled") as? Bool

        s.qobuzEmail = KeychainStore.load(key: "qobuz_email")
        s.qobuzPassword = KeychainStore.load(key: "qobuz_password")

        s.encryptSecrets(for: token)
        return s
    }

    /// Write the synced settings into this device's stores. `nil`/empty fields
    /// are skipped so an unconfigured service on the Mac never clears one the
    /// phone already has. Roon host/port is persisted here but connecting is the
    /// caller's job (see `RoonClient.importSettings`).
    public func apply() {
        let d = UserDefaults.standard

        if let host = roonHost {
            let clean = RoonClient.normalizeHost(host)   // never store a scheme/port in the host
            if !clean.isEmpty {
                d.set(clean, forKey: "lastRoonHost")
                if let port = roonPort, port > 0 { d.set(port, forKey: "lastRoonPort") }
            }
        }

        if let providerRaw = llmProvider,
           let provider = LLMConfig.Provider(rawValue: providerRaw) {
            var cfg = LLMConfigStore.load()
            cfg.provider = provider
            if let v = llmBaseURL, !v.isEmpty { cfg.baseURL = v }
            if let v = llmModel, !v.isEmpty { cfg.model = v }
            if let v = llmApiKey, !v.isEmpty { cfg.apiKey = v }
            LLMConfigStore.save(cfg)
        }

        if let v = analyzerURL, !v.isEmpty { d.set(v, forKey: "analyzer_url") }

        applyKeychain("listenbrainz_token", listenbrainzToken)
        applyKeychain("lastfm_api_key", lastfmApiKey)
        applyKeychain("lastfm_api_secret", lastfmApiSecret)
        applyKeychain("lastfm_session_key", lastfmSessionKey)
        applyKeychain("lastfm_username", lastfmUsername)
        if let enabled = lastfmScrobbleEnabled { d.set(enabled, forKey: "lastfm_scrobble_enabled") }

        applyKeychain("qobuz_email", qobuzEmail)
        applyKeychain("qobuz_password", qobuzPassword)
    }

    private func applyKeychain(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        KeychainStore.save(key: key, value: value)
    }
}
