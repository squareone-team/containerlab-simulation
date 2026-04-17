#!/bin/bash
set -e
VTEP_IP="10.1.0.14"
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

ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

if ip link show eth3 >/dev/null 2>&1; then ip link set eth3 master br0; bridge vlan add vid 50 dev eth3 pvid untagged; fi
if ip link show eth4 >/dev/null 2>&1; then ip link set eth4 master br0; bridge vlan add vid 40 dev eth4 pvid untagged; fi

for V in 10030 10040 10050; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 30 dev vxlan10030 pvid untagged
bridge vlan add vid 40 dev vxlan10040 pvid untagged
bridge vlan add vid 50 dev vxlan10050 pvid untagged
bridge vlan add vid 30 dev br0 self
bridge vlan add vid 40 dev br0 self
bridge vlan add vid 50 dev br0 self
bridge vlan add vid 4020 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vlan30 link br0 type vlan id 30
ip link set vlan30 master VRF-STAFF
ip link set vlan30 address $ANYCAST_MAC || true
ip addr add 192.168.30.1/24 dev vlan30
ip link set vlan30 up

ip link add vlan40 link br0 type vlan id 40
ip link set vlan40 master VRF-STAFF
ip link set vlan40 address $ANYCAST_MAC || true
ip addr add 192.168.40.1/24 dev vlan40
ip link set vlan40 up

ip link add vlan50 link br0 type vlan id 50
ip link set vlan50 master VRF-STAFF
ip link set vlan50 address $ANYCAST_MAC || true
ip addr add 192.168.50.1/24 dev vlan50
ip link set vlan50 up

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

# === END PHASE 1 — Phase 2 appends below ===
ip link set eth3 up
ip link set eth5 up
