#!/usr/bin/env bash
set -euo pipefail

CLAB_PREFIX="clab-esi-datacenter"
FW1="${CLAB_PREFIX}-firewall-01"
FW2="${CLAB_PREFIX}-firewall-02"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

run_in_container() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

get_master_fw() {
  if docker exec "$FW1" sh -lc "ip -4 addr show bond0 | grep -q '192.168.1.254/24'"; then
    echo "$FW1"
  elif docker exec "$FW2" sh -lc "ip -4 addr show bond0 | grep -q '192.168.1.254/24'"; then
    echo "$FW2"
  else
    echo ""
  fi
}

get_rule_packets() {
  local fw="$1"
  local fragment="$2"
  docker exec "$fw" sh -lc "nft list chain inet filter forward | grep -F \"$fragment\" | sed -n 's/.*counter packets \\([0-9][0-9]*\\) bytes.*/\\1/p' | head -n1"
}

cleanup() {
  run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9102.log" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "============================================================"
echo " Firewall End-to-End Validation - Ring 1"
echo "============================================================"

MASTER_FW="$(get_master_fw)"
if [[ -z "$MASTER_FW" ]]; then
  fail "No firewall currently owns VIP"
  echo "Passed: $PASS_COUNT"
  echo "Failed: $FAIL_COUNT"
  exit 1
fi
pass "Master firewall detected: $MASTER_FW"

if run_in_container "leaf-03" "vtysh -c 'show ip route vrf VRF-STAFF 192.168.10.0/24' 2>/dev/null | grep -Eq '10\\.1\\.0\\.(11|12)'"; then
  pass "leaf-03 learns pedagogy route through the border leaves"
else
  fail "leaf-03 does not learn pedagogy route through the border leaves"
fi

if run_in_container "leaf-09" "vtysh -c 'show ip route vrf VRF-PEDAGOGY 192.168.50.0/24' 2>/dev/null | grep -Eq '10\\.1\\.0\\.(11|12)'"; then
  pass "leaf-09 learns admin route through the border leaves"
else
  fail "leaf-09 does not learn admin route through the border leaves"
fi

DMZ_DROP_RULE="ip saddr @cluster_public_dmz ip daddr @cluster_2_admin"
DMZ_TOKEN="RING1_DMZ_$(date +%s)"

run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9102.log; (nc -l -p 9102 >/tmp/ring1-admin-9102.log 2>&1 &)"
sleep 1
before_dmz="$(get_rule_packets "$MASTER_FW" "$DMZ_DROP_RULE")"
run_in_container "public-web-server" "printf '%s\n' '$DMZ_TOKEN' | nc -w 3 192.168.50.10 9102 >/dev/null 2>&1 || true"
sleep 2
after_dmz="$(get_rule_packets "$MASTER_FW" "$DMZ_DROP_RULE")"

if run_in_container "server-admin-01" "grep -Fqx '$DMZ_TOKEN' /tmp/ring1-admin-9102.log"; then
  fail "DMZ -> Admin 9102 unexpectedly delivered a payload"
else
  pass "DMZ -> Admin 9102 payload was blocked"
fi

if [[ -n "$before_dmz" && -n "$after_dmz" && "$after_dmz" -gt "$before_dmz" ]]; then
  pass "DMZ -> Admin drop rule counter increased ($before_dmz -> $after_dmz)"
else
  fail "DMZ -> Admin drop rule counter did not increase"
fi

echo "============================================================"
echo " Results"
echo "============================================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
