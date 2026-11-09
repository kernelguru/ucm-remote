# UCM Remote

iPhone-App (SwiftUI) zum Ausstellen von **SSH-Zertifikaten** über
[Ultimate CA Manager](https://github.com/NeySlim/ultimate-ca-manager).

## Funktionen

- **Ausstellen** – Benutzer- oder Host-Zertifikat mit Principals, Key-ID und Gültigkeit
  - Schlüssel **auf dem iPhone erzeugen** (Ed25519, privater Schlüssel verlässt das Gerät nicht)
  - **vorhandenen Public Key signieren** (einfügen oder `.pub`-Datei wählen)
  - Schlüsselpaar **von UCM erzeugen lassen** (Ed25519, ECDSA, RSA)
- Ergebnis als Dateien `id_ed25519`, `id_ed25519-cert.pub`, `id_ed25519.pub`
  (Teilen-Menü bzw. „Dateien“ → „Auf meinem iPhone“ → „UCM Remote“)
- **Zertifikate** – Liste, Suche, Export, Widerruf
- **CAs** – Public Key der SSH-CAs plus Einrichtungszeilen für `sshd_config` / `known_hosts`
- Selbstsignierte UCM-Server werden per SHA-256-Pinning akzeptiert

## Einrichtung

1. In UCM einen API-Schlüssel mit den Rechten `read:ssh`, `write:ssh`, `read:ssh_cas` anlegen.
2. In der App unter *Einstellungen* Server (z. B. `https://ucm.local:8443`) und API-Schlüssel eintragen,
   „Speichern & Verbindung testen“, bei Bedarf dem Server-Zertifikat vertrauen.

## Build

GitHub Actions baut bei jedem Push eine **unsignierte IPA** (Artefakt `UCMRemote-unsigned-ipa`,
bei Tags `v*` zusätzlich als Release). Installation z. B. per AltStore, SideStore, Sideloadly oder TrollStore.

Lokal: `brew install xcodegen && xcodegen generate && open UCMRemote.xcodeproj`

App-Icon neu erzeugen (Windows): `powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1`
