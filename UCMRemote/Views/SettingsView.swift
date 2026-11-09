import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var server = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var result: String?
    @State private var errorText: String?
    @State private var untrustedFingerprint: String?

    var body: some View {
        Form {
            Section {
                TextField("https://ucm.local:8443", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API-Schlüssel", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Ultimate CA Manager")
            } footer: {
                Text("API-Schlüssel in UCM unter Konto → API-Schlüssel anlegen. Benötigte Rechte: read:ssh, write:ssh, read:ssh_cas.")
            }

            Section {
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text("Speichern & Verbindung testen")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || server.trimmed.isEmpty || apiKey.trimmed.isEmpty)
            }

            if let result {
                Section { Label(result, systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.callout) }
            }
            if let fp = untrustedFingerprint {
                Section {
                    Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Diesem Zertifikat vertrauen") {
                        settings.pinnedFingerprint = fp
                        untrustedFingerprint = nil
                        Task { await saveAndTest() }
                    }
                } header: {
                    Text("Unbekanntes Server-Zertifikat")
                } footer: {
                    Text("Vergleiche den Fingerabdruck mit dem Zertifikat deines UCM-Servers (z. B. `openssl x509 -noout -fingerprint -sha256`). Danach akzeptiert die App nur noch genau dieses Zertifikat.")
                }
            }

            if !settings.pinnedFingerprint.isEmpty {
                Section("Gepinntes Server-Zertifikat") {
                    Text(settings.pinnedFingerprint).font(.system(.caption, design: .monospaced))
                    Button("Pin entfernen", role: .destructive) { settings.pinnedFingerprint = "" }
                }
            }

            Section("Info") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Link("Ultimate CA Manager auf GitHub", destination: URL(string: "https://github.com/NeySlim/ultimate-ca-manager")!)
            }
        }
        .appBackground()
        .navigationTitle("Einstellungen")
        .onAppear {
            server = settings.server
            apiKey = settings.apiKey
        }
    }

    private func saveAndTest() async {
        settings.server = server.trimmed
        settings.saveAPIKey(apiKey)
        testing = true
        result = nil
        errorText = nil
        defer { testing = false }
        do {
            let cas = try await settings.client().listCAs()
            result = "Verbunden – \(cas.count) SSH-CA(s) gefunden"
        } catch UCMError.untrustedCertificate(let fp) {
            untrustedFingerprint = fp
            errorText = "Der Server nutzt ein nicht vertrauenswürdiges (z. B. selbstsigniertes) Zertifikat."
        } catch {
            errorText = error.localizedDescription
        }
    }
}
