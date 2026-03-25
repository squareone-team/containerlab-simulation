#!/bin/bash
# Configuration LACP Student-02 par Ikram
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 master bond0
ip link set eth1 up
ip link set bond0 up

# IP VLAN 20 (Student)
ip addr add 192.168.20.10/24 dev bond0
ip route add default via 192.168.20.1 dev bond0