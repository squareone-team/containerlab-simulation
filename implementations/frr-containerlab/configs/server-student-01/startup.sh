#!/bin/bash

# Création du Bond LACP
ip link add bond0 type bond mode 802.3ad miimon 100
ip link set eth1 master bond0
ip link set eth1 up

ip link set bond0 up

# Adressage IP (selon ton plan 192.168.X.X)
ip addr add 192.168.10.10/24 dev bond0
ip route add default via 192.168.10.1 dev bond0