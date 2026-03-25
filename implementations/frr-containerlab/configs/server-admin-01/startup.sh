#!/bin/bash
# Configuration LACP Admin-01 par Ikram
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 master bond0
ip link set eth1 up
ip link set bond0 up

# IP selon ton YAML (VLAN 50)
ip addr add 192.168.50.10/24 dev bond0
ip route add default via 192.168.50.1 dev bond0