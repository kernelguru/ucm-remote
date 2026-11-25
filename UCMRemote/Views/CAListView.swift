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
        .task(id: settings.activeID) { await load() }
    }

    private func load() async {
        guard settings.isConfigured else {
            cas = []
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
    @EnvironmentObject private var settings: AppSettings
    let ca: SSHCA
    @State private var krlFiles: [URL] = []
    @State private var loadingKRL = false
    @State private var errorText: String?

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

            Section {
                NavigationLink {
                    ServerSetupView(ca: ca)
                } label: {
                    Label("Server einrichten", systemImage: "terminal")
                }
            } footer: {
                Text(ca.type == .user
                     ? "Erzeugt einen Befehl zum Einfügen in deine SSH-App: Der Server vertraut danach den Benutzer-Zertifikaten dieser CA und holt auf Wunsch die Sperrliste automatisch."
                     : "Erzeugt einen Befehl zum Einfügen in deine SSH-App, der den Server für Host-Zertifikate dieser CA vorbereitet.")
            }

            if ca.type == .user {
                Section {
                    if krlFiles.isEmpty {
                        Button {
                            Task { await loadKRL() }
                        } label: {
                            HStack {
                                Label("Sperrliste (KRL) laden", systemImage: "list.bullet.rectangle")
                                if loadingKRL { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(loadingKRL)
                    } else {
                        ShareLink(items: krlFiles) {
                            Label("Sperrliste teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                } footer: {
                    Text("Für Server ohne Zugang zu UCM: Datei z. B. nach /etc/ssh/ucm_revoked_keys.krl kopieren und in sshd_config „RevokedKeys“ setzen.")
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.callout) }
            }

            if let key = ca.publicKey {
                TextBlockSection(title: "Public Key", text: key, footer: nil)
                if ca.type == .user {
                    TextBlockSection(
                        title: "Von Hand einrichten (sshd_config)",
                        text: "echo '\(key.trimmed)' > /etc/ssh/ucm_user_ca.pub\necho 'TrustedUserCAKeys /etc/ssh/ucm_user_ca.pub' >> /etc/ssh/sshd_config\nsystemctl reload ssh",
                        footer: "Kurzform ohne Prüfung. Steht in sshd_config ein Match-Block, die Zeile darüber einfügen.")
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
        .onDisappear { FileExport.removeTemporary(krlFiles) }
    }

    private func loadKRL() async {
        loadingKRL = true
        defer { loadingKRL = false }
        do {
            let data = try await settings.client().krl(caID: ca.id)
            krlFiles = [try FileExport.writeTemporary(data: data, name: "ucm_revoked_keys.krl")]
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func duration(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}
