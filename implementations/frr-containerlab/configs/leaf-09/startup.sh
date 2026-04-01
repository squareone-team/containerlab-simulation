#!/bin/bash
set -e
VTEP_IP="10.1.0.19"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

ip link add VRF-PEDAGOGY type vrf table 30
ip link set VRF-PEDAGOGY up

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

ip link set eth3 master br0
bridge vlan add vid 10 dev eth3 pvid untagged
ip link set eth4 master br0
bridge vlan add vid 20 dev eth4 pvid untagged

for V in 10010 10020; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 10 dev vxlan10010 pvid untagged
bridge vlan add vid 20 dev vxlan10020 pvid untagged
bridge vlan add vid 10 dev br0 self
bridge vlan add vid 20 dev br0 self
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

ip link add vlan20 link br0 type vlan id 20
ip link set vlan20 master VRF-PEDAGOGY
ip link set vlan20 address $ANYCAST_MAC || true
ip addr add 192.168.20.1/24 dev vlan20
ip link set vlan20 up

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

# === END PHASE 1 — Phase 2 appends below ===
