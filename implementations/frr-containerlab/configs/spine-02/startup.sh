#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# RING 3: Configure iptables to allow BGP and BFD from the expected sources, and SSH from the management host, while dropping other traffic to these ports.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth11"
ip addr replace 172.16.0.12/24 dev "$OOB_IF"
ip link set "$OOB_IF" up

# Ring 4: enable SSH daemon for bastion management
for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! command -v sshd >/dev/null 2>&1; then
  echo "Failed to install OpenSSH server on $(hostname)" >&2
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

/usr/sbin/sshd

iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP 2>/dev/null || iptables -A INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP
