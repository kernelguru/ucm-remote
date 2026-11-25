# UCM Remote

iPhone-App (SwiftUI) zum Ausstellen von **SSH-Zertifikaten** über
[Ultimate CA Manager](https://github.com/NeySlim/ultimate-ca-manager).

## Funktionen

- **Ausstellen** – Benutzer- oder Host-Zertifikat mit Principals, Key-ID und Gültigkeit
  - Schlüssel **auf dem iPhone erzeugen** (Ed25519, privater Schlüssel verlässt das Gerät nicht)
  - **vorhandenen Public Key signieren** (einfügen oder `.pub`-Datei wählen)
  - Schlüsselpaar **von UCM erzeugen lassen** (Ed25519, ECDSA, RSA)
- Ergebnis als Dateien `id_ed25519`, `id_ed25519-cert.pub`, `id_ed25519.pub`.
  Zertifikat und Public Key liegen unter „Dateien“ → „Auf meinem iPhone“ → „UCM Remote“.
  Der **private Schlüssel wird nicht gespeichert**: nur teilen oder kopieren (Zwischenablage nur lokal, nach 10 Minuten geleert).
- **Zertifikate** – Liste, Suche, Export, **Erneuern**, Widerruf; Hinweis auf bald ablaufende Zertifikate
- **Erinnerungen** vor Ablauf (lokale Mitteilungen, 1 Stunde / 1 Tag / 1 Woche vorher)
- **CAs** – Public Key, Sperrliste (KRL) laden und teilen
- **Server einrichten** – Befehl zum Einfügen in die SSH-App (siehe unten)
- **Mehrere UCM-Server** (Profile), API-Schlüssel je Server im Schlüsselbund
- **Face ID / Touch ID**-Sperre, Inhalt im App-Umschalter verdeckt
- Nur HTTPS; selbstsignierte UCM-Server werden per SHA-256-Pinning akzeptiert

## Server einrichten

Unter *CAs → CA wählen → Server einrichten* erzeugt die App einen Befehl, den du per SSH-App
(Termius, Blink, …) auf dem Server einfügst. Er

1. holt das Einrichtungsskript von UCM (`/api/v2/ssh/cas/{id}/setup-script`) und führt es aus,
2. verschiebt Direktiven, die UCM hinter einen `Match`-Block gehängt hat, nach oben
   (sonst gelten sie z. B. unter Windows nur für Administratoren),
3. richtet die Principals ein: *Principal = Benutzername* (Standard), Principals-Datei je Benutzer
   oder unverändert wie von UCM,
4. auf Wunsch die **automatische Sperrliste**: Die App legt in UCM einen API-Schlüssel nur mit
   `read:ssh_cas` an. Der Server holt die KRL per systemd-Timer, Cron oder geplanter Aufgabe
   (alle 5–60 Minuten) und setzt `RevokedKeys`. Das UCM-Zertifikat wird dabei gepinnt
   (curl `--pinnedpubkey` bzw. SHA-256 unter Windows). Schlägt ein Abruf fehl, bleibt die alte Liste aktiv.

Vor jeder Änderung wird `sshd_config` gesichert. Schlägt `sshd -t` fehl, wird die Sicherung
wiederhergestellt.

| System | Einfügen in | Zeitsteuerung |
|---|---|---|
| Debian/Ubuntu, AlmaLinux/RHEL, Arch | bash/zsh/sh (mit oder ohne `sudo`) | systemd-Timer |
| Alpine | sh (als root) | BusyBox-crond |
| Windows (OpenSSH) | PowerShell als Administrator | geplante Aufgabe (SYSTEM) |

Der API-Schlüssel für die Sperrliste liegt auf dem Server in `/etc/ssh/ucm-krl.conf` (nur root)
bzw. `C:\ProgramData\ssh\ucm-krl\` (nur SYSTEM/Administratoren). Der eingefügte Befehl kann in der
Shell-History landen. Der Schlüssel darf aber nur CA-Daten lesen und lässt sich in UCM jederzeit widerrufen.
Zum Entfernen zeigt die App einen zweiten Befehl an.

## Einrichtung

1. In UCM einen API-Schlüssel mit den Rechten `read:ssh`, `write:ssh`, `read:ssh_cas` anlegen.
2. In der App unter *Einstellungen → Server hinzufügen* Adresse (z. B. `https://ucm.local:8443`) und
   API-Schlüssel eintragen, „Speichern & Verbindung testen“, bei Bedarf dem Server-Zertifikat vertrauen.
3. Für *Server einrichten* wird eine aktuelle UCM-Version benötigt.

## Build

GitHub Actions baut bei jedem Push eine **unsignierte IPA** (Artefakt `UCMRemote-unsigned-ipa`,
bei Tags `v*` zusätzlich als Release). Installation z. B. per AltStore, SideStore, Sideloadly oder TrollStore.

Außerdem laufen dort die Unit-Tests im Simulator und die Einrichtungsskripte werden echt ausgeführt:
in Containern mit Debian, AlmaLinux, Arch und Alpine (inklusive Anmeldung mit gültigem und gesperrtem
Zertifikat) sowie auf einem Windows-Runner mit OpenSSH (`tools/server-setup-test/`).

Lokal: `brew install xcodegen && xcodegen generate && open UCMRemote.xcodeproj`

App-Icon neu erzeugen (Windows): `powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1`
