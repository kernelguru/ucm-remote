import XCTest
@testable import UCMRemote

final class ModelTests: XCTestCase {
    func testParsePrincipals() {
        XCTAssertEqual(SignRequest.parsePrincipals("root, marc\nadmin  ops,"), ["root", "marc", "admin", "ops"])
        XCTAssertEqual(SignRequest.parsePrincipals("  "), [])
    }

    func testSignRequestBody() {
        var r = SignRequest(caID: 3, certType: .host, principals: ["a"], validity: .caDefault, keyID: " ", descr: "")
        XCTAssertNil(r.body["validity_seconds"])
        XCTAssertNil(r.body["key_id"])
        XCTAssertEqual(r.body["cert_type"] as? String, "host")
        r.validity = .day
        r.keyID = " k1 "
        XCTAssertEqual(r.body["validity_seconds"] as? Int, 86400)
        XCTAssertEqual(r.body["key_id"] as? String, "k1")
    }

    private func decodeCert(_ json: String) throws -> SSHCertificate {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope<SSHCertificate>.self, from: Data(json.utf8)).data
    }

    func testDecodeCertificate() throws {
        let cert = try decodeCert("""
        {"data": {"id": 5, "ssh_ca_id": 3, "cert_type": "user", "key_id": "marc", "principals": ["marc"],
                  "serial": 9, "valid_from": "2026-01-01T00:00:00.000Z", "valid_to": "2026-01-02T00:00:00Z",
                  "revoked": false, "public_key": "ssh-ed25519 AAAA test"}, "message": "ok"}
        """)
        XCTAssertEqual(cert.sshCaId, 3)
        XCTAssertEqual(cert.displayName, "marc")
        XCTAssertNotNil(cert.validFromDate)
        XCTAssertEqual(cert.validToDate, ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
    }

    func testExpiryStates() throws {
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let base = #"{"data": {"id": 1, "valid_to": "%@", "revoked": %@}}"#
        func cert(_ to: String, revoked: Bool = false) throws -> SSHCertificate {
            try decodeCert(String(format: base, to, revoked ? "true" : "false"))
        }
        XCTAssertEqual(try cert("2026-03-01T00:00:00Z").expiry(now: now), .valid(ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")!))
        if case .soon = try cert("2026-01-03T00:00:00Z").expiry(now: now) {} else { XCTFail("soon") }
        XCTAssertEqual(try cert("2025-12-31T00:00:00Z").expiry(now: now), .expired)
        XCTAssertEqual(try cert("2026-03-01T00:00:00Z", revoked: true).expiry(now: now), .revoked)
    }

    func testReminderDate() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let now = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let long = try decoder.decode(SSHCertificate.self, from: Data(#"{"id": 1, "valid_from": "2026-01-01T00:00:00Z", "valid_to": "2026-02-01T00:00:00Z"}"#.utf8))
        XCTAssertEqual(ExpiryNotifier.fireDate(for: long, lead: 86400, now: now),
                       ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z"))
        // 8 Stunden Laufzeit: Erinnerung nach drei Vierteln (2 Stunden vor Ablauf)
        let short = try decoder.decode(SSHCertificate.self, from: Data(#"{"id": 2, "valid_from": "2026-01-01T00:00:00Z", "valid_to": "2026-01-01T08:00:00Z"}"#.utf8))
        XCTAssertEqual(ExpiryNotifier.fireDate(for: short, lead: 86400, now: now),
                       ISO8601DateFormatter().date(from: "2026-01-01T06:00:00Z"))
        let revoked = try decoder.decode(SSHCertificate.self, from: Data(#"{"id": 3, "valid_to": "2026-02-01T00:00:00Z", "revoked": true}"#.utf8))
        XCTAssertNil(ExpiryNotifier.fireDate(for: revoked, lead: 86400, now: now))
    }

    func testCreatedAPIKeyDecoding() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let k = try decoder.decode(Envelope<CreatedAPIKey>.self, from: Data(#"{"data": {"key": "ucm_ak_abc", "id": 4, "name": "x", "key_prefix": "ucm_ak_abc", "permissions": ["read:ssh_cas"], "created_at": "2026-01-01T00:00:00Z", "expires_at": null}}"#.utf8)).data
        XCTAssertEqual(k.id, 4)
        XCTAssertEqual(k.key, "ucm_ak_abc")
        XCTAssertNil(k.expiresAt)
    }

    func testClientRejectsHTTP() {
        XCTAssertThrowsError(try UCMClient(server: "http://ucm.local", apiKey: "k", pinnedFingerprint: nil))
        XCTAssertNoThrow(try UCMClient(server: "ucm.local:8443/", apiKey: "k", pinnedFingerprint: nil))
        XCTAssertEqual(try UCMClient(server: "ucm.local:8443/", apiKey: "k", pinnedFingerprint: nil).baseURL.absoluteString,
                       "https://ucm.local:8443")
    }

    func testSanitize() {
        XCTAssertEqual(FileExport.sanitize("marc@host 1/2"), "marc@host_1_2")
        XCTAssertEqual(FileExport.sanitize(""), "ssh-cert")
        XCTAssertFalse(FileExport.sanitize("..").hasPrefix("."))
    }

    func testProfileDisplayName() {
        XCTAssertEqual(ServerProfile(server: "ucm.local:8443").displayName, "ucm.local")
        XCTAssertEqual(ServerProfile(name: "Labor", server: "x").displayName, "Labor")
    }
}
