import SwiftUI

struct CAListView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var cas: [SSHCA] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            ForEach(cas) { ca in
                NavigationLink {
                    CADetailView(ca: ca)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ca.type == .host ? "server.rack" : "person.2")
                            .foregroundStyle(Theme.mint).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(ca.displayName).font(.headline)
                            Text("\(ca.type.label)-CA · \(ca.keyType ?? "") · \(ca.certCount ?? 0) Zertifikate")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle("SSH-CAs")
        .refreshable { await load() }
        .overlay { if loading && cas.isEmpty { ProgressView() } }
        .task { await load() }
    }

    private func load() async {
        guard settings.isConfigured else {
            errorText = UCMError.notConfigured.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            cas = try await settings.client().listCAs()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct CADetailView: View {
    let ca: SSHCA

    var body: some View {
        Form {
            Section("CA") {
                LabeledContent("Typ", value: ca.type.label)
                LabeledContent("Schlüssel", value: ca.keyType ?? "–")
                if let ttl = ca.defaultTtl { LabeledContent("Standard-Gültigkeit", value: Self.duration(ttl)) }
                if let max = ca.maxTtl, max > 0 { LabeledContent("Max. Gültigkeit", value: Self.duration(max)) }
                if let fp = ca.fingerprint {
                    Text(fp).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let key = ca.publicKey {
                TextBlockSection(title: "Public Key", text: key, footer: nil)
                if ca.type == .user {
                    TextBlockSection(
                        title: "Server einrichten (sshd_config)",
                        text: "echo '\(key.trimmed)' > /etc/ssh/ucm_user_ca.pub\necho 'TrustedUserCAKeys /etc/ssh/ucm_user_ca.pub' >> /etc/ssh/sshd_config\nsystemctl reload ssh",
                        footer: "Danach akzeptiert der Server alle Benutzer-Zertifikate dieser CA.")
                } else {
                    TextBlockSection(
                        title: "Client einrichten (known_hosts)",
                        text: "@cert-authority * \(key.trimmed)",
                        footer: "In ~/.ssh/known_hosts eintragen, damit Host-Zertifikate dieser CA ohne Rückfrage akzeptiert werden.")
                }
            }
        }
        .appBackground()
        .navigationTitle(ca.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    static func duration(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}
