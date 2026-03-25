#!/bin/bash

# 1. Créer l'agrégation (Bond0) en mode LACP
ip link add bond0 type bond mode 802.3ad miimon 100

# 2. Esclaves du bond (vers leaf-09 et leaf-10)
ip link set eth1 master bond0
ip link set eth2 master bond0

# 3. Allumer les interfaces
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up

# 4. Configurer le VLAN 10 (Student) sur le bond
bridge vlan add vid 10 dev bond0 pvid untagged