#!/bin/bash
set -e
VTEP_IP="10.1.0.12"
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
for IFACE in eth3 eth4 eth5 eth6 eth9; do
  ip link set dev $IFACE mtu 9000 || true
done

ip link add br-fw-ha type bridge vlan_filtering 1 vlan_default_pvid 1
ip link set br-fw-ha mtu 9000
ip link set br-fw-ha up
ip link set eth5 master br-fw-ha
ip link set eth9 master br-fw-ha
ip link set eth5 up
ip link set eth9 up
ip addr add 192.168.1.253/24 dev br-fw-ha

# Policy routing for packets returning from firewall transit segment.
# br-fw-ha lives in default namespace; steer based on source subnet
# into tenant VRF route tables to avoid default-mgmt path.
ip rule add iif br-fw-ha to 192.168.10.0/24 lookup 30 prio 10000 || true
ip rule add iif br-fw-ha to 192.168.20.0/24 lookup 30 prio 10001 || true
ip rule add iif br-fw-ha to 192.168.50.0/24 lookup 20 prio 10002 || true
ip rule add iif br-fw-ha to 192.168.60.0/24 lookup 20 prio 10003 || true
ip rule add iif br-fw-ha from 192.168.50.0/24 lookup 30 prio 10010 || true
ip rule add iif br-fw-ha from 192.168.60.0/24 lookup 30 prio 10011 || true
ip rule add iif br-fw-ha from 192.168.10.0/24 lookup 20 prio 10012 || true
ip rule add iif br-fw-ha from 192.168.20.0/24 lookup 20 prio 10013 || true
ip rule add iif br-fw-ha from 192.168.70.0/24 lookup 20 prio 10014 || true
ip rule add iif br-fw-ha from 192.168.80.0/24 lookup 20 prio 10015 || true

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

for V in 10090 10100; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 90 dev vxlan10090 pvid untagged
bridge vlan add vid 100 dev vxlan10100 pvid untagged
bridge vlan add vid 90 dev br0 self
bridge vlan add vid 100 dev br0 self
bridge vlan add vid 4030 dev br0 self

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

# === END PHASE 1 — Phase 2 appends below ===
