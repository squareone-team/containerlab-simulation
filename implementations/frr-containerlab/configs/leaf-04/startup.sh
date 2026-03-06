#!/bin/bash
set -e
VTEP_IP="10.1.0.14"
ANYCAST_MAC="00:00:00:11:11:11"

ip link add VRF-AI type vrf table 40 && ip link set VRF-AI up
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0 && ip link set br0 up

# Both GPU servers in same VLAN 80
ip link set eth3 master br0 && bridge vlan add vid 80 dev eth3 pvid untagged
ip link set eth4 master br0 && bridge vlan add vid 80 dev eth4 pvid untagged

ip link add vxlan10080 type vxlan id 10080 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan10080 master br0 && ip link set vxlan10080 up
bridge vlan add vid 80 dev vxlan10080 pvid untagged

ip link add vxlan10090 type vxlan id 10090 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan10090 master br0 && ip link set vxlan10090 up
bridge vlan add vid 90 dev vxlan10090 pvid untagged

bridge vlan add vid 4004 dev br0 self
bridge vlan add vid 80 dev br0 self
bridge vlan add vid 90 dev br0 self
ip link add vxlan50004 type vxlan id 50004 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan50004 master br0 && ip link set vxlan50004 up
bridge vlan add vid 4004 dev vxlan50004 pvid untagged

ip link add vlan80 link br0 type vlan id 80
ip link set vlan80 master VRF-AI
ip link set vlan80 address $ANYCAST_MAC
ip addr add 192.168.80.1/24 dev vlan80 && ip link set vlan80 up

ip link add vlan4004 link br0 type vlan id 4004
ip link set vlan4004 master VRF-AI && ip link set vlan4004 up

ip link add vlan90 link br0 type vlan id 90
ip addr add 172.16.0.1/24 dev vlan90 && ip link set vlan90 up