#!/bin/bash

# Configuration LACP 
ip link add bond0 type bond mode 802.3ad miimon 100

# interface existante au bond
ip link set eth1 master bond0
# ip link set eth2 master bond0

ip link set eth1 up
ip link set bond0 up

ip addr add 192.168.100.10/24 dev bond0
ip route add default via 192.168.100.1 dev bond0