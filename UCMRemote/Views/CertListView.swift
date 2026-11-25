import SwiftUI

struct CertListView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var certs: [SSHCertificate] = []
    @State private var search = ""
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            if certs.isEmpty && !loading && errorText == nil {
                Text("Keine SSH-Zertifikate").foregroundStyle(.secondary)
            }
            ForEach(certs) { cert in
                NavigationLink {
                    CertDetailView(cert: cert) { updated in
                        if let i = certs.firstIndex(where: { $0.id == updated.id }) { certs[i] = updated }
                    }
                } label: {
                    CertRow(cert: cert)
                }
            }
        }
        .appBackground()
        .navigationTitle("Zertifikate")
        .searchable(text: $search, prompt: "Key-ID oder Principal")
        .onSubmit(of: .search) { Task { await load() } }
        .refreshable { await load() }
        .overlay { if loading && certs.isEmpty { ProgressView() } }
        .task(id: settings.activeID) { await load() }
    }

    private func load() async {
        guard settings.isConfigured, let profile = settings.active else {
            certs = []
            errorText = UCMError.notConfigured.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            certs = try await settings.client().listCertificates(search: search.trimmed)
            errorText = nil
            if search.trimmed.isEmpty {
                await ExpiryNotifier.reschedule(certs, profile: profile)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct CertRow: View {
    let cert: SSHCertificate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: cert.certType == "host" ? "server.rack" : "person.badge.key")
                .foregroundStyle(ExpiryBadge.color(cert.expiry()))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(cert.displayName).font(.headline).lineLimit(1)
                Text(cert.principalText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let to = cert.validToDate {
                    Text("bis \(to.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            ExpiryBadge(cert: cert, compact: true)
        }
    }
}

/// Zustand eines Zertifikats: gültig, läuft bald ab, abgelaufen, widerrufen.
struct ExpiryBadge: View {
    let cert: SSHCertificate
    var compact = false

    var body: some View {
        let state = cert.expiry()
        if let text = Self.text(state, compact: compact) {
            if compact {
                Text(text).font(.caption2.bold()).foregroundStyle(Self.color(state))
            } else {
                LabeledContent("Status") { Text(text).foregroundStyle(Self.color(state)) }
            }
        }
    }

    static func text(_ state: SSHCertificate.Expiry, compact: Bool) -> String? {
        switch state {
        case .revoked: return "widerrufen"
        case .expired: return "abgelaufen"
        case .soon(let d):
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = compact ? .abbreviated : .full
            return "läuft \(f.localizedString(for: d, relativeTo: Date())) ab"
        case .valid: return compact ? nil : "gültig"
        case .unknown: return nil
        }
    }

    static func color(_ state: SSHCertificate.Expiry) -> Color {
        switch state {
        case .revoked: return .red
        case .expired, .soon: return .orange
        case .valid, .unknown: return Theme.mint
        }
    }
}

struct CertDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @State var cert: SSHCertificate
    var onChange: (SSHCertificate) -> Void = { _ in }

    @State private var export: SSHExport?
    @State private var files: [URL] = []
    @State private var errorText: String?
    @State private var confirmRevoke = false
    @State private var renewing = false

    private var base: String { SignView.fileBase(forPublicKey: cert.publicKey ?? "") }
    private var canRenew: Bool {
        cert.sshCaId != nil && !(cert.principals ?? []).isEmpty
            && (cert.publicKey?.trimmed.hasPrefix("ssh-") == true || cert.publicKey?.trimmed.hasPrefix("ecdsa-") == true)
    }

    var body: some View {
        Form {
            CertificateInfoSection(cert: cert)

            if canRenew {
                Section {
                    Button { renewing = true } label: {
                        Label("Erneuern", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Stellt ein neues Zertifikat für denselben Public Key, dieselbe CA und dieselben Principals aus.")
                }
            }
            if !files.isEmpty {
                Section {
                    ShareLink(items: files) {
                        Label("Zertifikat teilen / sichern", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let c = export?.certificate ?? cert.certificate {
                TextBlockSection(title: "Zertifikat (\(base)-cert.pub)", text: c, footer: nil)
            }
            if let ca = export?.caPublicKey {
                TextBlockSection(title: "CA Public Key", text: ca, footer: nil)
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
            if !cert.isRevoked {
                Section {
                    Button("Zertifikat widerrufen", role: .destructive) { confirmRevoke = true }
                }
            }
        }
        .appBackground()
        .navigationTitle(cert.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Zertifikat widerrufen?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Widerrufen", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("Der Widerruf wirkt auf Servern, die die Sperrliste (KRL) von UCM verwenden. Die automatische Sperrliste lässt sich unter CAs → Server einrichten aktivieren.")
        }
        .sheet(isPresented: $renewing) {
            RenewView(cert: cert)
        }
        .task { await loadExport() }
        .onDisappear { FileExport.removeTemporary(files) }
    }

    private func loadExport() async {
        guard export == nil else { return }
        do {
            let e = try await settings.client().export(certificateID: cert.id)
            export = e
            if let c = e.certificate, files.isEmpty {
                files = try FileExport.writeTemporary([.init(name: "\(base)-cert.pub", content: c.trimmed + "\n")])
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke() async {
        do {
            let client = try settings.client()
            try await client.revoke(certificateID: cert.id)
            cert = try await client.certificate(id: cert.id)
            onChange(cert)
            ExpiryNotifier.remove(certID: cert.id, profileID: settings.activeID)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Neues Zertifikat für den Public Key eines bestehenden Zertifikats.
struct RenewView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let cert: SSHCertificate

    @State private var validity: Validity = .day
    @State private var keyID = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var result: IssueResult?

    var body: some View {
        NavigationStack {
            if let result {
                IssueResultView(result: result)
            } else {
                Form {
                    CertificateInfoSection(cert: cert)
                    Section("Neues Zertifikat") {
                        TextField("Key-ID", text: $keyID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Gültigkeit", selection: $validity) {
                            ForEach(Validity.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if let errorText {
                        Section { Text(errorText).foregroundStyle(.red).font(.callout) }
                    }
                    Section {
                        Button {
                            Task { await renew() }
                        } label: {
                            HStack {
                                Spacer()
                                if working { ProgressView() } else { Label("Erneuern", systemImage: "arrow.triangle.2.circlepath") }
                                Spacer()
                            }
                        }
                        .disabled(working)
                    }
                }
                .appBackground()
                .navigationTitle("Erneuern")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                }
                .onAppear { if keyID.isEmpty { keyID = cert.keyId ?? "" } }
            }
        }
    }

    private func renew() async {
        guard let caID = cert.sshCaId, let pub = cert.publicKey?.trimmed else { return }
        working = true
        errorText = nil
        defer { working = false }
        let request = SignRequest(caID: caID, certType: SSHCertType(rawValue: cert.certType ?? "user") ?? .user,
                                  principals: cert.principals ?? [], validity: validity,
                                  keyID: keyID, descr: cert.descr ?? "")
        do {
            let issued = try await settings.client().sign(publicKey: pub, request: request)
            if let profile = settings.active { await ExpiryNotifier.schedule(issued, profile: profile) }
            result = IssueResult(certificate: issued, privateKey: nil, publicKey: pub,
                                 fileBase: SignView.fileBase(forPublicKey: pub), title: "Erneuert")
        } catch {
            errorText = error.localizedDescription
        }
    }
}
