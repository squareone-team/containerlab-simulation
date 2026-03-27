#!/bin/bash
# =======================================================
# Full EVPN Multi-Homing & Fabric Validation Script
# Lab : Ikram Datacenter (Containerlab + FRR)
# =======================================================

LAB_PREFIX="clab-esi-datacenter"
PASS=0
FAIL=0

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' 

echo "-------------------------------------------------------"
echo -e "🚀 ${YELLOW}DEBUT DU TEST GLOBAL FABRIC & ESI${NC}"
echo "-------------------------------------------------------"

# Fonction de résultat
result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC} $2"
        ((PASS++))
    else
        echo -e "${RED}[FAIL]${NC} $2"
        ((FAIL++))
    fi
}

# -------------------------------------------------------
# TEST 1 : Vérification de l'état ESI sur TOUS les Leafs
# -------------------------------------------------------
echo -e "\n🔍 [SECTION 1] Vérification ESI sur tous les Leafs..."
LEAFS=("leaf-01" "leaf-02" "leaf-03" "leaf-04" "leaf-05" "leaf-06" "leaf-07" "leaf-08" "leaf-09" "leaf-10")

for LEAF in "${LEAFS[@]}"; do
    ESI_COUNT=$(sudo docker exec ${LAB_PREFIX}-${LEAF} vtysh -c "show evpn mh es" 2>/dev/null | grep -c "ESI")
    if [ "$ESI_COUNT" -gt 0 ]; then
        result 0 "ESI active sur ${LEAF} ($ESI_COUNT segment(s) détecté(s))"
    else
        # Note: Certains leafs pourraient ne pas avoir d'ESI par design
        echo -e "${YELLOW}[INFO]${NC} Pas d'ESI configurée sur ${LEAF}"
    fi
done

# -------------------------------------------------------
# TEST 2 : Sessions BGP EVPN (Voisinage avec Spines)
# -------------------------------------------------------
echo -e "\n🔍 [SECTION 2] Sessions BGP L2VPN EVPN..."
for LEAF in "${LEAFS[@]}"; do
    BGP_STATE=$(sudo docker exec ${LAB_PREFIX}-${LEAF} vtysh -c "show bgp l2vpn evpn summary" 2>/dev/null | grep -c "Established")
    if [ "$BGP_STATE" -gt 0 ]; then
        result 0 "Sessions EVPN Established sur ${LEAF}"
    else
        result 1 "BGP EVPN DOWN sur ${LEAF}"
    fi
done

# -------------------------------------------------------
# TEST 3 : Connectivité Inter-VLAN (Overlay)
# -------------------------------------------------------
echo -e "\n🔍 [SECTION 3] Ping Inter-VLAN (Student-01 -> Student-02)..."
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -c 3 -W 1 192.168.20.10 > /dev/null 2>&1
result $? "Connectivité 192.168.10.x -> 192.168.20.x"

# -------------------------------------------------------
# TEST 4 : Résilience ESI (Basculement de lien)
# -------------------------------------------------------
echo -e "\n🔥 [SECTION 4] Test de résilience ESI (Coupure eth1)..."
sudo docker exec ${LAB_PREFIX}-server-student-01 ping -i 0.2 -W 1 192.168.10.1 > res_test.txt 2>&1 &
PING_PID=$!

sleep 1
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 down
sleep 2
sudo docker exec ${LAB_PREFIX}-server-student-01 ip link set eth1 up
sleep 1

kill $PING_PID 2>/dev/null
LOSS=$(grep -c "unreachable" res_test.txt)
rm -f res_test.txt

if [ "$LOSS" -eq 0 ]; then
    result 0 "Basculement ESI transparent (0 perte)"
else
    result 1 "Coupure détectée lors du basculement ($LOSS paquets)"
fi

# -------------------------------------------------------
# TEST 5 : LACP / Bonding Serveur
# -------------------------------------------------------
echo -e "\n🔍 [SECTION 5] État LACP sur Storage-01..."
if sudo docker exec ${LAB_PREFIX}-server-storage-01 test -f /proc/net/bonding/bond0; then
    BOND_MODE=$(sudo docker exec ${LAB_PREFIX}-server-storage-01 cat /proc/net/bonding/bond0 | grep -c "802.3ad")
    if [ "$BOND_MODE" -gt 0 ]; then
        result 0 "LACP 802.3ad est actif sur Storage-01"
    else
        result 1 "Bond présent mais n'est pas en mode 802.3ad"
    fi
else
    result 1 "Interface bond0 absente sur Storage-01"
fi

# -------------------------------------------------------
# BILAN FINAL
# -------------------------------------------------------
echo -e "\n-------------------------------------------------------"
echo -e "📊 BILAN FINAL : ${GREEN}$PASS Reussis${NC} / ${RED}$FAIL Echecs${NC}"
echo "-------------------------------------------------------"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✅ TOUTE LA FABRIC ET L'ESI SONT OPÉRATIONNELS !${NC}"
    exit 0
else
    echo -e "${RED}❌ DES ERREURS DOIVENT ÊTRE CORRIGÉES.${NC}"
    exit 1
fi