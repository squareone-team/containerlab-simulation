#!/bin/bash
set -e
VTEP_IP="10.1.0.11" # Leaf-01 VTEP IP address , a loopback IP can also be used here since it's only used as the source IP for VXLAN encapsulation
ANYCAST_MAC="00:00:00:11:11:11" # Anycast MAC address for the SVI interfaces, shared across all leafs to avoid ARP flooding

# VRF
ip link add VRF-PEDAGOGY type vrf table 10 # VRF named "VRF-PEDAGOGY" with routing table ID 10
ip link set VRF-PEDAGOGY up

# VLAN-aware bridge
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0 
ip link set br0 up

# Server access ports — untagged ingress per VLAN
ip link set eth3 master br0
bridge vlan add vid 10 dev eth3 pvid untagged   # server-ped-01
ip link set eth4 master br0
bridge vlan add vid 20 dev eth4 pvid untagged   # server-ped-02

# L2 VXLAN — VNI 10010 / VLAN 10
ip link add vxlan10010 type vxlan id 10010 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan10010 master br0
ip link set vxlan10010 up
bridge vlan add vid 10 dev vxlan10010 pvid untagged

# L2 VXLAN — VNI 10020 / VLAN 20
ip link add vxlan10020 type vxlan id 10020 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan10020 master br0
ip link set vxlan10020 up
bridge vlan add vid 20 dev vxlan10020 pvid untagged

# L2 VXLAN — VNI 10090 MGMT-OOB / VLAN 90 (all leafs carry this)
ip link add vxlan10090 type vxlan id 10090 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan10090 master br0
ip link set vxlan10090 up
bridge vlan add vid 90 dev vxlan10090 pvid untagged

# L3VNI — symmetric IRB for VRF-PEDAGOGY (VNI 50001, internal VLAN 4001)
bridge vlan add vid 4001 dev br0 self
bridge vlan add vid 10 dev br0 self
bridge vlan add vid 20 dev br0 self
bridge vlan add vid 90 dev br0 self
ip link add vxlan50001 type vxlan id 50001 local $VTEP_IP dstport 4789 nolearning
ip link set vxlan50001 master br0
ip link set vxlan50001 up
bridge vlan add vid 4001 dev vxlan50001 pvid untagged

# SVI anycast gateways (shared MAC across all leafs = no ARP flooding)
ip link add vlan10 link br0 type vlan id 10
ip link set vlan10 master VRF-PEDAGOGY
ip link set vlan10 address $ANYCAST_MAC
ip addr add 192.168.10.1/24 dev vlan10
ip link set vlan10 up

ip link add vlan20 link br0 type vlan id 20
ip link set vlan20 master VRF-PEDAGOGY
ip link set vlan20 address $ANYCAST_MAC
ip addr add 192.168.20.1/24 dev vlan20
ip link set vlan20 up

# L3VNI IRB interface (no IP — routing use only)
ip link add vlan4001 link br0 type vlan id 4001
ip link set vlan4001 master VRF-PEDAGOGY
ip link set vlan4001 up

# MGMT-OOB SVI
ip link add vlan90 link br0 type vlan id 90
ip addr add 172.16.0.1/24 dev vlan90
ip link set vlan90 up
