#!/bin/sh
set -eu

for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client nftables rsyslog >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! command -v sshd >/dev/null 2>&1; then
  echo "Failed to install OpenSSH on ftp-server" >&2
  exit 1
fi

ip addr add 192.168.80.11/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.80.254 dev eth1
ip addr add 172.16.0.61/24 dev eth2
ip link set eth2 up

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

for i in $(seq 1 60); do
  if [ -s /shared/bastion_ed25519.pub ]; then
    break
  fi
  sleep 1
done

if [ ! -s /shared/bastion_ed25519.pub ]; then
  echo "Bastion public key not found in /shared/bastion_ed25519.pub" >&2
  exit 1
fi

cat /shared/bastion_ed25519.pub > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;
    iif "lo" accept
    ct state established,related accept
    ip saddr 172.16.0.50 tcp dport 22 accept
    ip saddr 192.168.80.0/24 tcp dport 21 accept
    ip saddr 192.168.80.0/24 tcp dport 30000-31000 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
NFT

nft -f /etc/nftables.conf

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

/usr/sbin/rsyslogd

/usr/sbin/sshd
