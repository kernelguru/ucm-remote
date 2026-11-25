#!/bin/sh
# Test-CA, Zertifikate (Serien 7 = gesperrt, 8 = gültig), KRL und TLS-Zertifikat für die CI.
set -eu
W=${1:-work}
mkdir -p "$W"
cd "$W"
rm -f ca ca.pub good* victim* served.krl
ssh-keygen -q -t ed25519 -N '' -C ci-ca -f ca
if [ "${SKIP_CERTS:-0}" != 1 ]; then
    ssh-keygen -q -t ed25519 -N '' -f good
    ssh-keygen -q -t ed25519 -N '' -f victim
    ssh-keygen -q -s ca -I good -n alice -z 8 good.pub
    ssh-keygen -q -s ca -I victim -n alice -z 7 victim.pub
fi
printf 'serial: 7\n' > krl.spec
ssh-keygen -k -f served.krl -s ca.pub krl.spec
openssl req -x509 -newkey rsa:2048 -nodes -keyout tls.key -out tls.crt -days 2 -subj /CN=ucm.test 2>/dev/null
printf 'sha256//%s' "$(openssl x509 -in tls.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)" > pin.txt
echo "prepared in $W"
