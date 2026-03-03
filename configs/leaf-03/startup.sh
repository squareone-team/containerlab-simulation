#!/bin/bash
set -e
VTEP_IP="10.1.0.13"
ANYCAST_MAC="00:00:00:11:11:11"

ip link add VRF-SERVICES type vrf table 30 && ip link set VRF-SERVICES up
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0 && ip link set br0 up

ip link set eth3 master br0 && bridge vlan add vid 50 dev eth3 pvid untagged
ip link set eth4 master br0 && bridge vlan add vid 60 dev eth4 pvid untagged

for VNI_VLAN in "10050:50" "10060:60" "10070:70" "10090:90"; do
  VNI=${VNI_VLAN%%:*}; VLAN=${VNI_VLAN##*:}
  ip link add vxlan$VNI type vxlan id $VNI local $VTEP_IP dstport 4789 nolearning
  ip link set vxlan$VNI master br0 && ip link set vxlan$VNI up
  bridge vlan add vid $VLAN dev vxlan$VNI pvid untagged
done

bridge vlan add vid 4003 dev br0 self
bridge vlan add vid 50 dev br0 self
bridge vlan add vid 60 dev br0 self
bridge vlan add vid 70 dev br0 self
bridge vlan add vid 90 dev br0 self
ip link add vxlan50003 type vxlan id 50003 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan50003 master br0 && ip link set vxlan50003 up
bridge vlan add vid 4003 dev vxlan50003 pvid untagged

for VLAN_IP in "50:192.168.50.1/24" "60:192.168.60.1/24" "70:192.168.70.1/24"; do
  VLAN=${VLAN_IP%%:*}; IP=${VLAN_IP##*:}
  ip link add vlan$VLAN link br0 type vlan id $VLAN
  ip link set vlan$VLAN master VRF-SERVICES
  ip link set vlan$VLAN address $ANYCAST_MAC
  ip addr add $IP dev vlan$VLAN && ip link set vlan$VLAN up
done

ip link add vlan4003 link br0 type vlan id 4003
ip link set vlan4003 master VRF-SERVICES && ip link set vlan4003 up

ip link add vlan90 link br0 type vlan id 90
ip addr add 172.16.0.1/24 dev vlan90 && ip link set vlan90 up