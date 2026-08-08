@testable import RoonSageCore
import XCTest

/// Dekt de AES-GCM-envelop voor de credential-helft van `SyncableSettings`: een rondgang
/// met hetzelfde token moet identiek terugkomen, elk ander token of geknoeide byte moet
/// nil geven (nooit een halve payload), en de tokenhash moet stabiel en niet-omkeerbaar zijn.
final class SecretsEnvelopeTests: XCTestCase {

    private struct Payload: Codable, Equatable {
        var apiKey: String?
        var password: String?
        var count: Int
    }

    private let sample = Payload(apiKey: "sk-abc123", password: "hunter2", count: 7)

    func testRoundTripWithSameToken() {
        let token = "a1b2c3d4e5f6"
        guard let sealed = SecretsEnvelope.seal(sample, token: token) else {
            return XCTFail("seal gaf nil voor een geldig token")
        }
        XCTAssertEqual(SecretsEnvelope.open(Payload.self, from: sealed, token: token), sample)
    }

    func testWrongTokenFailsClosed() {
        let sealed = SecretsEnvelope.seal(sample, token: "correct-token")
        XCTAssertNotNil(sealed)
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: sealed!, token: "wrong-token"))
    }

    func testEmptyTokenNeverSealsOrOpens() {
        XCTAssertNil(SecretsEnvelope.seal(sample, token: ""))
        let sealed = SecretsEnvelope.seal(sample, token: "t")!
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: sealed, token: ""))
    }

    func testCiphertextDoesNotLeakPlaintext() {
        let sealed = SecretsEnvelope.seal(sample, token: "a-token")!
        XCTAssertFalse(sealed.contains("hunter2"))
        XCTAssertFalse(sealed.contains("sk-abc123"))
        // Het base64-blok moet ook na decodering geen leesbare sleutel bevatten.
        let raw = String(decoding: Data(base64Encoded: sealed) ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains("hunter2"))
    }

    func testTamperedCiphertextIsRejected() {
        let token = "a-token"
        let sealed = SecretsEnvelope.seal(sample, token: token)!
        var bytes = [UInt8](Data(base64Encoded: sealed)!)
        // Flip één bit in de ciphertext (voorbij de 12-byte nonce) — de GCM-tag moet dat vangen.
        bytes[bytes.count - 1] ^= 0x01
        let tampered = Data(bytes).base64EncodedString()
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: tampered, token: token))
    }

    func testGarbageInputIsRejected() {
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: "niet-base64!!", token: "t"))
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: "", token: "t"))
        // Te kort voor nonce+tag → SealedBox(combined:) gooit, geen crash.
        XCTAssertNil(SecretsEnvelope.open(Payload.self, from: Data([1, 2, 3]).base64EncodedString(), token: "t"))
    }

    func testNonceMakesEachSealDistinct() {
        let a = SecretsEnvelope.seal(sample, token: "t")
        let b = SecretsEnvelope.seal(sample, token: "t")
        XCTAssertNotEqual(a, b, "AES-GCM moet per seal een verse nonce gebruiken")
    }

    func testTokenHashIsStableAndOpaque() {
        let h = SecretsEnvelope.tokenHash("device-token-123")
        XCTAssertEqual(h, SecretsEnvelope.tokenHash("device-token-123"))
        XCTAssertNotEqual(h, SecretsEnvelope.tokenHash("device-token-124"))
        XCTAssertEqual(h.count, 64)                       // SHA-256 als hex
        XCTAssertFalse(h.contains("device-token-123"))
    }
}
