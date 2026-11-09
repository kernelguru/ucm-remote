import Foundation

/// Legt Dateien im Dokumente-Ordner der App ab (sichtbar in „Dateien" → „Auf meinem iPhone" → „UCM Remote")
/// und liefert die URLs zum Teilen.
enum FileExport {
    struct Item {
        let name: String
        let content: String
    }

    static func write(_ items: [Item], folder: String) throws -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(sanitize(folder), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try items.map { item in
            let url = dir.appendingPathComponent(item.name)
            try Data(item.content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "ssh-cert" : cleaned
    }
}
