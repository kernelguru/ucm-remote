#!/bin/sh
# Läuft im Container (Debian, Alma, Arch, Alpine): installiert sshd, führt den Einfüge-Befehl aus und
# prüft Anmeldung mit gültigem und gesperrtem Zertifikat.
set -eu
W=/w/work
if command -v apt-get >/dev/null; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server openssh-client >/dev/null
elif command -v dnf >/dev/null; then
    dnf install -y -q openssh-server openssh-clients >/dev/null
elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm --needed openssh >/dev/null
elif command -v apk >/dev/null; then
    apk add --no-cache openssh >/dev/null
fi
ssh-keygen -A >/dev/null
mkdir -p /run/sshd
if ! id alice >/dev/null 2>&1; then
    if command -v useradd >/dev/null; then useradd -m -s /bin/sh alice; else adduser -D -s /bin/sh alice; fi
fi
sed -i 's/^alice:[^:]*:/alice:*:/' /etc/shadow
printf '\nMatch Group nobody\n    X11Forwarding no\n' >> /etc/ssh/sshd_config
cp "$W/ca.pub" /tmp/ucmtest-ca.pub

echo "=== Einfüge-Befehl ==="
sh "$W/paste-linux.txt"

echo "=== Prüfung ==="
grep -n 'TrustedUserCAKeys\|RevokedKeys\|AuthorizedPrincipalsFile\|^Match' /etc/ssh/sshd_config
first_match=$(grep -n '^Match' /etc/ssh/sshd_config | head -n 1 | cut -d: -f1)
for key in TrustedUserCAKeys RevokedKeys; do
    line=$(grep -n "^$key" /etc/ssh/sshd_config | head -n 1 | cut -d: -f1)
    if [ -z "$line" ] || [ "$line" -ge "$first_match" ]; then echo "FEHLER: $key nicht vor Match"; exit 1; fi
done
if grep -q '^AuthorizedPrincipalsFile' /etc/ssh/sshd_config; then echo "FEHLER: AuthorizedPrincipalsFile noch gesetzt"; exit 1; fi
[ "$(head -c 6 /etc/ssh/ucm_revoked_keys.krl)" = SSHKRL ] || { echo "FEHLER: keine KRL"; exit 1; }
[ "$(stat -c %a /etc/ssh/ucm-krl.conf)" = 600 ] || { echo "FEHLER: Rechte ucm-krl.conf"; exit 1; }
/usr/local/sbin/ucm-krl-update

SSHD=$(command -v sshd || echo /usr/sbin/sshd)
"$SSHD" -p 2222 -o PidFile=/tmp/sshd-test.pid
sleep 1
cp "$W/good" "$W/good-cert.pub" "$W/victim" "$W/victim-cert.pub" /tmp/
chmod 600 /tmp/good /tmp/victim
o="-p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
out=$(ssh $o -i /tmp/good alice@127.0.0.1 echo LOGIN_OK)
[ "$out" = LOGIN_OK ] || { echo "FEHLER: gültiges Zertifikat abgewiesen"; exit 1; }
echo "OK: gültiges Zertifikat (Serie 8) angenommen"
# shellcheck disable=SC2086
if ssh $o -i /tmp/victim alice@127.0.0.1 echo LOGIN_OK 2>/dev/null; then
    echo "FEHLER: gesperrtes Zertifikat angenommen"; exit 1
fi
echo "OK: gesperrtes Zertifikat (Serie 7) abgewiesen"

echo "=== Zweiter Lauf (idempotent) ==="
sh "$W/paste-linux.txt"
[ "$(grep -c '^RevokedKeys' /etc/ssh/sshd_config)" = 1 ] || { echo "FEHLER: RevokedKeys doppelt"; exit 1; }

echo "=== Entfernen ==="
sh "$W/paste-linux.txt.remove"
if grep -q '^RevokedKeys' /etc/ssh/sshd_config; then echo "FEHLER: RevokedKeys noch da"; exit 1; fi
[ ! -e /etc/ssh/ucm-krl.conf ] || { echo "FEHLER: ucm-krl.conf noch da"; exit 1; }
kill "$(cat /tmp/sshd-test.pid)" 2>/dev/null || true
echo "ALLES OK"
