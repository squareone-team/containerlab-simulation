#!/bin/sh
set -eu

ip addr add 192.168.80.10/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.80.254 dev eth1

for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client nftables >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! command -v sshd >/dev/null 2>&1; then
  echo "Failed to install OpenSSH on ftp-server" >&2
  exit 1
fi

mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -A

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
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ -s /shared/bastion_ed25519.pub ]; then
    cat /shared/bastion_ed25519.pub > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    break
  fi
  sleep 1
done

/usr/sbin/sshd
