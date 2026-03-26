#!/bin/bash

# On définit le préfixe pour éviter de le retaper (à adapter selon ton lab)
LAB_PREFIX="clab-esi-datacenter"

echo "-------------------------------------------------------"
echo "🚀 DEBUT DES TESTS MULTI-HOMING EVPN - Ikram Datacenter"
echo "-------------------------------------------------------"

# 1. Vérification ESI (On retire -it pour éviter l'erreur TTY)
echo -e "\n🔍 [TEST 1] Vérification de l'état ESI sur Leaf-03..."
sudo docker exec ${LAB_PREFIX}-leaf-03 vtysh -c "show evpn es detail" | grep -E "ESI|Remote gateway|eth3|eth4" || echo "⚠️ Aucune ESI détectée."

# 2. Test de connectivité
echo -e "\n🔍 [TEST 2] Ping entre Student-01 et Student-02 (Inter-VLAN)..."
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -c 3 192.168.20.10

# 3. TEST DE PANNE
echo -e "\n🔥 [TEST 3] Simulation de coupure de lien sur Student-01..."

# On lance le ping DEPUIS le container et on redirige la sortie vers un fichier local
# Note : Pas de -it ici non plus
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -i 0.2 192.168.10.1 > ping_test.txt &
PING_PID=$!

sleep 1
echo "--- Coupure du lien eth1 (vers Leaf-09) ---"
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 down

sleep 3
echo "--- Rétablissement du lien eth1 ---"
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 up

# On laisse le lien remonter un peu avant de tuer le ping
sleep 1
sudo kill $PING_PID 2>/dev/null

echo "--- Résultat du ping pendant la coupure : ---"
if [ -f ping_test.txt ]; then
    grep "packet loss" ping_test.txt
    rm ping_test.txt
else
    echo "❌ Erreur : Le fichier de log du ping n'a pas été généré."
fi

# 4. Vérification LACP
echo -e "\n🔍 [TEST 4] État du Bond sur Storage-01..."
sudo docker exec ${LAB_PREFIX}-server-storage-01 cat /proc/net/bonding/bond0 | grep -A 10 "802.3ad info"

echo -e "\n-------------------------------------------------------"
echo "✅ TESTS TERMINÉS"
echo "-------------------------------------------------------"