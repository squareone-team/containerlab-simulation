#!/bin/bash
# Configuration Bridge LACP pour bp-sw par Ikram

# 1. Créer le Bridge (le commutateur virtuel)
ip link add br0 type bridge vlan_filtering 1
ip link set br0 up

# 2. Créer l'agrégation LACP (Bond0)
ip link add bond0 type bond mode 802.3ad miimon 100

# 3. Esclaver les interfaces physiques au bond
# eth1 -> Leaf-09:eth7 | eth2 -> Leaf-10:eth7
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0

# 4. Attacher le bond au bridge br0
ip link set bond0 master br0

# 5. Allumer toutes les interfaces
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 6. Configurer les VLANs sur le lien vers les Leafs (Trunk)
# On autorise les VLANs 10 (Student 1) et 20 (Student 2)
bridge vlan add vid 10 dev bond0
bridge vlan add vid 20 dev bond0
# Note: On retire le VLAN 1 par défaut pour plus de sécurité
bridge vlan del vid 1 dev bond0