import Foundation

/// Gemeinsame Felder für Signieren und Erzeugen.
struct SignRequest {
    var caID: Int
    var certType: SSHCertType
    var principals: [String]
    var validity: Validity
    var keyID: String
    var descr: String

    var body: [String: Any] {
        var b: [String: Any] = [
            "ca_id": caID,
            "cert_type": certType.rawValue,
            "principals": principals,
        ]
        if validity != .caDefault { b["validity_seconds"] = validity.rawValue }
        if !keyID.trimmed.isEmpty { b["key_id"] = keyID.trimmed }
        if !descr.trimmed.isEmpty { b["descr"] = descr.trimmed }
        return b
    }

    static func parsePrincipals(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }
}
