#!/bin/sh
# Configuration pour STORAGE-01
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up
sleep 2
apk add --no-cache chrony
ip addr add 192.168.80.10/24 dev bond0
ip route del default
ip route add default via 192.168.80.1 dev bond0
