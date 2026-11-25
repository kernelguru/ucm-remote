#!/bin/sh
# Nachbildung des UCM-Skripts für Tests: hängt die Direktiven wie UCM ans Ende der sshd_config.
set -eu
mkdir -p /etc/ssh/ssh_ca_keys
cp /tmp/ucmtest-ca.pub /etc/ssh/ssh_ca_keys/user_ca.pub
if ! grep -qE '^[[:space:]]*TrustedUserCAKeys' /etc/ssh/sshd_config; then
    printf '\n# SSH User CA Trust: added by UCM setup script\nTrustedUserCAKeys /etc/ssh/ssh_ca_keys/user_ca.pub\n' >> /etc/ssh/sshd_config
fi
mkdir -p /etc/ssh/auth_principals
grep -qE '^[[:space:]]*AuthorizedPrincipalsFile' /etc/ssh/sshd_config \
    || printf 'AuthorizedPrincipalsFile /etc/ssh/auth_principals/%%u\n' >> /etc/ssh/sshd_config
echo "mock UCM script done"
