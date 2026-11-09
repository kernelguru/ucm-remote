import SwiftUI

/// Zeigt das ausgestellte Zertifikat (und ggf. den Schlüssel) und bietet die Dateien zum Teilen an.
struct IssueResultView: View {
    let result: IssueResult
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var errorText: String?

    private var cert: SSHCertificate { result.certificate }
    private var base: String { result.fileBase }

    var body: some View {
        Form {
            CertificateInfoSection(cert: cert)

            Section {
                if !files.isEmpty {
                    ShareLink(items: files) {
                        Label("Dateien teilen / sichern", systemImage: "square.and.arrow.up")
                    }
                }
                Text("Gespeichert in Dateien → Auf meinem iPhone → UCM Remote → \(folderName)")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Dateien")
            } footer: {
                Text("Auf dem Client neben den Schlüssel legen (z. B. ~/.ssh/). `ssh -i ~/.ssh/\(base) user@host` nutzt \(base)-cert.pub automatisch.")
            }

            if let key = result.privateKey {
                TextBlockSection(title: "Privater Schlüssel (\(base))", text: key,
                                 footer: "Wird nur jetzt angezeigt. Sicher aufbewahren, z. B. in einer SSH-App (Termius, Blink, Secure ShellFish) importieren.")
            }
            if let c = cert.certificate {
                TextBlockSection(title: "Zertifikat (\(base)-cert.pub)", text: c, footer: nil)
            }
            TextBlockSection(title: "Public Key (\(base).pub)", text: result.publicKey, footer: nil)

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .appBackground()
        .navigationTitle("Ausgestellt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
        }
        .interactiveDismissDisabled(result.privateKey != nil)
        .onAppear(perform: writeFiles)
    }

    private var folderName: String {
        FileExport.sanitize("\(cert.displayName)-\(cert.serial.map(String.init) ?? String(cert.id))")
    }

    private func writeFiles() {
        guard files.isEmpty else { return }
        var items: [FileExport.Item] = []
        if let key = result.privateKey { items.append(.init(name: base, content: key)) }
        if let c = cert.certificate { items.append(.init(name: "\(base)-cert.pub", content: c.trimmed + "\n")) }
        if !result.publicKey.isEmpty { items.append(.init(name: "\(base).pub", content: result.publicKey.trimmed + "\n")) }
        do {
            files = try FileExport.write(items, folder: folderName)
        } catch {
            errorText = "Dateien konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}

/// Eckdaten eines Zertifikats.
struct CertificateInfoSection: View {
    let cert: SSHCertificate

    var body: some View {
        Section("Zertifikat") {
            LabeledContent("Key-ID", value: cert.keyId ?? "–")
            LabeledContent("Typ", value: cert.certType == "host" ? "Host" : "Benutzer")
            LabeledContent("Principals", value: cert.principalText.nilIfEmpty ?? "–")
            if let serial = cert.serial { LabeledContent("Seriennummer", value: String(serial)) }
            if let ca = cert.caName { LabeledContent("CA", value: ca) }
            if let from = cert.validFromDate { LabeledContent("Gültig ab", value: from.formatted(date: .abbreviated, time: .shortened)) }
            if let to = cert.validToDate { LabeledContent("Gültig bis", value: to.formatted(date: .abbreviated, time: .shortened)) }
            if let status = cert.status { LabeledContent("Status", value: status) }
        }
    }
}

/// Mehrzeiliger Text mit Kopier-Knopf.
struct TextBlockSection: View {
    let title: String
    let text: String
    let footer: String?
    @State private var copied = false

    var body: some View {
        Section {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
            Button {
                UIPasteboard.general.string = text
                copied = true
            } label: {
                Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}
