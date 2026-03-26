#!/bin/bash
# Configuration LACP Admin-01 par Ikram

# 1. Créer l'interface bond0 en mode LACP (802.3ad)
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Esclaver les DEUX interfaces physiques (eth1 et eth2)
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Monter les interfaces
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configuration IP (Réseau Admin - VLAN 50)
# On attend un peu que le LACP se stabilise
sleep 2
ip addr add 192.168.50.10/24 dev bond0
ip route add default via 192.168.50.1 dev bond0