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

tcp_connect_expect_success() {
  local src_node="$1"
  local dst_ip="$2"
  local dst_port="$3"
  local tries=0

  while [ "$tries" -lt 5 ]; do
    if run_in_container "$src_node" "nc -z -w 3 $dst_ip $dst_port >/dev/null 2>&1"; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done

  return 1
}

tcp_connect_expect_blocked() {
  local src_node="$1"
  local dst_ip="$2"
  local dst_port="$3"
  local tries=0

  while [ "$tries" -lt 3 ]; do
    if run_in_container "$src_node" "nc -z -w 3 $dst_ip $dst_port >/dev/null 2>&1"; then
      return 1
    fi
    tries=$((tries + 1))
    sleep 1
  done

  return 0
}

echo "============================================================"
echo " Firewall End-to-End Validation - Ring 1"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# Test 1: Admin -> Student policy present (DNS/DHCP/Monitoring)
# -----------------------------------------------------------------------------
echo "[TEST 1] Testing Admin -> Student Policy Presence..."
if run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy tcp dport { 53, 9100 } ct state new accept' >/dev/null"; then
  pass "Admin -> Student policy present (expected SUCCESS)"
else
  fail "Admin -> Student policy missing (expected SUCCESS)" \
    "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | sed -n '/chain forward/,/}/p'"
fi
echo

# -----------------------------------------------------------------------------
# Test 2: Student -> Admin (Stateful Drop)
# -----------------------------------------------------------------------------
echo "[TEST 2] Testing Student -> Admin Initiation Block (9101/tcp)..."
if ! container_exists "server-student-01" || ! container_exists "server-admin-01"; then
  fail "Required containers for Test 2 are missing" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server-'"
else
  run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true; : > /tmp/final-test2-admin.log; nohup nc -l -p 9101 >/tmp/final-test2-admin.log 2>&1 </dev/null &"
  sleep 1

  if tcp_connect_expect_blocked "server-student-01" "192.168.50.10" "9101"; then
    pass "Student -> Admin 9101 blocked (expected behavior)"
  else
    fail "Student -> Admin 9101 unexpectedly succeeded (should be blocked)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_1_pedagogy.*cluster_2_admin'"
  fi
fi
echo

# -----------------------------------------------------------------------------
# Test 3: DMZ Isolation
# -----------------------------------------------------------------------------
echo "[TEST 3] Testing DMZ Isolation from Internal Clusters..."
SOURCE_NODE="server-dmz-01"

if ! container_exists "$SOURCE_NODE"; then
  fail "No DMZ source container found (server-dmz-01)" \
    "docker ps --format '{{.Names}}' | grep '${CLAB_PREFIX}-server'"
else
  PING_C1_OK=0
  PING_C2_OK=0

  if run_in_container "$SOURCE_NODE" "ping -c 2 -W 1 192.168.10.10 >/tmp/final-test3-c1.out 2>&1"; then
    PING_C1_OK=1
  fi
  if run_in_container "$SOURCE_NODE" "ping -c 2 -W 1 192.168.50.10 >/tmp/final-test3-c2.out 2>&1"; then
    PING_C2_OK=1
  fi

  if [ "$PING_C1_OK" -eq 0 ] && [ "$PING_C2_OK" -eq 0 ]; then
    pass "DMZ source cannot reach Cluster 1/2 (expected FAIL)"
  else
    fail "DMZ source reached Cluster 1 or 2 (isolation broken)" \
      "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_public_dmz'"
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
# Test 5: Storage policy present (General -> Storage)
# -----------------------------------------------------------------------------
echo "[TEST 5] Testing General -> Storage Policy Presence..."
if run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_5_storage tcp dport { 111, 2049, 3260 } ct state new accept' >/dev/null"; then
  pass "General -> Storage policy present (expected SUCCESS)"
else
  fail "General -> Storage policy missing (expected SUCCESS)" \
    "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_1_pedagogy.*cluster_5_storage'"
fi
echo

# -----------------------------------------------------------------------------
# Test 6: Pedagogy -> LMS policy present (Moodle)
# -----------------------------------------------------------------------------
echo "[TEST 6] Testing Pedagogy -> LMS Policy Presence..."
if run_in_container "firewall-01" "nft list ruleset | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_lms_staff tcp dport { 80, 443 } ct state new accept' >/dev/null"; then
  pass "Pedagogy -> LMS policy present (expected SUCCESS)"
else
  fail "Pedagogy -> LMS policy missing (expected SUCCESS)" \
    "docker exec ${CLAB_PREFIX}-firewall-01 nft list ruleset | grep -n 'cluster_lms_staff'"
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
