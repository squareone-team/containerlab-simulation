#!/bin/bash
set -e
VTEP_IP="10.1.0.12"
ANYCAST_MAC="00:00:00:11:11:11"

ip link add VRF-RESEARCH type vrf table 20 && ip link set VRF-RESEARCH up
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0 && ip link set br0 up

ip link set eth3 master br0 && bridge vlan add vid 30 dev eth3 pvid untagged
ip link set eth4 master br0 && bridge vlan add vid 40 dev eth4 pvid untagged

for VNI_VLAN in "10030:30" "10040:40" "10090:90"; do
  VNI=${VNI_VLAN%%:*}; VLAN=${VNI_VLAN##*:}
  ip link add vxlan$VNI type vxlan id $VNI local $VTEP_IP dstport 4789 nolearning
  ip link set vxlan$VNI master br0 && ip link set vxlan$VNI up
  bridge vlan add vid $VLAN dev vxlan$VNI pvid untagged
done

bridge vlan add vid 4002 dev br0 self
bridge vlan add vid 30 dev br0 self
bridge vlan add vid 40 dev br0 self
bridge vlan add vid 90 dev br0 self
ip link add vxlan50002 type vxlan id 50002 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan50002 master br0 && ip link set vxlan50002 up
bridge vlan add vid 4002 dev vxlan50002 pvid untagged

for VLAN_IP in "30:192.168.30.1/24" "40:192.168.40.1/24"; do
  VLAN=${VLAN_IP%%:*}; IP=${VLAN_IP##*:}
  ip link add vlan$VLAN link br0 type vlan id $VLAN
  ip link set vlan$VLAN master VRF-RESEARCH
  ip link set vlan$VLAN address $ANYCAST_MAC
  ip addr add $IP dev vlan$VLAN && ip link set vlan$VLAN up
done

ip link add vlan4002 link br0 type vlan id 4002
ip link set vlan4002 master VRF-RESEARCH && ip link set vlan4002 up

ip link add vlan90 link br0 type vlan id 90
ip addr add 172.16.0.1/24 dev vlan90 && ip link set vlan90 up