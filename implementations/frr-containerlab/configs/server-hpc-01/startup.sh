#!/bin/bash
# Configuration LACP HPC-01 par Ikram

# 1. Créer l'interface bond0 en mode LACP
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Esclaver eth1 ET eth2 (Critique pour la redondance ESI)
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activer les interfaces
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 70 - HPC)
# Un petit délai pour laisser LACP s'établir avec les deux Leafs
sleep 2
ip addr add 192.168.70.10/24 dev bond0
ip route add default via 192.168.70.1 dev bond0