#!/bin/bash
# Configuration LACP DMZ par Ikram

# 1. Création du bond LACP
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Ajout des DEUX interfaces (eth1 vers Leaf-01, eth2 vers Leaf-02)
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activation
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 100 - DMZ)
sleep 2
ip addr add 192.168.100.10/24 dev bond0
ip route add default via 192.168.100.1 dev bond0