import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
    @AppStorage(ExpiryNotifier.enabledKey) private var notifyEnabled = false
    @AppStorage(ExpiryNotifier.leadKey) private var leadHours = 24
    @State private var lockEnabled = false
    @State private var notifyDenied = false

    var body: some View {
        Form {
            Section {
                if settings.profiles.count > 1 {
                    Picker("Aktiver Server", selection: $settings.activeID) {
                        ForEach(settings.profiles) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                }
                ForEach(settings.profiles) { profile in
                    NavigationLink {
                        ProfileEditView(profile: profile)
                    } label: {
                        HStack {
                            Image(systemName: profile.id == settings.activeID ? "checkmark.circle.fill" : "server.rack")
                                .foregroundStyle(profile.id == settings.activeID ? Theme.mint : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(profile.displayName)
                                Text(profile.server).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink {
                    ProfileEditView(profile: ServerProfile())
                } label: {
                    Label("Server hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Ultimate CA Manager")
            } footer: {
                Text(settings.profiles.count > 1
                     ? "Alle Tabs arbeiten mit dem aktiven Server."
                     : "API-Schlüssel in UCM unter Konto → API-Schlüssel anlegen. Benötigte Rechte: read:ssh, write:ssh, read:ssh_cas.")
            }

            Section {
                Toggle("Mit \(AppLock.biometryName) sperren", isOn: Binding(
                    get: { lockEnabled },
                    set: { on in
                        Task {
                            if await lock.setEnabled(on) { lockEnabled = on }
                        }
                    }))
            } header: {
                Text("Sicherheit")
            } footer: {
                Text("Fragt beim Öffnen und nach jedem Wechsel in den Hintergrund nach \(AppLock.biometryName). Im App-Umschalter wird der Inhalt verdeckt.")
            }

            Section {
                Toggle("Vor Ablauf erinnern", isOn: Binding(
                    get: { notifyEnabled },
                    set: { on in
                        if on {
                            Task {
                                let granted = await ExpiryNotifier.requestAuthorization()
                                notifyEnabled = granted
                                notifyDenied = !granted
                            }
                        } else {
                            notifyEnabled = false
                            ExpiryNotifier.removeEverything()
                        }
                    }))
                if notifyEnabled {
                    Picker("Zeitpunkt", selection: $leadHours) {
                        ForEach(ExpiryNotifier.leadOptions, id: \.hours) { Text($0.label).tag($0.hours) }
                    }
                }
                if notifyDenied {
                    Text("Mitteilungen sind für UCM Remote nicht erlaubt. In den iOS-Einstellungen unter Mitteilungen aktivieren.")
                        .font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Erinnerungen")
            } footer: {
                Text("Die Erinnerungen werden geplant, wenn die Zertifikatsliste geladen wird.")
            }

            Section("Info") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Link("Ultimate CA Manager auf GitHub", destination: URL(string: "https://github.com/NeySlim/ultimate-ca-manager")!)
            }
        }
        .appBackground()
        .navigationTitle("Einstellungen")
        .onAppear { lockEnabled = lock.enabled }
    }
}

/// Server-Adresse, API-Schlüssel und gepinntes Zertifikat eines Profils.
struct ProfileEditView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerProfile
    @State private var apiKey = ""
    @State private var testing = false
    @State private var result: String?
    @State private var errorText: String?
    @State private var untrustedFingerprint: String?
    @State private var confirmDelete = false

    init(profile: ServerProfile) {
        _draft = State(initialValue: profile)
    }

    private var isNew: Bool { !settings.profiles.contains { $0.id == draft.id } }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $draft.name)
                TextField("https://ucm.local:8443", text: $draft.server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API-Schlüssel", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
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
                .disabled(testing || draft.server.trimmed.isEmpty || apiKey.trimmed.isEmpty)
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
                        draft.pinnedFingerprint = fp
                        untrustedFingerprint = nil
                        Task { await saveAndTest() }
                    }
                } header: {
                    Text("Unbekanntes Server-Zertifikat")
                } footer: {
                    Text("Vergleiche den Fingerabdruck mit dem Zertifikat deines UCM-Servers (z. B. `openssl x509 -noout -fingerprint -sha256`). Danach akzeptiert die App nur noch genau dieses Zertifikat.")
                }
            }

            if !draft.pinnedFingerprint.isEmpty {
                Section("Gepinntes Server-Zertifikat") {
                    Text(draft.pinnedFingerprint).font(.system(.caption, design: .monospaced))
                    Button("Pin entfernen", role: .destructive) {
                        draft.pinnedFingerprint = ""
                        if !isNew { settings.setPinnedFingerprint("", for: draft.id) }
                    }
                }
            }

            if !isNew {
                Section {
                    Button("Server entfernen", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .appBackground()
        .navigationTitle(isNew ? "Neuer Server" : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if apiKey.isEmpty { apiKey = settings.apiKey(for: draft) } }
        .confirmationDialog("Server entfernen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                settings.delete(draft)
                dismiss()
            }
        } message: {
            Text("API-Schlüssel und Einstellungen dieses Servers werden vom iPhone gelöscht. In UCM bleibt alles unverändert.")
        }
    }

    private func saveAndTest() async {
        testing = true
        result = nil
        errorText = nil
        defer { testing = false }
        do {
            let client = try UCMClient(server: draft.server, apiKey: apiKey, pinnedFingerprint: draft.pinnedFingerprint)
            settings.save(draft, apiKey: apiKey)
            let cas = try await client.listCAs()
            result = "Verbunden – \(cas.count) SSH-CA(s) gefunden"
        } catch UCMError.untrustedCertificate(let fp) {
            untrustedFingerprint = fp
            errorText = "Der Server nutzt ein nicht vertrauenswürdiges (z. B. selbstsigniertes) Zertifikat."
        } catch {
            errorText = error.localizedDescription
        }
    }
}
