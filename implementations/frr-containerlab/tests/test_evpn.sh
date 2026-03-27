#!/bin/bash
# =======================================================
# EVPN Multi-Homing Validation Script
# Lab : Ikram Datacenter (Containerlab + FRR)
# =======================================================

LAB_PREFIX="clab-esi-datacenter"

echo "-------------------------------------------------------"
echo "🚀 DEBUT DES TESTS MULTI-HOMING EVPN - Ikram Datacenter"
echo "-------------------------------------------------------"

# -------------------------------------------------------
# TEST 1 : Vérification de l'état ESI sur Leaf-03
# -------------------------------------------------------
echo -e "\n🔍 [TEST 1] Vérification de l'état ESI sur Leaf-03..."

if sudo docker exec ${LAB_PREFIX}-leaf-03 vtysh -c "show evpn es detail" >/dev/null 2>&1; then
    sudo docker exec ${LAB_PREFIX}-leaf-03 vtysh -c "show evpn es detail" \
        | grep -E "ESI|State|Mode|eth3|eth4" \
        || echo "⚠️ Aucune ESI détectée."
else
    echo "❌ Impossible d'exécuter vtysh sur Leaf-03."
fi

# -------------------------------------------------------
# TEST 2 : Ping Inter-VLAN (Student-01 → Student-02)
# -------------------------------------------------------
echo -e "\n🔍 [TEST 2] Ping entre Student-01 et Student-02 (Inter-VLAN)..."
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -c 3 192.168.20.10

# -------------------------------------------------------
# TEST 3 : Test de résilience (coupure de lien)
# -------------------------------------------------------
echo -e "\n🔥 [TEST 3] Simulation de coupure de lien sur Student-01..."

# Lancement du ping en arrière-plan
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -i 0.2 192.168.10.1 > ping_test.txt &
PING_PID=$!

sleep 1
echo "--- Coupure du lien eth1 (vers Leaf) ---"
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 down

sleep 3
echo "--- Rétablissement du lien eth1 ---"
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 up

sleep 1
sudo kill $PING_PID 2>/dev/null

echo "--- Résultat du ping pendant la coupure ---"
if [ -f ping_test.txt ]; then
    grep -E "packet loss|unreachable" ping_test.txt || echo "✅ Pas de perte significative détectée."
    rm ping_test.txt
else
    echo "❌ Erreur : fichier de log du ping absent."
fi

# -------------------------------------------------------
# TEST 4 : Vérification LACP / Bonding côté serveur
# -------------------------------------------------------
echo -e "\n🔍 [TEST 4] État du Bond sur Storage-01..."

if sudo docker exec ${LAB_PREFIX}-server-storage-01 test -f /proc/net/bonding/bond0; then
    sudo docker exec ${LAB_PREFIX}-server-storage-01 \
        cat /proc/net/bonding/bond0 | grep -A 10 "802.3ad"
else
    echo "⚠️ Aucun bond LACP détecté sur Storage-01."
fi

echo -e "\n-------------------------------------------------------"
echo "✅ TESTS TERMINÉS"
echo "-------------------------------------------------------"
