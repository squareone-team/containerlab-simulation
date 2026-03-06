#!/bin/bash
set -e
VTEP_IP="10.1.0.21"

# All four VRFs
for VRF_TABLE in "VRF-PEDAGOGY:10" "VRF-RESEARCH:20" "VRF-SERVICES:30" "VRF-AI:40"; do
  VRF=${VRF_TABLE%%:*}; TABLE=${VRF_TABLE##*:}
  ip link add $VRF type vrf table $TABLE && ip link set $VRF up
done

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0 && ip link set br0 up

# L3VNIs only — no server ports on border leafs
for VNI_VLAN_VRF in "50001:4001:VRF-PEDAGOGY" "50002:4002:VRF-RESEARCH" "50003:4003:VRF-SERVICES" "50004:4004:VRF-AI"; do
  VNI=${VNI_VLAN_VRF%%:*}; REST=${VNI_VLAN_VRF#*:}; VLAN=${REST%%:*}; VRF=${REST##*:}
  bridge vlan add vid $VLAN dev br0 self
  ip link add vxlan$VNI type vxlan id $VNI local $VTEP_IP dstport 4789 nolearning
  ip link set vxlan$VNI master br0 && ip link set vxlan$VNI up
  bridge vlan add vid $VLAN dev vxlan$VNI pvid untagged
  ip link add vlan$VLAN link br0 type vlan id $VLAN
  ip link set vlan$VLAN master $VRF && ip link set vlan$VLAN up
done