import CryptoKit
import Foundation

/// Fingerabdrücke eines X.509-Zertifikats (DER) für das Pinning auf Servern.
enum TLSPin {
    /// SHA-256 des ganzen Zertifikats, z. B. `AB:CD:…` (Format der App und des Windows-Skripts).
    static func certificateFingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// curl-Format für `--pinnedpubkey`: `sha256//<Base64 des SHA-256 über SubjectPublicKeyInfo>`.
    static func curlPublicKeyPin(der: Data) -> String? {
        guard let spki = subjectPublicKeyInfo(der: der) else { return nil }
        return "sha256//" + Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// Schneidet die SubjectPublicKeyInfo (inkl. Kopf) aus einem Zertifikat.
    /// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?, serial, signature,
    ///                             issuer, validity, subject, subjectPublicKeyInfo, … }, … }
    static func subjectPublicKeyInfo(der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let cert = element(bytes, at: 0), cert.tag == 0x30,
              let tbs = element(bytes, at: cert.contentStart), tbs.tag == 0x30 else { return nil }
        var fields: [Element] = []
        var i = tbs.contentStart
        while i < tbs.end, let e = element(bytes, at: i) {
            fields.append(e)
            i = e.end
        }
        let offset = fields.first?.tag == 0xA0 ? 1 : 0
        let index = offset + 5
        guard fields.count > index, fields[index].tag == 0x30 else { return nil }
        return Data(bytes[fields[index].start..<fields[index].end])
    }

    struct Element {
        let tag: UInt8
        let start: Int
        let contentStart: Int
        let end: Int
    }

    /// Liest Tag und Länge (DER, definite length) an Position `i`.
    static func element(_ b: [UInt8], at i: Int) -> Element? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var length = Int(b[i + 1])
        var header = 2
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n >= 1, n <= 4, i + 1 + n < b.count else { return nil }
            length = 0
            for k in 0..<n { length = (length << 8) | Int(b[i + 2 + k]) }
            header += n
        }
        let end = i + header + length
        guard end <= b.count else { return nil }
        return Element(tag: tag, start: i, contentStart: i + header, end: end)
    }
}
