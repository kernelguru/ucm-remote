import XCTest
@testable import UCMRemote

final class LocalKeyTests: XCTestCase {
    /// Liest SSH-Strings (uint32 Länge + Daten) aus `data` ab `offset`.
    private func readString(_ data: [UInt8], _ offset: inout Int) -> [UInt8] {
        let n = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }

    func testPublicKeyLine() throws {
        let key = LocalKey(comment: "marc")
        let parts = key.publicKeyLine.split(separator: " ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        XCTAssertEqual(parts[2], "marc")
        let blob = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
        var o = 0
        let bytes = [UInt8](blob)
        XCTAssertEqual(String(decoding: readString(bytes, &o), as: UTF8.self), "ssh-ed25519")
        XCTAssertEqual(readString(bytes, &o), [UInt8](key.privateKey.publicKey.rawRepresentation))
        XCTAssertEqual(o, bytes.count)
    }

    func testOpenSSHPrivateKeyFormat() throws {
        let key = LocalKey(comment: "test")
        let pem = key.openSSHPrivateKey
        XCTAssertTrue(pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        let body = pem.split(separator: "\n").dropFirst().dropLast().joined()
        XCTAssertTrue(pem.split(separator: "\n").allSatisfy { $0.count <= 70 })
        let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: body)))
        let magic = Array("openssh-key-v1".utf8) + [0]
        XCTAssertEqual(Array(bytes.prefix(magic.count)), magic)
        var o = magic.count
        XCTAssertEqual(String(decoding: readString(bytes, &o), as: UTF8.self), "none")
        XCTAssertEqual(String(decoding: readString(bytes, &o), as: UTF8.self), "none")
        XCTAssertEqual(readString(bytes, &o), [])
        o += 4 // Anzahl Schlüssel
        _ = readString(bytes, &o) // Public Key
        let priv = readString(bytes, &o)
        XCTAssertEqual(o, bytes.count)
        XCTAssertEqual(priv.count % 8, 0)
        XCTAssertEqual(Array(priv[0..<4]), Array(priv[4..<8]), "Prüfwerte müssen gleich sein")
        var p = 8
        XCTAssertEqual(String(decoding: readString(priv, &p), as: UTF8.self), "ssh-ed25519")
        let pub = readString(priv, &p)
        let secret = readString(priv, &p)
        XCTAssertEqual(secret.count, 64)
        XCTAssertEqual(Array(secret[0..<32]), [UInt8](key.privateKey.rawRepresentation))
        XCTAssertEqual(Array(secret[32..<64]), pub)
        XCTAssertEqual(String(decoding: readString(priv, &p), as: UTF8.self), "test")
        let padding = Array(priv[p...])
        XCTAssertEqual(padding, (0..<padding.count).map { UInt8($0 + 1) })
    }
}
