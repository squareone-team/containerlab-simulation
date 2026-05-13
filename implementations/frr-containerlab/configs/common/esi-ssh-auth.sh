#!/bin/sh
set -eu

RESOURCE="${1:?usage: esi-ssh-auth.sh <resource>}"

ensure_user() {
    username="$1"
    uid="$2"
    if ! id "$username" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -u "$uid" -m -d "/home/$username" -s /bin/sh "$username"
        else
            adduser -D -u "$uid" -h "/home/$username" -s /bin/sh "$username"
        fi
    fi
}

set_sshd_config() {
    key="$1"
    value="$2"
    if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" /etc/ssh/sshd_config; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" /etc/ssh/sshd_config
    else
        printf '%s %s\n' "$key" "$value" >> /etc/ssh/sshd_config
    fi
}

ensure_user squareone.admin 2101
ensure_user amine.kadri 2102

echo "$RESOURCE" > /etc/esi-auth-resource

mkdir -p /run/sshd /etc/pam.d /var/log
ssh-keygen -A

cat > /etc/pam.d/sshd << 'EOF'
auth required pam_exec.so expose_authtok type=auth /usr/bin/python3 /usr/local/bin/esi-pam-auth-client.py
auth required pam_permit.so
account required pam_permit.so
session required pam_permit.so
EOF

set_sshd_config UsePAM yes
set_sshd_config PasswordAuthentication no
set_sshd_config KbdInteractiveAuthentication yes
set_sshd_config ChallengeResponseAuthentication yes
set_sshd_config AuthenticationMethods keyboard-interactive
set_sshd_config PubkeyAuthentication no
set_sshd_config PermitRootLogin no
set_sshd_config PermitEmptyPasswords no
set_sshd_config AllowUsers "squareone.admin amine.kadri"
set_sshd_config MaxAuthTries 3
set_sshd_config LoginGraceTime 30

pkill sshd 2>/dev/null || true
if [ -x /usr/sbin/sshd.pam ]; then
    /usr/sbin/sshd.pam
else
    /usr/sbin/sshd
fi
