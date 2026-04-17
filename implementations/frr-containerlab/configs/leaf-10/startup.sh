#!/bin/bash
set -e
VTEP_IP="10.1.0.20"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# RING 3: Allow BGP and BFD from known peer subnets, SSH from management subnet, and VTEP control traffic from all leafs. Drop all other attempts to connect to these services on the leaf itself.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

for AUTH_VTEP in 10.1.0.1 10.1.0.2 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  iptables -A INPUT -p udp --dport 4789 -s "$AUTH_VTEP" -j ACCEPT
done
iptables -A INPUT -p udp --dport 4789 -j DROP

ip link add VRF-PEDAGOGY type vrf table 30
ip link set VRF-PEDAGOGY up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

if ip link show eth3 >/dev/null 2>&1; then ip link set eth3 master br0; bridge vlan add vid 10 dev eth3 pvid untagged; fi
if ip link show eth4 >/dev/null 2>&1; then ip link set eth4 master br0; bridge vlan add vid 10 dev eth4 pvid untagged; fi

ip link add vxlan10010 type vxlan id 10010 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan10010 mtu 9000
ip link set vxlan10010 master br0
ip link set vxlan10010 up
bridge vlan add vid 10 dev vxlan10010 pvid untagged
bridge vlan add vid 10 dev br0 self
bridge vlan add vid 4030 dev br0 self

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

ip link add vlan10 link br0 type vlan id 10
ip link set vlan10 master VRF-PEDAGOGY
ip link set vlan10 address $ANYCAST_MAC || true
ip addr add 192.168.10.1/24 dev vlan10
ip link set vlan10 up

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

# === END PHASE 1 — Phase 2 appends below ===
ip link set eth3 up

# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth10"
ip addr replace 172.16.0.30/24 dev "$OOB_IF"
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
