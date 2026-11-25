#!/bin/sh
# ============================================================================
# UCM Remote: SSH-CA auf einem Linux-Server einrichten
# CA: __CA_NAME__
#
#   1. Einrichtungsskript von Ultimate CA Manager ausführen
#   2. Direktiven, die hinter einem "Match"-Block gelandet sind, nach oben holen
#   3. Principals einrichten
#   4. Optional: Sperrliste (KRL) regelmäßig von UCM holen (RevokedKeys)
#
# Getestet für Debian/Ubuntu, AlmaLinux/RHEL, Arch und Alpine.
# ============================================================================
set -eu

CA_TYPE='__CA_TYPE__'
PRINCIPALS_MODE='__PRINCIPALS_MODE__'
PRINCIPALS=__PRINCIPALS_Q__
KRL_ENABLED='__KRL_ENABLED__'
KRL_INTERVAL='__KRL_INTERVAL__'
UCM_CA_ID='__CA_ID__'

SSHD_CONFIG=/etc/ssh/sshd_config
PRINCIPALS_DIR=/etc/ssh/auth_principals
KRL_FILE=/etc/ssh/ucm_revoked_keys.krl
KRL_CONF=/etc/ssh/ucm-krl.conf
KRL_BIN=/usr/local/sbin/ucm-krl-update
KRL_MARK='# ucm-remote-krl'

info() { printf '[INFO]  %s\n' "$1"; }
ok()   { printf '[OK]    %s\n' "$1"; }
warn() { printf '[WARN]  %s\n' "$1"; }
err()  { printf '[ERROR] %s\n' "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "Bitte als root bzw. mit sudo ausführen."
    exit 1
fi

SSHD=$(command -v sshd 2>/dev/null || true)
if [ -z "$SSHD" ] && [ -x /usr/sbin/sshd ]; then SSHD=/usr/sbin/sshd; fi
if [ -z "$SSHD" ] && [ -x /usr/bin/sshd ]; then SSHD=/usr/bin/sshd; fi

reload_sshd() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
            || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null \
            || { warn "sshd konnte nicht neu geladen werden, bitte manuell prüfen."; return 0; }
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd reload 2>/dev/null || rc-service sshd restart \
            || { warn "sshd konnte nicht neu geladen werden, bitte manuell prüfen."; return 0; }
    elif command -v service >/dev/null 2>&1; then
        service sshd reload 2>/dev/null || service ssh reload \
            || { warn "sshd konnte nicht neu geladen werden, bitte manuell prüfen."; return 0; }
    else
        warn "Kein Dienst-Manager gefunden, bitte sshd manuell neu laden."
        return 0
    fi
    ok "sshd neu geladen"
}

# Ersetzt sshd_config durch $1, falls sich der Inhalt geändert hat.
replace_config() {
    if [ "$(cksum < "$1")" = "$(cksum < "$SSHD_CONFIG")" ]; then
        rm -f "$1"
        return 1
    fi
    cat "$1" > "$SSHD_CONFIG"
    rm -f "$1"
    return 0
}

# --- Schritt 1: Skript von UCM ----------------------------------------------
info "Schritt 1/4: Einrichtungsskript von UCM"
UCM_TMP=$(mktemp)
cat > "$UCM_TMP" <<'UCM_CA_SCRIPT_EOF'
__UCM_SCRIPT__
UCM_CA_SCRIPT_EOF
if sh "$UCM_TMP" </dev/null; then
    rm -f "$UCM_TMP"
else
    rm -f "$UCM_TMP"
    err "Das UCM-Skript ist fehlgeschlagen (siehe oben)."
    exit 1
fi
printf '\n'

if [ ! -f "$SSHD_CONFIG" ]; then
    err "$SSHD_CONFIG nicht gefunden."
    exit 1
fi
BACKUP="$SSHD_CONFIG.ucm-remote.$(date +%Y%m%d%H%M%S)"
cp -p "$SSHD_CONFIG" "$BACKUP"
info "Sicherung: $BACKUP"

# --- Schritt 2: Direktiven aus Match-Blöcken holen ---------------------------
# Alles nach der ersten "Match"-Zeile gilt nur für diesen Block. UCM hängt seine
# Zeilen ans Ende der Datei an. Gibt es dort schon einen Match-Block, gälten sie
# nur für diesen Block (unter Windows z. B. nur für Administratoren).
info "Schritt 2/4: Lage der Direktiven in sshd_config prüfen"
FIX_TMP=$(mktemp)
awk '
BEGIN {
    keys["trustedusercakeys"] = 1; keys["authorizedprincipalsfile"] = 1
    keys["hostcertificate"] = 1;   keys["revokedkeys"] = 1
}
{ line[NR] = $0 }
function kw(s) { sub(/^[ \t]+/, "", s); s = tolower(s); sub(/[ \t=].*/, "", s); return s }
END {
    m = 0
    for (i = 1; i <= NR; i++) {
        k = kw(line[i])
        if (k == "match") { m = i; break }
        if (k in keys) seen[k] = 1
    }
    if (m == 0) { for (i = 1; i <= NR; i++) print line[i]; exit }
    for (i = m + 1; i <= NR; i++) {
        k = kw(line[i])
        if ((k in keys) && !(k in seen)) {
            move[i] = 1; seen[k] = 1
            if (i - 1 > m && line[i - 1] ~ /^#.*UCM/) move[i - 1] = 1
        }
    }
    for (i = 1; i < m; i++) print line[i]
    for (i = m + 1; i <= NR; i++) if (i in move) print line[i]
    for (i = m; i <= NR; i++) if (!(i in move)) print line[i]
}' "$SSHD_CONFIG" > "$FIX_TMP"
if replace_config "$FIX_TMP"; then
    ok "Direktiven vor den ersten Match-Block verschoben"
else
    ok "Nichts zu verschieben"
fi

# --- Schritt 3: Principals ----------------------------------------------------
info "Schritt 3/4: Principals"
if [ "$CA_TYPE" = "user" ]; then
    case "$PRINCIPALS_MODE" in
    username)
        # Ohne AuthorizedPrincipalsFile muss das Zertifikat den Benutzernamen als
        # Principal enthalten (OpenSSH-Standard).
        P_TMP=$(mktemp)
        awk '{
            s = $0; sub(/^[ \t]+/, "", s); k = tolower(s); sub(/[ \t=].*/, "", k)
            if (k == "authorizedprincipalsfile" && index(s, "/etc/ssh/auth_principals/%u") > 0) next
            print
        }' "$SSHD_CONFIG" > "$P_TMP"
        if replace_config "$P_TMP"; then
            ok "AuthorizedPrincipalsFile entfernt: Principal = Benutzername"
        else
            ok "Principal = Benutzername"
        fi
        ;;
    file)
        mkdir -p "$PRINCIPALS_DIR"
        chmod 755 "$PRINCIPALS_DIR"
        COUNT=0
        printf '%s\n' "$PRINCIPALS" > "$PRINCIPALS_DIR/.ucm-remote.tmp"
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            user=$(printf '%s' "${entry%%:*}" | tr -d ' \t')
            list=${entry#*:}
            case "$user" in
            ''|*[!A-Za-z0-9._-]*|.*) warn "Ungültiger Benutzername übersprungen: $user"; continue ;;
            esac
            printf '%s\n' "$list" | tr ', \t' '\n\n\n' | sed '/^$/d' > "$PRINCIPALS_DIR/$user"
            chmod 644 "$PRINCIPALS_DIR/$user"
            ok "Principals für $user: $(tr '\n' ' ' < "$PRINCIPALS_DIR/$user")"
            COUNT=$((COUNT + 1))
        done < "$PRINCIPALS_DIR/.ucm-remote.tmp"
        rm -f "$PRINCIPALS_DIR/.ucm-remote.tmp"
        if [ "$COUNT" -eq 0 ]; then
            warn "Keine Einträge. Ohne $PRINCIPALS_DIR/<benutzer> ist keine Anmeldung per Zertifikat möglich."
        fi
        ;;
    *)
        ok "Unverändert"
        ;;
    esac
else
    ok "Host-CA, nichts zu tun"
fi

# --- Schritt 4: Sperrliste (KRL) ---------------------------------------------
info "Schritt 4/4: Sperrliste (KRL)"
if [ "$KRL_ENABLED" = "1" ] && [ "$CA_TYPE" = "user" ]; then
    if ! command -v curl >/dev/null 2>&1; then
        info "Installiere curl"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq </dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates </dev/null
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q curl </dev/null
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q curl </dev/null
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --noconfirm --needed curl </dev/null
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl </dev/null
        fi
        if ! command -v curl >/dev/null 2>&1; then
            err "curl fehlt und konnte nicht installiert werden."
            exit 1
        fi
    fi

    if [ -f "$KRL_CONF" ] && ! grep -q "^UCM_CA_ID=$UCM_CA_ID\$" "$KRL_CONF"; then
        warn "Die Sperrliste war für eine andere CA eingerichtet, sie wird ersetzt (sshd kennt nur eine RevokedKeys-Datei)."
    fi

    OLD_UMASK=$(umask)
    umask 077
    cat > "$KRL_CONF" <<'UCM_KRL_CONF_EOF'
# UCM Remote: Zugang zur Sperrliste. Der API-Schlüssel hat nur das Recht read:ssh_cas.
UCM_URL=__UCM_URL_Q__
UCM_CA_ID=__CA_ID__
UCM_PIN=__PIN_Q__
UCM_API_KEY=__API_KEY_Q__
KRL_FILE=/etc/ssh/ucm_revoked_keys.krl
UCM_KRL_CONF_EOF
    umask "$OLD_UMASK"
    chmod 600 "$KRL_CONF"

    mkdir -p "$(dirname "$KRL_BIN")"
    cat > "$KRL_BIN" <<'UCM_KRL_BIN_EOF'
#!/bin/sh
# UCM Remote: holt die SSH-Sperrliste (KRL) von Ultimate CA Manager.
# Bei Fehlern bleibt die bisherige Liste aktiv.
set -eu
. /etc/ssh/ucm-krl.conf
log() { logger -t ucm-krl "$1" 2>/dev/null || true; printf 'ucm-krl: %s\n' "$1" >&2; }
TMP=$(mktemp "$(dirname "$KRL_FILE")/.ucm-krl.XXXXXX")
trap 'rm -f "$TMP"' EXIT
if [ -n "$UCM_PIN" ]; then
    set -- --insecure --pinnedpubkey "$UCM_PIN"
else
    set --
fi
if ! printf 'header = "X-API-Key: %s"\n' "$UCM_API_KEY" \
    | curl -fsS --max-time 60 --retry 2 --config - "$@" -o "$TMP" "$UCM_URL/api/v2/ssh/cas/$UCM_CA_ID/krl"; then
    log "Download fehlgeschlagen, bisherige Sperrliste bleibt aktiv"
    exit 1
fi
if [ "$(head -c 6 "$TMP")" != "SSHKRL" ]; then
    log "Antwort ist keine KRL, bisherige Sperrliste bleibt aktiv"
    exit 1
fi
chmod 644 "$TMP"
mv -f "$TMP" "$KRL_FILE"
trap - EXIT
if command -v restorecon >/dev/null 2>&1; then restorecon "$KRL_FILE" 2>/dev/null || true; fi
UCM_KRL_BIN_EOF
    chmod 755 "$KRL_BIN"

    if "$KRL_BIN"; then
        ok "Sperrliste geladen: $KRL_FILE"
    else
        err "Die Sperrliste konnte nicht geladen werden. RevokedKeys wird nicht gesetzt."
        err "Prüfen: Erreicht der Server UCM? Test: $KRL_BIN"
        exit 1
    fi

    if grep -qiE '^[[:space:]]*RevokedKeys[[:space:]=]' "$SSHD_CONFIG"; then
        if grep -qiE "^[[:space:]]*RevokedKeys[[:space:]=]+${KRL_FILE}[[:space:]]*\$" "$SSHD_CONFIG"; then
            ok "RevokedKeys ist bereits gesetzt"
        else
            warn "RevokedKeys zeigt bereits auf eine andere Datei, bitte manuell prüfen:"
            warn "  $(grep -iE '^[[:space:]]*RevokedKeys' "$SSHD_CONFIG" | head -n 1)"
        fi
    else
        R_TMP=$(mktemp)
        awk -v f="$KRL_FILE" '
        function kw(s) { sub(/^[ \t]+/, "", s); s = tolower(s); sub(/[ \t=].*/, "", s); return s }
        !done && kw($0) == "match" { print "# SSH-Sperrliste: hinzugefügt von UCM Remote"; print "RevokedKeys " f; print ""; done = 1 }
        { print }
        END { if (!done) { print ""; print "# SSH-Sperrliste: hinzugefügt von UCM Remote"; print "RevokedKeys " f } }
        ' "$SSHD_CONFIG" > "$R_TMP"
        replace_config "$R_TMP" || true
        ok "RevokedKeys $KRL_FILE eingetragen"
    fi
    for f in /etc/ssh/sshd_config.d/*.conf; do
        if [ -f "$f" ] && grep -qiE '^[[:space:]]*RevokedKeys' "$f"; then
            warn "Auch $f setzt RevokedKeys. Es gilt der zuerst gelesene Wert."
        fi
    done

    if [ "$KRL_INTERVAL" -ge 60 ]; then CRON_SPEC='0 * * * *'; else CRON_SPEC="*/$KRL_INTERVAL * * * *"; fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat > /etc/systemd/system/ucm-krl-update.service <<'UCM_UNIT_EOF'
[Unit]
Description=UCM Remote: SSH-Sperrliste (KRL) aktualisieren
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ucm-krl-update
UCM_UNIT_EOF
        printf '[Unit]\nDescription=UCM Remote: SSH-Sperrliste alle %s Minuten aktualisieren\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=%smin\nRandomizedDelaySec=30\n\n[Install]\nWantedBy=timers.target\n' \
            "$KRL_INTERVAL" "$KRL_INTERVAL" > /etc/systemd/system/ucm-krl-update.timer
        systemctl daemon-reload
        systemctl enable --now ucm-krl-update.timer >/dev/null 2>&1
        systemctl restart ucm-krl-update.timer
        ok "systemd-Timer aktiv: alle $KRL_INTERVAL Minuten (systemctl list-timers ucm-krl-update.timer)"
    elif [ -d /etc/crontabs ]; then
        # Alpine / BusyBox crond
        touch /etc/crontabs/root
        grep -v "$KRL_MARK" /etc/crontabs/root > /etc/crontabs/root.ucm-remote || true
        printf '%s %s >/dev/null 2>&1 %s\n' "$CRON_SPEC" "$KRL_BIN" "$KRL_MARK" >> /etc/crontabs/root.ucm-remote
        cat /etc/crontabs/root.ucm-remote > /etc/crontabs/root
        rm -f /etc/crontabs/root.ucm-remote
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
        fi
        ok "Cron-Job aktiv: alle $KRL_INTERVAL Minuten (/etc/crontabs/root)"
    elif [ -d /etc/cron.d ]; then
        printf '%s\n%s root %s >/dev/null 2>&1\n' "$KRL_MARK" "$CRON_SPEC" "$KRL_BIN" > /etc/cron.d/ucm-krl-update
        chmod 644 /etc/cron.d/ucm-krl-update
        ok "Cron-Job aktiv: alle $KRL_INTERVAL Minuten (/etc/cron.d/ucm-krl-update)"
    else
        warn "Weder systemd noch cron gefunden. Bitte $KRL_BIN regelmäßig selbst aufrufen."
    fi
else
    ok "Nicht gewünscht"
fi

# --- Prüfen und neu laden ----------------------------------------------------
if [ -n "$SSHD" ]; then
    if "$SSHD" -t; then
        ok "sshd-Konfiguration ist gültig"
    else
        err "sshd -t meldet einen Fehler. Stelle $BACKUP wieder her."
        cat "$BACKUP" > "$SSHD_CONFIG"
        exit 1
    fi
else
    warn "sshd nicht gefunden, Konfiguration ungeprüft"
fi
if [ "$(cksum < "$BACKUP")" != "$(cksum < "$SSHD_CONFIG")" ]; then
    reload_sshd
fi

printf '\n[OK]    Fertig.\n'
