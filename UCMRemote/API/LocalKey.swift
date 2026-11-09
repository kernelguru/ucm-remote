import CryptoKit
import Foundation
import Security

/// Ed25519-Schlüsselpaar, das auf dem iPhone erzeugt wird. Der private Schlüssel verlässt
/// das Gerät nicht; an UCM geht nur der Public Key zum Signieren.
struct LocalKey {
    let privateKey: Curve25519.Signing.PrivateKey
    let comment: String

    init(comment: String) {
        self.privateKey = Curve25519.Signing.PrivateKey()
        self.comment = comment
    }

    private var publicRaw: Data { privateKey.publicKey.rawRepresentation }

    /// SSH-Wire-Format des Public Keys: string "ssh-ed25519" + string pub(32)
    private var publicBlob: Data {
        var d = Data()
        d.appendSSHString("ssh-ed25519")
        d.appendSSHString(publicRaw)
        return d
    }

    /// Zeile für `id_ed25519.pub` bzw. zum Signieren.
    var publicKeyLine: String {
        "ssh-ed25519 \(publicBlob.base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)")
    }

    /// Unverschlüsselter privater Schlüssel im Format `openssh-key-v1` (wie `ssh-keygen -t ed25519`).
    var openSSHPrivateKey: String {
        var checkBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &checkBytes)
        let check = Data(checkBytes)

        var priv = Data()
        priv.append(check)
        priv.append(check)
        priv.appendSSHString("ssh-ed25519")
        priv.appendSSHString(publicRaw)
        // OpenSSH speichert 64 Bytes: 32 Byte Seed + 32 Byte Public Key
        priv.appendSSHString(privateKey.rawRepresentation + publicRaw)
        priv.appendSSHString(comment)
        var pad: UInt8 = 1
        while priv.count % 8 != 0 {
            priv.append(pad)
            pad += 1
        }

        var d = Data("openssh-key-v1".utf8)
        d.append(0)
        d.appendSSHString("none")   // cipher
        d.appendSSHString("none")   // kdf
        d.appendSSHString(Data())   // kdf options
        d.appendUInt32(1)           // Anzahl Schlüssel
        d.appendSSHString(publicBlob)
        d.appendSSHString(priv)

        let b64 = d.base64EncodedString()
        var lines: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<end]))
            idx = end
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}

extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    mutating func appendSSHString(_ s: String) {
        appendSSHString(Data(s.utf8))
    }

    mutating func appendSSHString(_ d: Data) {
        appendUInt32(UInt32(d.count))
        append(d)
    }
}
