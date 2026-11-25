import Foundation

/// Dateien zum Teilen.
/// - `write` legt Zertifikate und Public Keys dauerhaft im Dokumente-Ordner ab
///   (sichtbar in „Dateien“ → „Auf meinem iPhone“ → „UCM Remote“).
/// - `writeTemporary` legt Geheimnisse (private Schlüssel, Skripte mit API-Schlüssel) nur kurz in
///   einem temporären Ordner ab. Er wird mit `removeTemporary` bzw. beim nächsten Start gelöscht.
enum FileExport {
    struct Item {
        let name: String
        let content: String
    }

    static func write(_ items: [Item], folder: String) throws -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(sanitize(folder), isDirectory: true)
        return try write(items, to: dir)
    }

    static func writeTemporary(_ items: [Item]) throws -> [URL] {
        let dir = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try write(items, to: dir)
    }

    static func writeTemporary(data: Data, name: String) throws -> URL {
        let dir = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sanitize(name))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Löscht die temporären Dateien (den Ordner, in dem `url` liegt).
    static func removeTemporary(_ urls: [URL]) {
        let root = temporaryRoot.standardizedFileURL.path
        for dir in Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL }) where dir.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Beim App-Start: Reste löschen, die ein Absturz oder Beenden hinterlassen hat.
    static func cleanTemporary() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    }

    private static func write(_ items: [Item], to dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try items.map { item in
            let url = dir.appendingPathComponent(sanitize(item.name))
            try Data(item.content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "ssh-cert" + cleaned : cleaned
    }
}
