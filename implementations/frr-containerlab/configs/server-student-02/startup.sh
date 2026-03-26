#!/bin/bash
# Configuration LACP Student-02 par Ikram

# 1. Création de l'interface bond0 en mode LACP (802.3ad)
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Esclaver eth1 (vers Leaf-09) ET eth2 (vers Leaf-10)
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activer les interfaces physiques et le bond
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 20 - Student 02)
# On attend 2 secondes pour que la négociation LACP se termine
sleep 2
ip addr add 192.168.20.10/24 dev bond0
ip route add default via 192.168.20.1 dev bond0