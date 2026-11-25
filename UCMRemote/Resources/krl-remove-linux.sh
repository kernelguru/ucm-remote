#!/bin/sh
# UCM Remote: automatische Sperrliste (KRL) wieder entfernen
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root bzw. mit sudo ausführen." >&2; exit 1; }
SSHD_CONFIG=/etc/ssh/sshd_config
KRL_FILE=/etc/ssh/ucm_revoked_keys.krl
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl disable --now ucm-krl-update.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ucm-krl-update.timer /etc/systemd/system/ucm-krl-update.service
    systemctl daemon-reload
fi
if [ -f /etc/crontabs/root ]; then
    grep -v '# ucm-remote-krl' /etc/crontabs/root > /etc/crontabs/root.ucm-remote || true
    cat /etc/crontabs/root.ucm-remote > /etc/crontabs/root
    rm -f /etc/crontabs/root.ucm-remote
fi
rm -f /etc/cron.d/ucm-krl-update /usr/local/sbin/ucm-krl-update /etc/ssh/ucm-krl.conf
cp -p "$SSHD_CONFIG" "$SSHD_CONFIG.ucm-remote.$(date +%Y%m%d%H%M%S)"
TMP=$(mktemp)
awk -v f="$KRL_FILE" '
    /^# SSH-Sperrliste: hinzugefügt von UCM Remote$/ { next }
    { s = $0; sub(/^[ \t]+/, "", s); k = tolower(s); sub(/[ \t=].*/, "", k)
      if (k == "revokedkeys" && index(s, f) > 0) next
      print }' "$SSHD_CONFIG" > "$TMP"
cat "$TMP" > "$SSHD_CONFIG"
rm -f "$TMP"
SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
"$SSHD" -t
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh
elif command -v rc-service >/dev/null 2>&1; then
    rc-service sshd reload
else
    service sshd reload 2>/dev/null || service ssh reload
fi
rm -f "$KRL_FILE"
echo "[OK]    Automatische Sperrliste entfernt."
echo "        Der API-Schlüssel für die Sperrliste kann jetzt in UCM widerrufen werden."
