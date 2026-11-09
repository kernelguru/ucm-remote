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
                    CertDetailView(cert: cert)
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
            certs = try await settings.client().listCertificates(search: search.trimmed)
            errorText = nil
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
                .foregroundStyle(statusColor)
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
            if let status = cert.status {
                Text(status).font(.caption2.bold()).foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        if cert.revoked == true { return .red }
        if let to = cert.validToDate, to < Date() { return .orange }
        return Theme.mint
    }
}

struct CertDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @State var cert: SSHCertificate
    @State private var export: SSHExport?
    @State private var files: [URL] = []
    @State private var errorText: String?
    @State private var confirmRevoke = false

    private var base: String { SignView.fileBase(forPublicKey: cert.publicKey ?? "") }

    var body: some View {
        Form {
            CertificateInfoSection(cert: cert)

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
            if cert.revoked != true {
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
            Text("Der Widerruf wirkt erst, wenn die Server die aktuelle KRL von UCM verwenden.")
        }
        .task { await loadExport() }
    }

    private func loadExport() async {
        do {
            let e = try await settings.client().export(certificateID: cert.id)
            export = e
            if let c = e.certificate {
                files = try FileExport.write([.init(name: "\(base)-cert.pub", content: c.trimmed + "\n")],
                                             folder: "\(cert.displayName)-\(cert.serial.map(String.init) ?? String(cert.id))")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke() async {
        do {
            try await settings.client().revoke(certificateID: cert.id)
            if let updated = try await settings.client().listCertificates(search: cert.keyId ?? "").first(where: { $0.id == cert.id }) {
                cert = updated
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
