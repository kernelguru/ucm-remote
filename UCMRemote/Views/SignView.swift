import SwiftUI
import UniformTypeIdentifiers

enum KeySource: String, CaseIterable, Identifiable {
    case local, existing, server
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "Auf dem iPhone erzeugen"
        case .existing: return "Vorhandenen Public Key signieren"
        case .server: return "Von UCM erzeugen lassen"
        }
    }
}

/// Ergebnis einer Ausstellung, für die Ergebnisansicht.
struct IssueResult: Identifiable {
    let id = UUID()
    let certificate: SSHCertificate
    let privateKey: String?
    let publicKey: String
    let fileBase: String
}

struct SignView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var cas: [SSHCA] = []
    @State private var caID: Int?
    @State private var certType: SSHCertType = .user
    @State private var principals = ""
    @State private var keyID = ""
    @State private var descr = ""
    @State private var validity: Validity = .day
    @State private var source: KeySource = .local
    @State private var serverKeyType: SSHKeyType = .ed25519
    @State private var publicKey = ""
    @State private var importing = false

    @State private var loading = false
    @State private var working = false
    @State private var errorText: String?
    @State private var result: IssueResult?

    private var selectedCA: SSHCA? { cas.first { $0.id == caID } }
    private var principalList: [String] { SignRequest.parsePrincipals(principals) }

    private var canSubmit: Bool {
        guard caID != nil, !principalList.isEmpty, !working else { return false }
        if source == .existing { return publicKey.trimmed.hasPrefix("ssh-") || publicKey.trimmed.hasPrefix("ecdsa-") }
        return true
    }

    var body: some View {
        Form {
            Section("Zertifizierungsstelle") {
                if loading {
                    ProgressView()
                } else if cas.isEmpty {
                    Text("Keine SSH-CA gefunden. Lege in UCM unter „SSH“ eine CA an.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("SSH-CA", selection: $caID) {
                        ForEach(cas) { ca in
                            Text("\(ca.displayName) (\(ca.type.label))").tag(Optional(ca.id))
                        }
                    }
                    if let ca = selectedCA, ca.allowAnyPrincipal != true, let allowed = ca.allowedPrincipals, !allowed.isEmpty {
                        Text("Erlaubte Principals: \(allowed.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Typ", selection: $certType) {
                    ForEach(SSHCertType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(certType == .user ? "Principals, z. B. root, marc" : "Hostnamen, z. B. server.lan", text: $principals)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key-ID (optional)", text: $keyID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Beschreibung (optional)", text: $descr)
                Picker("Gültigkeit", selection: $validity) {
                    ForEach(Validity.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Zertifikat")
            } footer: {
                Text(certType == .user
                     ? "Principals = Benutzernamen, mit denen du dich am Server anmelden darfst."
                     : "Principals = Namen, unter denen der Host erreichbar ist.")
            }

            Section {
                Picker("Schlüssel", selection: $source) {
                    ForEach(KeySource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                switch source {
                case .local:
                    Label("Ed25519 – der private Schlüssel verlässt das iPhone nicht.", systemImage: "lock.iphone")
                        .font(.callout)
                case .server:
                    Picker("Schlüsseltyp", selection: $serverKeyType) {
                        ForEach(SSHKeyType.allCases) { Text($0.label).tag($0) }
                    }
                    Label("UCM erzeugt den Schlüssel und gibt ihn einmalig zurück.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                case .existing:
                    TextEditor(text: $publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Einfügen") { publicKey = UIPasteboard.general.string ?? publicKey }
                        Spacer()
                        Button(".pub-Datei wählen") { importing = true }
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Schlüssel")
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.callout) }
            }

            Section {
                Button {
                    Task { await issue() }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView() } else { Label("Zertifikat ausstellen", systemImage: "signature") }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .appBackground()
        .navigationTitle("SSH-Zertifikat")
        .toolbar {
            Button { Task { await loadCAs() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .task { if cas.isEmpty { await loadCAs() } }
        .onChange(of: caID) { _ in
            if let ca = selectedCA { certType = ca.type }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText, .item]) { res in
            guard case .success(let url) = res else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { publicKey = text.trimmed }
        }
        .sheet(item: $result) { r in
            NavigationStack { IssueResultView(result: r) }
        }
    }

    private func loadCAs() async {
        guard settings.isConfigured else {
            errorText = UCMError.notConfigured.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            cas = try await settings.client().listCAs()
            if caID == nil || !cas.contains(where: { $0.id == caID }) { caID = cas.first?.id }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func issue() async {
        guard let caID else { return }
        working = true
        errorText = nil
        defer { working = false }
        let request = SignRequest(caID: caID, certType: certType, principals: principalList,
                                  validity: validity, keyID: keyID, descr: descr)
        do {
            let client = try settings.client()
            switch source {
            case .local:
                let comment = keyID.trimmed.nilIfEmpty ?? principalList.first ?? "ucm-remote"
                let key = LocalKey(comment: comment)
                let cert = try await client.sign(publicKey: key.publicKeyLine, request: request)
                result = IssueResult(certificate: cert, privateKey: key.openSSHPrivateKey,
                                     publicKey: key.publicKeyLine, fileBase: "id_ed25519")
            case .existing:
                let pub = publicKey.trimmed
                let cert = try await client.sign(publicKey: pub, request: request)
                result = IssueResult(certificate: cert, privateKey: nil, publicKey: pub,
                                     fileBase: Self.fileBase(forPublicKey: pub))
            case .server:
                let cert = try await client.generate(keyType: serverKeyType, request: request)
                result = IssueResult(certificate: cert, privateKey: cert.privateKey,
                                     publicKey: cert.publicKey ?? "", fileBase: serverKeyType.fileBase)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func fileBase(forPublicKey key: String) -> String {
        if key.hasPrefix("ssh-ed25519") { return "id_ed25519" }
        if key.hasPrefix("ecdsa-") { return "id_ecdsa" }
        if key.hasPrefix("ssh-rsa") { return "id_rsa" }
        return "id_key"
    }
}
