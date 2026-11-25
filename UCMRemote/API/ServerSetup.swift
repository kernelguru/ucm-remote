import Foundation

enum SetupPlatform: String, CaseIterable, Identifiable {
    case linux, windows
    var id: String { rawValue }
    var label: String { self == .linux ? "Linux" : "Windows" }
    var ucmParameter: String { rawValue }
    var fileExtension: String { self == .linux ? "sh" : "ps1" }
}

/// Wie sshd Principals im Zertifikat mit Benutzerkonten abgleicht.
enum PrincipalsMode: String, CaseIterable, Identifiable {
    case username, file, keep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .username: return "Principal = Benutzername"
        case .file: return "Principals-Datei je Benutzer"
        case .keep: return "Wie von UCM eingerichtet"
        }
    }
    var explanation: String {
        switch self {
        case .username:
            return "OpenSSH-Standard: Ein Zertifikat mit dem Principal „root“ erlaubt die Anmeldung als root. Die von UCM gesetzte AuthorizedPrincipalsFile-Zeile wird entfernt."
        case .file:
            return "Je Benutzer eine Datei in auth_principals. Eine Zeile pro Benutzer, z. B. „root: marc, admin“."
        case .keep:
            return "UCM setzt AuthorizedPrincipalsFile. Ohne Datei je Benutzer ist dann keine Anmeldung per Zertifikat möglich."
        }
    }
}

/// Wie der Server beim Abholen der Sperrliste das TLS-Zertifikat von UCM prüft.
enum KRLTrustMode: String, CaseIterable, Identifiable {
    case pinned, system
    var id: String { rawValue }
    var label: String { self == .pinned ? "Fester Schlüssel (Pinning)" : "System-Zertifizierungsstellen" }
}

/// Angaben für die automatische Sperrliste.
struct KRLSettings {
    var serverURL: String
    var caID: Int
    var apiKey: String
    var intervalMinutes: Int
    /// curl-Pin (`sha256//…`), nil = Prüfung über die System-CAs.
    var curlPin: String?
    /// SHA-256 des Server-Zertifikats (AA:BB:…), nil = Prüfung über die System-CAs.
    var certificateFingerprint: String?
}

/// Baut aus dem Skript von UCM und den Vorlagen der App den Befehl zum Einfügen ins Terminal.
enum ServerSetup {
    enum Failure: LocalizedError {
        case missingTemplate(String)
        case unsafe(String)
        var errorDescription: String? {
            switch self {
            case .missingTemplate(let n): return "Vorlage \(n) fehlt in der App."
            case .unsafe(let what): return "Das Skript kann nicht sicher eingebettet werden (\(what))."
            }
        }
    }

    static let outerTerminator = "UCM_REMOTE_EOF"
    static let innerTerminator = "UCM_CA_SCRIPT_EOF"

    // MARK: Skripte

    /// Vollständiges Shell-Skript (zum Teilen als .sh oder zum Einbetten in den Einfüge-Befehl).
    static func linuxScript(ucmScript: String, ca: SSHCA, principalsMode: PrincipalsMode,
                            principals: String, krl: KRLSettings?) throws -> String {
        let script = ucmScript.replacingOccurrences(of: "\r\n", with: "\n")
        for t in [outerTerminator, innerTerminator] where hasLine(script, t) {
            throw Failure.unsafe("Endmarke im UCM-Skript")
        }
        if let krl { try validate(krl) }
        var values: [String: String] = [
            "__CA_NAME__": commentSafe(ca.displayName),
            "__CA_TYPE__": ca.type.rawValue,
            "__PRINCIPALS_MODE__": ca.type == .user ? principalsMode.rawValue : PrincipalsMode.keep.rawValue,
            "__PRINCIPALS_Q__": shellQuote(principals.replacingOccurrences(of: "\r", with: "")),
            "__KRL_ENABLED__": krl != nil && ca.type == .user ? "1" : "0",
            "__KRL_INTERVAL__": String(krl?.intervalMinutes ?? 15),
            "__CA_ID__": String(ca.id),
            "__UCM_URL_Q__": shellQuote(krl?.serverURL ?? ""),
            "__PIN_Q__": shellQuote(krl?.curlPin ?? ""),
            "__API_KEY_Q__": shellQuote(krl?.apiKey ?? ""),
        ]
        values["__UCM_SCRIPT__"] = script.hasSuffix("\n") ? String(script.dropLast()) : script
        return try render("server-setup-linux", ext: "sh", values: values)
    }

    /// Vollständiges PowerShell-Skript (nur ASCII, damit es über jede Konsole eingefügt werden kann).
    static func windowsScript(ucmScript: String, ca: SSHCA, principalsMode: PrincipalsMode,
                              principals: String, krl: KRLSettings?) throws -> String {
        if let krl { try validate(krl) }
        let updater = try template("krl-update-windows", ext: "ps1")
        let values: [String: String] = [
            "__CA_NAME__": commentSafe(ca.displayName),
            "__CA_TYPE__": ca.type.rawValue,
            "__PRINCIPALS_MODE__": ca.type == .user ? principalsMode.rawValue : PrincipalsMode.keep.rawValue,
            "__PRINCIPALS_PSQ__": psQuote(asciiOnly(principals.replacingOccurrences(of: "\r", with: ""))),
            "__KRL_ENABLED__": krl != nil && ca.type == .user ? "1" : "0",
            "__KRL_INTERVAL__": String(krl?.intervalMinutes ?? 15),
            "__CA_ID__": String(ca.id),
            "__UCM_URL_PSQ__": psQuote(krl?.serverURL ?? ""),
            "__PIN_PSQ__": psQuote(krl?.certificateFingerprint ?? ""),
            "__API_KEY_PSQ__": psQuote(krl?.apiKey ?? ""),
            "__UCM_SCRIPT_B64__": Data(ucmScript.utf8).base64EncodedString(),
            "__UPDATER_B64__": Data(updater.utf8).base64EncodedString(),
        ]
        let script = try render("server-setup-windows", ext: "ps1", values: values)
        guard script.unicodeScalars.allSatisfy(\.isASCII) else { throw Failure.unsafe("Nicht-ASCII-Zeichen") }
        return script
    }

    static func removalScript(platform: SetupPlatform) throws -> String {
        platform == .linux ? try template("krl-remove-linux", ext: "sh") : try template("krl-remove-windows", ext: "ps1")
    }

    // MARK: Einfüge-Befehle

    /// Ein Block zum Einfügen in eine POSIX-Shell (bash, zsh, sh). Das Skript wird zuerst komplett in
    /// eine temporäre Datei geschrieben und dann ausgeführt. Das führende Leerzeichen hält den
    /// Befehl bei `HISTCONTROL=ignorespace` aus der Shell-History.
    static func linuxPasteCommand(script: String, sudo: Bool) throws -> String {
        guard !hasLine(script, outerTerminator) else { throw Failure.unsafe("Endmarke im Skript") }
        let shell = sudo ? "sudo sh" : "sh"
        let body = script.hasSuffix("\n") ? script : script + "\n"
        return " \(shell) -c 'f=$(mktemp) || exit 1; cat >\"$f\"; sh \"$f\" </dev/null; r=$?; rm -f \"$f\"; exit $r' <<'\(outerTerminator)'\n"
            + body + outerTerminator + "\n"
    }

    /// Ein Block zum Einfügen in eine PowerShell, die als Administrator läuft.
    static func windowsPasteCommand(script: String) throws -> String {
        let lines = script.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard !lines.contains(where: { $0.hasPrefix("'@") }) else { throw Failure.unsafe("Here-String-Ende im Skript") }
        let body = script.hasSuffix("\n") ? String(script.dropLast()) : script
        return "$ucmSetup = @'\n" + body + "\n'@\n"
            + "$ucmFile = Join-Path $env:TEMP ('ucm-remote-' + [guid]::NewGuid().ToString() + '.ps1'); "
            + "[IO.File]::WriteAllText($ucmFile, $ucmSetup, (New-Object System.Text.UTF8Encoding $true)); "
            + "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ucmFile; "
            + "Remove-Item -Force $ucmFile; Remove-Variable ucmSetup, ucmFile\n"
    }

    // MARK: Hilfen

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// PowerShell behandelt auch typografische Apostrophe als Anführungszeichen.
    static func psQuote(_ s: String) -> String {
        var out = "'"
        for ch in s {
            if "'\u{2018}\u{2019}\u{201A}\u{201B}".contains(ch) { out.append(ch) }
            out.append(ch)
        }
        return out + "'"
    }

    static func commentSafe(_ s: String) -> String {
        asciiOnly(s).filter { $0 != "\n" && $0 != "\r" }
    }

    static func asciiOnly(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0.isASCII ? $0 : "_" }))
    }

    private static func hasLine(_ text: String, _ line: String) -> Bool {
        text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }

    private static func validate(_ krl: KRLSettings) throws {
        let keyChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !krl.apiKey.isEmpty, krl.apiKey.unicodeScalars.allSatisfy(keyChars.contains) else {
            throw Failure.unsafe("API-Schlüssel")
        }
        guard krl.serverURL.hasPrefix("https://"),
              krl.serverURL.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { throw Failure.unsafe("Server-Adresse") }
        guard [5, 15, 30, 60].contains(krl.intervalMinutes) else { throw Failure.unsafe("Intervall") }
    }

    private static func template(_ name: String, ext: String) throws -> String {
        guard let url = Bundle(for: AppSettings.self).url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.missingTemplate("\(name).\(ext)")
        }
        return text
    }

    private static func render(_ name: String, ext: String, values: [String: String]) throws -> String {
        var text = try template(name, ext: ext)
        // Das UCM-Skript zuletzt einsetzen, damit Platzhalter darin nicht ersetzt werden.
        let late: Set<String> = ["__UCM_SCRIPT__"]
        for (k, v) in values where !late.contains(k) { text = text.replacingOccurrences(of: k, with: v) }
        for k in late { if let v = values[k] { text = text.replacingOccurrences(of: k, with: v) } }
        return text
    }
}
