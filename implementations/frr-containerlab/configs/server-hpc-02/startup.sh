#!/bin/sh
# Configuration pour HPC-02
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up
sleep 2
ip addr add 192.168.70.20/24 dev bond0
ip route del default
ip route add default via 192.168.70.1 dev bond0