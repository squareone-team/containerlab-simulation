#!/bin/bash
# =======================================================
# Validation Rigoureuse par Paire de Leafs (ESI/Multi-homing)
# Lab : clab-esi-datacenter
# =======================================================

LAB_PREFIX="clab-esi-datacenter"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "  [${GREEN}PASS${NC}] $1"; }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; }

echo -e "=== VALIDATION PAR PAIRE DE LEAFS ===\n"

# --- CONFIGURATION DES PAIRES ET DES TESTS ---
# Format: "LeafA LeafB Serveur IP_Gateway IP_Distant Description"
PAIRS=(
    "leaf-01 leaf-02 server-dmz-01 192.168.100.1 192.168.100.1 DMZ_Zone"
    "leaf-03 leaf-04 server-admin-01 192.168.50.1 192.168.60.10 Admin_Zone"
    "leaf-05 leaf-06 server-hpc-01 192.168.70.1 192.168.70.20 HPC_Zone"
    "leaf-07 leaf-08 server-storage-01 192.168.80.1 192.168.80.1 Storage_Zone"
    "leaf-09 leaf-10 server-student-01 192.168.10.1 192.168.20.10 Student_Zone"
)

for P in "${PAIRS[@]}"; do
    L1=$(echo $P | awk '{print $1}')
    L2=$(echo $P | awk '{print $2}')
    SRV=$(echo $P | awk '{print $3}')
    GW=$(echo $P | awk '{print $4}')
    REMOTE=$(echo $P | awk '{print $5}')
    DESC=$(echo $P | awk '{print $6}')

    echo -e "📍 Vérification [${DESC}] (Paire ${L1}/${L2})"

    # 1. Test ESI Sync (Plan de contrôle)
    # On redirige les erreurs vtysh vers /dev/null pour un affichage propre
    SYNC1=$(docker exec ${LAB_PREFIX}-${L1} vtysh -c "show evpn mh es" 2>/dev/null | grep -c "ESI")
    SYNC2=$(docker exec ${LAB_PREFIX}-${L2} vtysh -c "show evpn mh es" 2>/dev/null | grep -c "ESI")
    
    if [ "$SYNC1" -gt 0 ] && [ "$SYNC2" -gt 0 ]; then
        pass "ESI synchronisée sur ${L1} et ${L2}"
    else
        fail "ESI manquante ou service FRR HS sur ${L1} ou ${L2}"
    fi

    # 2. Test DF Election (Anti-doublon / BUM)
    DF=$(docker exec ${LAB_PREFIX}-${L1} vtysh -c "show evpn mh es" 2>/dev/null | grep -c "DF")
    [ "$DF" -gt 0 ] && pass "Election Designated Forwarder OK" || fail "Problème d'élection DF"

    # 3. Test Gateway Anycast (LACP local + IRB)
    docker exec ${LAB_PREFIX}-${SRV} ping -c 2 -W 1 ${GW} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        # Vérification des DUP! (Doublons)
        DUPS=$(docker exec ${LAB_PREFIX}-${SRV} ping -c 3 -W 1 ${GW} | grep -c "DUP!")
        if [ "$DUPS" -eq 0 ]; then
            pass "Ping Gateway ${GW} (Stable, 0 DUP!)"
        else
            fail "Ping Gateway ${GW} ($DUPS DUP! détectés - Erreur DF)"
        fi
    else
        fail "Ping Gateway ${GW} ÉCHOUÉ (Vérifier Bond0/Privileged)"
    fi

    # 4. Test Connectivité Fabric (VXLAN Inter-VTEP)
    # On ne lance le test distant que si la destination est différente de la GW
    if [ "$GW" != "$REMOTE" ]; then
        docker exec ${LAB_PREFIX}-${SRV} ping -c 2 -W 1 ${REMOTE} > /dev/null 2>&1
        [ $? -eq 0 ] && pass "Ping Distant ${REMOTE} (Overlay OK)" || fail "Ping Distant ${REMOTE} ÉCHOUÉ"
    fi

    echo "-------------------------------------------------------"
done

# --- TEST FINAL VRF ---
echo -ne "🔍 Test Isolation VRF Finale... "
docker exec ${LAB_PREFIX}-server-dmz-01 ping -c 1 -W 1 192.168.50.10 > /dev/null 2>&1
[ $? -ne 0 ] && echo -e "${GREEN}[OK] VRF isolées${NC}" || echo -e "${RED}[FAIL] LEAK DETECTED${NC}"