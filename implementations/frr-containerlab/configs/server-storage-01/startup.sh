#!/bin/bash
# Configuration LACP Storage-01 par Ikram

# 1. Création de l'interface bond0 (Mode LACP)
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Ajout des DEUX interfaces physiques (eth1 et eth2)
# Rappel : eth1 -> Leaf-07 / eth2 -> Leaf-08
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Activation du Bond et des esclaves
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (VLAN 80 - Storage)
# Le petit "sleep" pour laisser le LACP négocier avec les Leafs
sleep 2
ip addr add 192.168.80.10/24 dev bond0
ip route add default via 192.168.80.1 dev bond0