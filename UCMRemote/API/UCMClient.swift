import CryptoKit
import Foundation
import Security

enum UCMError: LocalizedError {
    case notConfigured
    case invalidURL
    case untrustedCertificate(fingerprint: String)
    case http(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Bitte zuerst Server-Adresse und API-Schlüssel in den Einstellungen eintragen."
        case .invalidURL:
            return "Die Server-Adresse ist ungültig."
        case .untrustedCertificate(let fp):
            return "Das TLS-Zertifikat des Servers ist nicht vertrauenswürdig.\nSHA-256: \(fp)"
        case .http(let status, let message):
            switch status {
            case 401: return "Nicht angemeldet (401): \(message)\nAPI-Schlüssel prüfen."
            case 403: return "Keine Berechtigung (403): \(message)"
            default: return "Serverfehler \(status): \(message)"
            }
        case .decoding(let what):
            return "Unerwartete Antwort vom Server (\(what))."
        }
    }
}

/// Prüft das Server-Zertifikat. Ist es nicht über die Systemvertrauensstellung gültig,
/// wird es nur akzeptiert, wenn sein SHA-256-Fingerabdruck dem gespeicherten entspricht (Pinning).
final class TrustDelegate: NSObject, URLSessionDelegate {
    private let pinned: String?
    private let lock = NSLock()
    private var _rejectedFingerprint: String?

    var rejectedFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return _rejectedFingerprint
    }

    init(pinned: String?) {
        self.pinned = pinned?.nilIfEmpty
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = Self.fingerprint(of: leaf)
        if let pinned, pinned == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        lock.lock(); _rejectedFingerprint = fingerprint; lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    static func fingerprint(of cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Zugriff auf die REST-API v2 von Ultimate CA Manager mit API-Schlüssel (`X-API-Key`).
struct UCMClient {
    let baseURL: URL
    let apiKey: String
    let pinnedFingerprint: String?

    init(server: String, apiKey: String, pinnedFingerprint: String?) throws {
        var s = server.trimmed
        guard !s.isEmpty, !apiKey.isEmpty else { throw UCMError.notConfigured }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { throw UCMError.invalidURL }
        self.baseURL = url
        self.apiKey = apiKey.trimmed
        self.pinnedFingerprint = pinnedFingerprint
    }

    // MARK: Endpunkte

    func listCAs() async throws -> [SSHCA] {
        try await decode(send("GET", "/api/v2/ssh/cas", query: [URLQueryItem(name: "per_page", value: "100")]))
    }

    func listCertificates(search: String = "") async throws -> [SSHCertificate] {
        var items = [URLQueryItem(name: "per_page", value: "100")]
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        return try await decode(send("GET", "/api/v2/ssh/certificates", query: items))
    }

    /// Signiert einen vorhandenen OpenSSH-Public-Key (`POST /api/v2/ssh/certificates`).
    func sign(publicKey: String, request: SignRequest) async throws -> SSHCertificate {
        var body = request.body
        body["public_key"] = publicKey
        return try await decode(send("POST", "/api/v2/ssh/certificates", json: body))
    }

    /// Lässt UCM ein Schlüsselpaar erzeugen und signieren (`POST /api/v2/ssh/certificates/generate`).
    /// Der private Schlüssel kommt nur dieses eine Mal zurück.
    func generate(keyType: SSHKeyType, request: SignRequest) async throws -> SSHCertificate {
        var body = request.body
        body["key_type"] = keyType.rawValue
        return try await decode(send("POST", "/api/v2/ssh/certificates/generate", json: body))
    }

    func export(certificateID: Int) async throws -> SSHExport {
        try await decode(send("GET", "/api/v2/ssh/certificates/\(certificateID)/export"))
    }

    func revoke(certificateID: Int) async throws {
        _ = try await send("POST", "/api/v2/ssh/certificates/\(certificateID)/revoke", json: ["reason": "unspecified"])
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      json: [String: Any]? = nil) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw UCMError.invalidURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw UCMError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let delegate = TrustDelegate(pinned: pinnedFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if let fp = delegate.rejectedFingerprint { throw UCMError.untrustedCertificate(fingerprint: fp) }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw UCMError.decoding("keine HTTP-Antwort") }
        guard (200..<300).contains(http.statusCode) else {
            let problem = try? JSONDecoder().decode(ProblemBody.self, from: data)
            let text = problem?.text ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw UCMError.http(status: http.statusCode, message: text)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Envelope<T>.self, from: data).data
        } catch {
            throw UCMError.decoding(String(describing: T.self))
        }
    }
}
