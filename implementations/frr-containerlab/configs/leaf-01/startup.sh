#!/bin/bash
set -e
VTEP_IP="10.1.0.11"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

ip link add VRF-PEDAGOGY type vrf table 30
ip link set VRF-PEDAGOGY up
ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up
ip link add VRF-PUBLIC type vrf table 40
ip link set VRF-PUBLIC up
ip link add VRF-ORIENTATION type vrf table 50
ip link set VRF-ORIENTATION up
for IFACE in eth3 eth4 eth5 eth6; do
  ip link set dev $IFACE mtu 9000 || true
done

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

for V in 10030 10040 10090 10100; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 30 dev vxlan10030 pvid untagged
bridge vlan add vid 40 dev vxlan10040 pvid untagged
bridge vlan add vid 90 dev vxlan10090 pvid untagged
bridge vlan add vid 100 dev vxlan10100 pvid untagged
bridge vlan add vid 30 dev br0 self
bridge vlan add vid 40 dev br0 self
bridge vlan add vid 90 dev br0 self
bridge vlan add vid 100 dev br0 self
bridge vlan add vid 4020 dev br0 self
bridge vlan add vid 4030 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

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

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

# === END PHASE 1 — Phase 2 appends below ===
