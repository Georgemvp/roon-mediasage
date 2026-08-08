import CryptoKit
import Foundation

/// Vertrouwelijkheid voor de credential-helft van `SyncableSettings`.
///
/// `GET /settings` draagt API-keys, de Last.fm-sessie en het Qobuz-wachtwoord, en de
/// share-server praat plat HTTP over LAN én ZeroTier (`LibraryShareServer.send`). De
/// token-gate houdt een *onbevoegde vraag* tegen, maar niet het *meelezen* onderweg.
///
/// Server en client delen al een geheim: het goedgekeurde apparaat-token. Daaruit leidt
/// dit envelop een AES-GCM-sleutel af (HKDF-SHA256), zodat de secrets versleuteld over de
/// lijn gaan zonder TLS en zonder dat de gebruiker iets extra's hoeft in te stellen. Een
/// meelezer zonder het token ziet base64-ruis; een verkeerd token faalt op de GCM-tag
/// (authenticated encryption), niet met stille rommel.
///
/// Bewust *geen* vervanging voor TLS: het beschermt de payload, niet de metadata (welke
/// paden, hoe groot). Zie `docs/BENCHMARK-LIDARR-DROPPEDNEEDLE.md` V1 stap 3.
public enum SecretsEnvelope {
    /// Formaatversie van de envelop. Meegestuurd zodat een toekomstige sleutel- of
    /// cipherwissel herkenbaar is in plaats van als decodeerfout te verschijnen.
    public static let version = 1

    /// Vaste salt + info voor HKDF. Statisch mag hier: het invoermateriaal (het token) is
    /// zelf al 24 willekeurige bytes uit `ensureDeviceToken()`, dus de salt hoeft geen
    /// entropie toe te voegen — hij scheidt alleen dit gebruik van elk ander gebruik van
    /// hetzelfde token (domeinscheiding).
    private static let salt = Data("RoonSage-share-server".utf8)
    private static let info = Data("RoonSage-Settings-v1".utf8)

    static func key(forToken token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: salt,
            info: info,
            outputByteCount: 32)
    }

    /// Versleutel `value` voor de houder van `token`. Geeft base64 van het AES-GCM
    /// combined-formaat (nonce‖ciphertext‖tag), of nil bij een leeg token of een waarde
    /// die niet te coderen is — de aanroeper valt dan terug op "geen secrets meesturen",
    /// nooit op "onversleuteld meesturen".
    public static func seal<T: Encodable>(_ value: T, token: String) -> String? {
        guard !token.isEmpty, let plain = try? JSONEncoder().encode(value) else { return nil }
        guard let box = try? AES.GCM.seal(plain, using: key(forToken: token)),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// Keer `seal` om. nil bij een leeg/verkeerd token, geknoeide bytes of een payload die
    /// niet als `T` decodeert — alle drie zijn "we hebben geen secrets", niet een halve.
    public static func open<T: Decodable>(_ type: T.Type, from base64: String, token: String) -> T? {
        guard !token.isEmpty,
              let data = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key(forToken: token))
        else { return nil }
        return try? JSONDecoder().decode(type, from: plain)
    }

    /// Stabiele hash van een apparaat-token, voor opslag in plaats van de klare tekst.
    /// De server hoeft het token nooit terug te lezen — hij vergelijkt alleen. Zelfde
    /// hex-digest-idioom als `DiskImageCache.cacheKey`.
    public static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
