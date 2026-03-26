#!/bin/bash
# Configuration LACP HPC-02 par Ikram

# 1. Créer l'interface bond0 (Mode LACP)
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Ajouter les DEUX interfaces physiques au bond
# eth1 va vers Leaf-05, eth2 va vers Leaf-06
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activer les interfaces
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 70 - HPC)
# IP .20 pour ne pas entrer en conflit avec HPC-01 (.10)
sleep 2
ip addr add 192.168.70.20/24 dev bond0
ip route add default via 192.168.70.1 dev bond0