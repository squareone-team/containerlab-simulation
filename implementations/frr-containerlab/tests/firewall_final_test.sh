#!/usr/bin/env bash
set -u

CLAB_PREFIX="clab-esi-datacenter"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

run_in_container() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

container_exists() {
  local node="$1"
  docker ps --format '{{.Names}}' | grep -qx "${CLAB_PREFIX}-${node}"
}

pass() {
  local msg="$1"
  echo -e "${GREEN}[PASS]${NC} ${msg}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local msg="$1"
  local debug_cmd="$2"
  echo -e "${RED}[FAIL]${NC} ${msg}"
  echo -e "  ${YELLOW}Debug:${NC} ${debug_cmd}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "============================================================"
echo " Task 1 Final Validation - Firewall Insertion & Security"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# Test 1: Admin -> Student (Permit & Hairpin)
# -----------------------------------------------------------------------------
echo "[TEST 1] Testing Admin -> Student One-Way Policy (9100/tcp)..."
if ! container_exists "server-admin-01" || ! container_exists "server-student-01"; then
  fail "Required containers for Test 1 are missing" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server-'"
else
  run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true; nc -l -p 9100 >/tmp/final-test-9100.log 2>&1 &"
  sleep 1

  if run_in_container "server-admin-01" "timeout 6 nc -zv 192.168.10.10 9100 >/tmp/final-test1.out 2>&1"; then
    pass "Admin can reach Student on 9100 (expected SUCCESS)"
  else
    fail "Admin -> Student 9100 failed (expected SUCCESS)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | sed -n '/chain forward/,/}/p'"
  fi
fi
echo

# -----------------------------------------------------------------------------
# Test 2: Student -> Admin (Stateful Drop)
# -----------------------------------------------------------------------------
echo "[TEST 2] Testing Student -> Admin Initiation Block (22/tcp)..."
if ! container_exists "server-student-01" || ! container_exists "server-admin-01"; then
  fail "Required containers for Test 2 are missing" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server-'"
else
  if run_in_container "server-student-01" "timeout 6 nc -zv 192.168.50.10 22 >/tmp/final-test2.out 2>&1"; then
    fail "Student -> Admin 22 unexpectedly succeeded (should be blocked)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_1_pedagogy.*cluster_2_admin'"
  else
    OUT2="$(run_in_container "server-student-01" "cat /tmp/final-test2.out 2>/dev/null || true")"
    if echo "$OUT2" | grep -qi 'timed out\|operation timed out'; then
      pass "Student -> Admin 22 timed out (expected FAIL/TIMEOUT)"
    else
      pass "Student -> Admin 22 failed (expected blocked behavior)"
    fi
  fi
fi
echo

# -----------------------------------------------------------------------------
# Test 3: Cluster 4 Isolation (Orientation Lockdown)
# -----------------------------------------------------------------------------
echo "[TEST 3] Testing Cluster 4 Isolation (Orientation Lockdown)..."
ORIENTATION_NODE="server-orientation-01"
if ! container_exists "$ORIENTATION_NODE"; then
  ORIENTATION_NODE="server-dmz-01"
fi

if ! container_exists "$ORIENTATION_NODE"; then
  fail "No orientation-like container found (server-orientation-01/server-dmz-01)" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server'"
else
  PING_C1_OK=0
  PING_C2_OK=0

  if run_in_container "$ORIENTATION_NODE" "ping -c 2 -W 1 192.168.10.10 >/tmp/final-test3-c1.out 2>&1"; then
    PING_C1_OK=1
  fi
  if run_in_container "$ORIENTATION_NODE" "ping -c 2 -W 1 192.168.50.10 >/tmp/final-test3-c2.out 2>&1"; then
    PING_C2_OK=1
  fi

  if [ "$PING_C1_OK" -eq 0 ] && [ "$PING_C2_OK" -eq 0 ]; then
    pass "Orientation source cannot reach Cluster 1/2 (expected FAIL)"
  else
    fail "Orientation source reached Cluster 1 or 2 (isolation broken)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_4_orientation'"
  fi
fi
echo

# -----------------------------------------------------------------------------
# Test 4: High Availability (Keepalived VIP)
# -----------------------------------------------------------------------------
echo "[TEST 4] Testing Keepalived VIP Reachability from Border Leaf..."
if ! container_exists "leaf-01"; then
  fail "Border leaf container missing (leaf-01)" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-leaf'"
else
  if run_in_container "leaf-01" "ping -c 2 -W 1 192.168.1.254 >/tmp/final-test4.out 2>&1"; then
    pass "VIP 192.168.1.254 reachable from border leaf (expected SUCCESS)"
  else
    fail "VIP 192.168.1.254 not reachable from border leaf" \
      "docker exec ${CLAB_PREFIX}-firewall-01 ip -4 addr show eth1; docker exec ${CLAB_PREFIX}-firewall-02 ip -4 addr show eth1"
  fi
fi
echo

# -----------------------------------------------------------------------------
# Test 5: Storage Access (General -> Storage)
# -----------------------------------------------------------------------------
echo "[TEST 5] Testing General -> Storage Access (2049/tcp)..."
if ! container_exists "server-student-01" || ! container_exists "server-storage-01"; then
  fail "Required containers for Test 5 are missing" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server-'"
else
  run_in_container "server-storage-01" "pkill nc >/dev/null 2>&1 || true; nc -l -p 2049 >/tmp/final-test-2049.log 2>&1 &"
  sleep 1

  if run_in_container "server-student-01" "timeout 6 nc -zv 192.168.80.10 2049 >/tmp/final-test5.out 2>&1"; then
    pass "General can reach Storage on 2049 (expected SUCCESS)"
  else
    fail "General -> Storage 2049 failed (expected SUCCESS)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_1_pedagogy.*cluster_5_storage'"
  fi
fi
echo

echo "============================================================"
echo " Results"
echo "============================================================"
echo -e "${GREEN}Passed:${NC} ${PASS_COUNT}"
echo -e "${RED}Failed:${NC} ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
