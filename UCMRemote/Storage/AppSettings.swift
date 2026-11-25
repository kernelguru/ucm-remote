import Foundation

/// Ein UCM-Server. Der API-Schlüssel liegt getrennt im Schlüsselbund.
struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var server: String = ""
    /// SHA-256 des TLS-Zertifikats (AA:BB:…), falls der Server nicht systemweit vertrauenswürdig ist.
    var pinnedFingerprint: String = ""

    var displayName: String {
        if let n = name.trimmed.nilIfEmpty { return n }
        let s = server.trimmed
        let withScheme = s.contains("://") ? s : "https://" + s
        return URL(string: withScheme)?.host ?? (s.nilIfEmpty ?? "Neuer Server")
    }
}

/// API-Schlüssel, den die App für die automatische Sperrliste angelegt hat (nur `read:ssh_cas`).
struct StoredKRLKey: Codable, Equatable {
    let id: Int
    let key: String
    let prefix: String?
    let expiresAt: String?
    let created: Date
}

/// Server-Profile, aktives Profil und API-Schlüssel.
final class AppSettings: ObservableObject {
    @Published private(set) var profiles: [ServerProfile] = []
    @Published var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Self.activeKey) }
    }
    @Published private var apiKeys: [UUID: String] = [:]

    private let defaults: UserDefaults
    private static let profilesKey = "profiles"
    private static let activeKey = "activeProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey),
           let list = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = list
        }
        migrateLegacySettings()
        for p in profiles { apiKeys[p.id] = Keychain.load(account: Keychain.apiKeyAccount(p.id)) }
        let stored = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        activeID = profiles.contains { $0.id == stored } ? stored : profiles.first?.id
    }

    /// Version 0.1 kannte nur einen Server (AppStorage „server“ + Schlüsselbund-Konto „default“).
    private func migrateLegacySettings() {
        guard profiles.isEmpty, let old = defaults.string(forKey: "server")?.trimmed, !old.isEmpty else { return }
        let profile = ServerProfile(server: old, pinnedFingerprint: defaults.string(forKey: "pinnedFingerprint") ?? "")
        let key = Keychain.load(account: Keychain.legacyAccount)
        Keychain.save(key, account: Keychain.apiKeyAccount(profile.id))
        Keychain.delete(account: Keychain.legacyAccount)
        profiles = [profile]
        persist()
        defaults.set(profile.id.uuidString, forKey: Self.activeKey)
        defaults.removeObject(forKey: "server")
        defaults.removeObject(forKey: "pinnedFingerprint")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
    }

    // MARK: Aktives Profil

    var active: ServerProfile? { profiles.first { $0.id == activeID } }
    var apiKey: String { activeID.flatMap { apiKeys[$0] } ?? "" }
    var isConfigured: Bool { active.map { !$0.server.trimmed.isEmpty } == true && !apiKey.isEmpty }

    func apiKey(for profile: ServerProfile) -> String { apiKeys[profile.id] ?? "" }

    func client() throws -> UCMClient {
        guard let p = active else { throw UCMError.notConfigured }
        return try client(for: p)
    }

    func client(for profile: ServerProfile) throws -> UCMClient {
        try UCMClient(server: profile.server, apiKey: apiKey(for: profile), pinnedFingerprint: profile.pinnedFingerprint)
    }

    // MARK: Bearbeiten

    func save(_ profile: ServerProfile, apiKey: String) {
        var p = profile
        p.server = p.server.trimmed
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        let key = apiKey.trimmed
        apiKeys[p.id] = key
        Keychain.save(key, account: Keychain.apiKeyAccount(p.id))
        persist()
        if activeID == nil { activeID = p.id }
    }

    func setPinnedFingerprint(_ fp: String, for id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].pinnedFingerprint = fp
        persist()
    }

    func delete(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        apiKeys[profile.id] = nil
        Keychain.delete(account: Keychain.apiKeyAccount(profile.id))
        Keychain.delete(account: Keychain.krlKeyAccount(profile.id))
        ExpiryNotifier.removeAll(profileID: profile.id)
        persist()
        if activeID == profile.id { activeID = profiles.first?.id }
    }

    // MARK: Schlüssel für die Sperrliste

    func krlKey(for profile: ServerProfile) -> StoredKRLKey? {
        let raw = Keychain.load(account: Keychain.krlKeyAccount(profile.id))
        guard !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(StoredKRLKey.self, from: Data(raw.utf8))
    }

    func saveKRLKey(_ key: StoredKRLKey, for profile: ServerProfile) {
        guard let data = try? JSONEncoder().encode(key) else { return }
        Keychain.save(String(decoding: data, as: UTF8.self), account: Keychain.krlKeyAccount(profile.id))
        objectWillChange.send()
    }

    func forgetKRLKey(for profile: ServerProfile) {
        Keychain.delete(account: Keychain.krlKeyAccount(profile.id))
        objectWillChange.send()
    }
}
