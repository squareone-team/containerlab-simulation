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
ip link add VRF-PUBLIC type vrf table 40
ip link set VRF-PUBLIC up
ip link add VRF-ORIENTATION type vrf table 50
ip link set VRF-ORIENTATION up
ip link add VRF-WIFI-CTRL type vrf table 60
ip link set VRF-WIFI-CTRL up
for IFACE in eth3 eth4 eth5 eth6 eth8; do
  ip link set dev $IFACE mtu 9000 || true
done

ip link set eth8 master VRF-WIFI-CTRL
ip addr add 10.200.0.1/30 dev eth8
ip link set eth8 up
ip route add 192.168.10.100/32 via 10.200.0.2 vrf VRF-WIFI-CTRL

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

for V in 10090 10100 10120; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 90 dev vxlan10090 pvid untagged
bridge vlan add vid 100 dev vxlan10100 pvid untagged
bridge vlan add vid 120 dev vxlan10120 pvid untagged
bridge vlan add vid 90 dev br0 self
bridge vlan add vid 100 dev br0 self
bridge vlan add vid 120 dev br0 self
bridge vlan add vid 4030 dev br0 self
bridge vlan add vid 4060 dev br0 self

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

ip link add vxlan50060 type vxlan id 50060 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50060 mtu 9000
ip link set vxlan50060 master br0
ip link set vxlan50060 up
bridge vlan add vid 4060 dev vxlan50060 pvid untagged

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

ip link add vlan120 link br0 type vlan id 120
ip link set vlan120 master VRF-WIFI-CTRL
ip link set vlan120 address $ANYCAST_MAC || true
ip link set vlan120 up

ip link add vlan4060 link br0 type vlan id 4060
ip link set vlan4060 master VRF-WIFI-CTRL
ip link set vlan4060 up

# === END PHASE 1 — Phase 2 appends below ===

# Ring 4: restrict OOB SSH access to bastion-01 only
iptables -I INPUT -i eth0 -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --dport 22 -j DROP
