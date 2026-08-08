@testable import RoonSageCore
import XCTest

/// Covers the share-server hardening: a malformed Content-Length must never
/// produce an inverted body slice (which crashed the always-on process), the
/// token compare must be constant-time-correct, and header parsing must be
/// case-insensitive.
final class LibraryShareServerSecurityTests: XCTestCase {

    private func header(contentLength: String) -> String {
        "POST /command HTTP/1.1\r\nHost: x\r\nContent-Length: \(contentLength)\r\n\r\n"
    }

    func testContentLengthNegativeClampsToZero() {
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "-1")), 0)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "-99999999")), 0)
    }

    func testContentLengthOverflowCapsAt32MB() {
        let cap = 32 * 1024 * 1024
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "999999999999")), cap)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "\(Int.max)")), cap)
    }

    func testContentLengthNormalValuePreserved() {
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "512")), 512)
    }

    func testContentLengthMissingOrGarbageIsZero() {
        XCTAssertEqual(LibraryShareServer.contentLength("GET / HTTP/1.1\r\n\r\n"), 0)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "abc")), 0)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LibraryShareServer.constantTimeEquals("a1b2c3", "a1b2c3"))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("a1b2c3", "a1b2c4"))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("short", "longer-token"))
        XCTAssertTrue(LibraryShareServer.constantTimeEquals("", ""))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("", "x"))
    }

    func testHeaderValueCaseInsensitive() {
        let h = "GET /x HTTP/1.1\r\nX-RoonSage-Token: secret123\r\n\r\n"
        XCTAssertEqual(LibraryShareServer.headerValue("x-roonsage-token", in: h), "secret123")
        XCTAssertEqual(LibraryShareServer.headerValue("X-RoonSage-Token", in: h), "secret123")
    }

    func testHeaderValueMissingIsNil() {
        let h = "GET /x HTTP/1.1\r\nHost: y\r\n\r\n"
        XCTAssertNil(LibraryShareServer.headerValue("X-RoonSage-Token", in: h))
    }

    // MARK: - Device approval

    func testDeviceApprovalLifecycle() {
        let token = "test-device-\(UUID().uuidString)"
        let hash = SecretsEnvelope.tokenHash(token)
        defer { LibraryShareServer.rejectDevice(token: token); LibraryShareServer.revokeDevice(tokenHash: hash) }

        // Unknown → queued as pending, not yet approved.
        XCTAssertFalse(LibraryShareServer.isApprovedDevice(token))
        LibraryShareServer.recordPending(token: token, name: "MacBook Air", ip: "10.0.0.9")
        XCTAssertTrue(LibraryShareServer.pendingDevices().contains { $0.token == token && $0.name == "MacBook Air" })
        XCTAssertFalse(LibraryShareServer.isApprovedDevice(token))

        // Approve → moves out of pending, into approved.
        XCTAssertTrue(LibraryShareServer.approveDevice(token: token))
        XCTAssertTrue(LibraryShareServer.isApprovedDevice(token))
        XCTAssertFalse(LibraryShareServer.pendingDevices().contains { $0.token == token })
        XCTAssertTrue(LibraryShareServer.approvedDevices().contains { $0.tokenHash == hash })
        // The clear-text token must never be what we store.
        XCTAssertFalse(LibraryShareServer.approvedDevices().contains { $0.tokenHash == token })

        // Approving an already-approved (no longer pending) device is a no-op.
        XCTAssertFalse(LibraryShareServer.approveDevice(token: token))

        // Revoke → drops back to unapproved.
        LibraryShareServer.revokeDevice(tokenHash: hash)
        XCTAssertFalse(LibraryShareServer.isApprovedDevice(token))
    }

    func testRecordPendingIgnoresApprovedAndBlankName() {
        let token = "test-device-\(UUID().uuidString)"
        defer { LibraryShareServer.rejectDevice(token: token); LibraryShareServer.revokeDevice(tokenHash: SecretsEnvelope.tokenHash(token)) }

        // Blank name falls back to a placeholder.
        LibraryShareServer.recordPending(token: token, name: "", ip: "10.0.0.1")
        XCTAssertEqual(LibraryShareServer.pendingDevices().first { $0.token == token }?.name, "Onbekend apparaat")

        // Once approved, further knocks must NOT re-queue it.
        XCTAssertTrue(LibraryShareServer.approveDevice(token: token))
        LibraryShareServer.recordPending(token: token, name: "still knocking", ip: "10.0.0.1")
        XCTAssertFalse(LibraryShareServer.pendingDevices().contains { $0.token == token })
    }

    // MARK: - Settings secrets (V1)

    // Note: these build a `SyncableSettings` by hand rather than calling
    // `exportCurrent`, which reads seven Keychain items — from an unsigned xctest
    // bundle that pops a blocking SecurityAgent ACL prompt and hangs the run (the
    // same freeze `KeychainStore` warns about). The sealing contract is what's
    // under test here, not the Keychain read.

    /// A round trip through the wire format restores exactly what went in.
    func testSecretsSurviveEncodeDecodeRoundTrip() throws {
        let token = "caller-\(UUID().uuidString)"
        var original = SyncableSettings()
        original.roonHost = "10.0.0.5"
        original.qobuzPassword = "hunter2"
        original.lastfmSessionKey = "sess-abc"
        original.encryptSecrets(for: token)

        let wire = try JSONEncoder().encode(original)
        // The credentials must not be readable anywhere in the serialized payload.
        let asText = String(decoding: wire, as: UTF8.self)
        XCTAssertFalse(asText.contains("hunter2"))
        XCTAssertFalse(asText.contains("sess-abc"))
        XCTAssertTrue(asText.contains("10.0.0.5"), "niet-geheime velden blijven leesbaar")

        var received = try JSONDecoder().decode(SyncableSettings.self, from: wire)
        XCTAssertTrue(received.decryptSecrets(withToken: token))
        XCTAssertEqual(received.qobuzPassword, "hunter2")
        XCTAssertEqual(received.lastfmSessionKey, "sess-abc")
        XCTAssertEqual(received.roonHost, "10.0.0.5")
    }

    /// An old client (or a wrong token) gets nil secrets — never a partial or
    /// garbled credential, and `apply()`'s nil-skip leaves local values alone.
    func testUndecryptableSecretsStayNil() {
        var s = SyncableSettings()
        s.qobuzPassword = "hunter2"
        s.encryptSecrets(for: "server-side-token")

        var received = s
        XCTAssertFalse(received.decryptSecrets(withToken: "client-has-different-token"))
        XCTAssertNil(received.qobuzPassword)
    }

    /// No caller token → the secrets are dropped, never sent in the clear.
    func testExportWithoutTokenDropsSecretsEntirely() {
        var s = SyncableSettings()
        s.qobuzPassword = "hunter2"
        s.lastfmApiKey = "key"
        s.encryptSecrets(for: nil)

        XCTAssertNil(s.qobuzPassword)
        XCTAssertNil(s.lastfmApiKey)
        XCTAssertNil(s.encryptedSecrets)
    }

    // MARK: - Enforcement default (V2)

    /// A fresh install must not serve the library to unpaired peers. Reads the
    /// live default without disturbing a value the user already set.
    func testEnforceTokenDefaultsToTrueWhenUnset() {
        let key = "share_token_enforce"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(LibraryShareServer.enforceToken, "ongezet moet afdwingen betekenen")

        LibraryShareServer.enforceToken = false
        XCTAssertFalse(LibraryShareServer.enforceToken, "een expliciete uit blijft uit")
    }
}
