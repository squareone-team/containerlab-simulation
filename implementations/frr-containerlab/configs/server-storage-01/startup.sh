#!/bin/bash
# Configuration LACP Storage-01 par Ikram
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 master bond0
ip link set eth1 up
ip link set bond0 up

# IP VLAN 80 (Storage)
ip addr add 192.168.80.10/24 dev bond0
ip route add default via 192.168.80.1 dev bond0

echo "SERVER-STORAGE : LACP Bond0 et IP 192.168.80.10 configurés."