import Foundation

/// Hülle aller UCM-Antworten: `{ "data": ..., "message": ..., "meta": ... }`
struct Envelope<T: Decodable>: Decodable {
    let data: T
}

/// Fehlerkörper (RFC 7807 + Altfelder) der UCM-API.
struct ProblemBody: Decodable {
    let detail: String?
    let message: String?

    var text: String? { detail ?? message }
}

/// SSH-Zertifizierungsstelle (`GET /api/v2/ssh/cas`).
struct SSHCA: Decodable, Identifiable, Hashable {
    let id: Int
    let descr: String?
    let caType: String?          // "user" oder "host"
    let publicKey: String?
    let keyType: String?
    let fingerprint: String?
    let defaultTtl: Int?
    let maxTtl: Int?
    let allowedPrincipals: [String]?
    let allowAnyPrincipal: Bool?
    let allowCustomKeyId: Bool?
    let certCount: Int?

    var displayName: String { descr?.nilIfEmpty ?? "SSH-CA \(id)" }
    var type: SSHCertType { SSHCertType(rawValue: caType ?? "user") ?? .user }
}

/// SSH-Zertifikat (`/api/v2/ssh/certificates`).
struct SSHCertificate: Decodable, Identifiable, Hashable {
    let id: Int
    let descr: String?
    let sshCaId: Int?
    let caName: String?
    let certType: String?
    let keyId: String?
    let publicKey: String?
    let certificate: String?
    let principals: [String]?
    let serial: Int?
    let validFrom: String?
    let validTo: String?
    let keyType: String?
    let fingerprint: String?
    let revoked: Bool?
    let status: String?
    /// Nur bei `/generate`: privater Schlüssel im OpenSSH-Format (einmalig).
    let privateKey: String?

    var displayName: String { keyId?.nilIfEmpty ?? descr?.nilIfEmpty ?? "Zertifikat \(id)" }
    var principalText: String { (principals ?? []).joined(separator: ", ") }
    var validToDate: Date? { validTo.flatMap(Date.fromUCM) }
    var validFromDate: Date? { validFrom.flatMap(Date.fromUCM) }
}

/// Antwort von `GET /api/v2/ssh/certificates/{id}/export`.
struct SSHExport: Decodable {
    let certificate: String?
    let publicKey: String?
    let caPublicKey: String?
    let keyId: String?
}

enum SSHCertType: String, CaseIterable, Identifiable {
    case user, host
    var id: String { rawValue }
    var label: String { self == .user ? "Benutzer" : "Host" }
}

/// Schlüsseltypen, die UCM beim Erzeugen kennt.
enum SSHKeyType: String, CaseIterable, Identifiable {
    case ed25519
    case ecdsaP256 = "ecdsa-p256"
    case ecdsaP384 = "ecdsa-p384"
    case rsa
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .rsa: return "RSA"
        }
    }
    /// Üblicher Dateiname des Schlüssels.
    var fileBase: String {
        switch self {
        case .ed25519: return "id_ed25519"
        case .ecdsaP256, .ecdsaP384: return "id_ecdsa"
        case .rsa: return "id_rsa"
        }
    }
}

/// Laufzeit-Vorgaben für Zertifikate.
enum Validity: Int, CaseIterable, Identifiable {
    case hour = 3600
    case hours8 = 28800
    case day = 86400
    case week = 604800
    case month = 2_592_000
    case quarter = 7_776_000
    case year = 31_536_000
    case caDefault = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .hour: return "1 Stunde"
        case .hours8: return "8 Stunden"
        case .day: return "1 Tag"
        case .week: return "1 Woche"
        case .month: return "30 Tage"
        case .quarter: return "90 Tage"
        case .year: return "1 Jahr"
        case .caDefault: return "Standard der CA"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Date {
    static func fromUCM(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
