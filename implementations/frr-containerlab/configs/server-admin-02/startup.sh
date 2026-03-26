#!/bin/bash
# Configuration LACP Admin-02 par Ikram

# 1. Créer l'interface bond0 (LACP)
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Esclaver eth1 ET eth2 (très important pour l'ESI)
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activer tout le monde
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 60 - Admin 02)
# On attend un court instant que le LACP négocie avec les Leafs
sleep 2
ip addr add 192.168.60.10/24 dev bond0
ip route add default via 192.168.60.1 dev bond0