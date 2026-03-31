#!/bin/bash
set -e
VTEP_IP="10.1.0.18"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

if ip link show eth3 >/dev/null 2>&1; then ip link set eth3 master br0; bridge vlan add vid 80 dev eth3 pvid untagged; fi
if ip link show eth4 >/dev/null 2>&1; then ip link set eth4 master br0; bridge vlan add vid 80 dev eth4 pvid untagged; fi

ip link add vxlan10080 type vxlan id 10080 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan10080 mtu 9000
ip link set vxlan10080 master br0
ip link set vxlan10080 up
bridge vlan add vid 80 dev vxlan10080 pvid untagged
bridge vlan add vid 80 dev br0 self
bridge vlan add vid 4020 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vlan80 link br0 type vlan id 80
ip link set vlan80 master VRF-STAFF
ip link set vlan80 address $ANYCAST_MAC || true
ip addr add 192.168.80.1/24 dev vlan80
ip link set vlan80 up

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

# === END PHASE 1 — Phase 2 appends below ===

# Ring 4: restrict OOB SSH access to bastion-01 only
iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
