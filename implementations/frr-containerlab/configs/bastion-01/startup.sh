#!/bin/sh
set -eu

# Bastion management address on OOB network
ip addr flush dev eth0 || true
ip addr add 172.16.0.50/24 dev eth0
ip link set eth0 up

# SSH service hardening for management access
apk add --no-cache openssh >/dev/null
mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -A

# Use explicit settings required by Ring 4 policy.
if grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
  echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
if grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi
if grep -q '^MaxAuthTries' /etc/ssh/sshd_config; then
  sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
else
  echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config
fi
if grep -q '^LoginGraceTime' /etc/ssh/sshd_config; then
  sed -i 's/^LoginGraceTime.*/LoginGraceTime 30/' /etc/ssh/sshd_config
else
  echo 'LoginGraceTime 30' >> /etc/ssh/sshd_config
fi

# Generate bastion management keypair if missing.
if [ ! -f /root/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
fi

/usr/sbin/sshd -D -e
