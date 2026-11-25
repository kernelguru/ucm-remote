import SwiftUI

/// Erzeugt den Befehl, der einen Server für eine SSH-CA einrichtet: Skript von UCM plus
/// Korrekturen, Principals und auf Wunsch die automatische Sperrliste.
struct ServerSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    let ca: SSHCA

    @AppStorage("setup.platform") private var platformRaw = SetupPlatform.linux.rawValue
    @AppStorage("setup.sudo") private var useSudo = true
    @AppStorage("setup.principalsMode") private var principalsRaw = PrincipalsMode.username.rawValue
    @AppStorage("setup.krl") private var krlEnabled = true
    @AppStorage("setup.krlInterval") private var krlInterval = 15
    @AppStorage("setup.krlTrust") private var trustRaw = KRLTrustMode.pinned.rawValue

    @State private var hostname = ""
    @State private var principals = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var output: Output?
    @State private var confirmNewKey = false

    struct Output {
        let command: String
        let removal: String?
        let files: [URL]
        let containsKey: Bool
        let createdKey: Bool
    }

    private var platform: SetupPlatform {
        get { SetupPlatform(rawValue: platformRaw) ?? .linux }
    }
    private var principalsMode: PrincipalsMode { PrincipalsMode(rawValue: principalsRaw) ?? .username }
    private var trust: KRLTrustMode { KRLTrustMode(rawValue: trustRaw) ?? .pinned }
    private var wantsKRL: Bool { ca.type == .user && krlEnabled }

    var body: some View {
        Form {
            Section {
                Picker("System", selection: $platformRaw) {
                    ForEach(SetupPlatform.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if platform == .linux {
                    Toggle("Mit sudo ausführen", isOn: $useSudo)
                }
            } header: {
                Text("Zielsystem")
            } footer: {
                Text(platform == .linux
                     ? "Debian/Ubuntu, AlmaLinux/RHEL, Arch und Alpine. In eine bash-, zsh- oder sh-Sitzung einfügen (nicht fish). Ohne sudo als root anmelden."
                     : "In eine PowerShell einfügen, die als Administrator läuft. Ist cmd.exe die Standard-Shell, zuerst „powershell“ eingeben.")
            }

            if ca.type == .host {
                Section {
                    TextField("Hostname (optional)", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Host")
                } footer: {
                    Text("Danach den Host-Schlüssel des Servers in UCM signieren lassen und das Zertifikat wie im Skript beschrieben ablegen.")
                }
            }

            if ca.type == .user {
                Section {
                    Picker("Principals", selection: $principalsRaw) {
                        ForEach(PrincipalsMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    if principalsMode == .file {
                        TextEditor(text: $principals)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 80)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Anmeldung")
                } footer: {
                    Text(principalsMode.explanation)
                }

                krlSection
            }

            Section {
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView() } else { Label("Befehl erzeugen", systemImage: "terminal") }
                        Spacer()
                    }
                }
                .disabled(working)
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.callout) }
            }

            if let output {
                if output.createdKey {
                    Section {
                        Label("In UCM wurde ein API-Schlüssel für die Sperrliste angelegt (nur read:ssh_cas).", systemImage: "key")
                            .font(.callout)
                    }
                }
                TextBlockSection(
                    title: "Zum Einfügen",
                    text: output.command,
                    footer: footer(for: output),
                    sensitive: output.containsKey,
                    lineLimit: 14)
                if !output.files.isEmpty {
                    Section {
                        ShareLink(items: output.files) {
                            Label("Als Skriptdatei teilen", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text(platform == .linux
                             ? "Auf dem Server mit „sudo sh datei.sh“ ausführen."
                             : "Auf dem Server mit „powershell -ExecutionPolicy Bypass -File datei.ps1“ als Administrator ausführen.")
                    }
                }
                if let removal = output.removal {
                    TextBlockSection(
                        title: "Automatische Sperrliste wieder entfernen",
                        text: removal,
                        footer: nil,
                        sensitive: false,
                        lineLimit: 4)
                }
            }
        }
        .appBackground()
        .navigationTitle("Server einrichten")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: platformRaw) { _ in clearOutput() }
        .onDisappear { clearOutput() }
        .confirmationDialog("Neuen Schlüssel für die Sperrliste erstellen?", isPresented: $confirmNewKey, titleVisibility: .visible) {
            Button("Neu erstellen") {
                if let p = settings.active { settings.forgetKRLKey(for: p) }
                clearOutput()
            }
        } message: {
            Text("Beim nächsten „Befehl erzeugen“ legt die App einen neuen Schlüssel an. Server mit dem alten Schlüssel holen die Liste weiter, bis du ihn in UCM widerrufst.")
        }
    }

    @ViewBuilder private var krlSection: some View {
        Section {
            Toggle("Sperrliste automatisch holen", isOn: $krlEnabled)
            if krlEnabled {
                Picker("Intervall", selection: $krlInterval) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("alle \($0) Minuten").tag($0) }
                }
                Picker("TLS-Prüfung", selection: $trustRaw) {
                    ForEach(KRLTrustMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if let profile = settings.active, let key = settings.krlKey(for: profile) {
                    LabeledContent("API-Schlüssel", value: (key.prefix ?? "ucm_ak_") + "…")
                    if let exp = key.expiresAt.flatMap(Date.fromUCM) {
                        LabeledContent("Gültig bis", value: exp.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Neuen Schlüssel erstellen") { confirmNewKey = true }
                } else {
                    Text("Der API-Schlüssel (nur read:ssh_cas) wird beim Erzeugen automatisch in UCM angelegt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sperrliste (KRL)")
        } footer: {
            Text(krlEnabled
                 ? (trust == .pinned
                    ? "Der Server holt die Liste von UCM und akzeptiert dabei nur den aktuellen Schlüssel des UCM-Zertifikats. Wechselt UCM den Schlüssel, den Befehl neu erzeugen und einfügen."
                    : "Der Server prüft das UCM-Zertifikat über seine eigenen Zertifizierungsstellen. Nur wählen, wenn UCM ein öffentlich gültiges Zertifikat hat.")
                 : "Ohne Sperrliste wirkt ein Widerruf in UCM auf diesem Server nicht.")
        }
    }

    private func footer(for output: Output) -> String {
        var parts: [String] = []
        if output.containsKey {
            parts.append("Enthält den API-Schlüssel für die Sperrliste. Er darf nur CA-Daten lesen und landet auf dem Server in einer Datei, die nur root lesen kann. Die Zwischenablage wird nach 10 Minuten geleert.")
        }
        parts.append(platform == .linux
                     ? "Das Skript legt vorher eine Sicherung der sshd_config an und stellt sie wieder her, wenn „sshd -t“ fehlschlägt."
                     : "Das Skript legt vorher eine Sicherung der sshd_config an und stellt sie wieder her, wenn „sshd -t“ fehlschlägt. Läuft das UCM-Skript fehl, steht das Protokoll in %TEMP%.")
        return parts.joined(separator: "\n\n")
    }

    private func clearOutput() {
        if let files = output?.files { FileExport.removeTemporary(files) }
        output = nil
    }

    private func generate() async {
        guard let profile = settings.active else {
            errorText = UCMError.notConfigured.localizedDescription
            return
        }
        working = true
        errorText = nil
        clearOutput()
        defer { working = false }
        do {
            let client = try settings.client()
            let ucmScript = try await client.setupScript(caID: ca.id, type: ca.type, hostname: hostname, platform: platform)

            var krl: KRLSettings?
            var createdKey = false
            if wantsKRL {
                let key: StoredKRLKey
                if let existing = settings.krlKey(for: profile) {
                    key = existing
                } else {
                    let created = try await client.createAPIKey(
                        name: "UCM Remote Sperrliste", permissions: ["read:ssh_cas"], expiresDays: nil)
                    key = StoredKRLKey(id: created.id, key: created.key, prefix: created.keyPrefix,
                                       expiresAt: created.expiresAt, created: Date())
                    settings.saveKRLKey(key, for: profile)
                    createdKey = true
                }
                var curlPin: String?
                var fingerprint: String?
                if trust == .pinned {
                    let der = try await client.serverCertificate()
                    guard let pin = TLSPin.curlPublicKeyPin(der: der) else {
                        throw UCMError.decoding("TLS-Zertifikat nicht lesbar")
                    }
                    curlPin = pin
                    fingerprint = TLSPin.certificateFingerprint(der: der)
                }
                krl = KRLSettings(serverURL: client.baseURL.absoluteString, caID: ca.id, apiKey: key.key,
                                  intervalMinutes: krlInterval, curlPin: curlPin, certificateFingerprint: fingerprint)
            }

            let script: String
            let command: String
            var removal: String?
            switch platform {
            case .linux:
                script = try ServerSetup.linuxScript(ucmScript: ucmScript, ca: ca, principalsMode: principalsMode,
                                                     principals: principals, krl: krl)
                command = try ServerSetup.linuxPasteCommand(script: script, sudo: useSudo)
                if wantsKRL {
                    removal = try ServerSetup.linuxPasteCommand(
                        script: try ServerSetup.removalScript(platform: .linux), sudo: useSudo)
                }
            case .windows:
                script = try ServerSetup.windowsScript(ucmScript: ucmScript, ca: ca, principalsMode: principalsMode,
                                                       principals: principals, krl: krl)
                command = try ServerSetup.windowsPasteCommand(script: script)
                if wantsKRL {
                    removal = try ServerSetup.windowsPasteCommand(
                        script: try ServerSetup.removalScript(platform: .windows))
                }
            }
            let name = "ucm-setup-\(FileExport.sanitize(ca.displayName)).\(platform.fileExtension)"
            let files = try FileExport.writeTemporary([.init(name: name, content: script)])
            output = Output(command: command, removal: removal, files: files,
                            containsKey: krl != nil, createdKey: createdKey)
        } catch UCMError.http(let status, _) where status == 404 {
            errorText = "Diese UCM-Version kennt das Einrichtungsskript noch nicht. Bitte UCM aktualisieren."
        } catch {
            errorText = error.localizedDescription
        }
    }
}
