#!/usr/bin/env bash
set -euo pipefail

CLAB_PREFIX="clab-esi-datacenter"
LEAF1="${CLAB_PREFIX}-leaf-01"
FW1="${CLAB_PREFIX}-firewall-01"
FW2="${CLAB_PREFIX}-firewall-02"
ADMIN="${CLAB_PREFIX}-server-admin-01"
STUDENT="${CLAB_PREFIX}-server-student-01"
VIP="192.168.1.254"

pass=0
fail=0

ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }

run_in_container() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

get_master_fw() {
  if docker exec "$FW1" sh -lc "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
    echo "$FW1"
  elif docker exec "$FW2" sh -lc "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
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
  run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9101.log" >/dev/null 2>&1 || true
  run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-student-9100.log" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "=== Firewall In-Path Validation (Ring 1) ==="

if docker exec "$LEAF1" sh -lc "ping -c 2 -W 2 $VIP >/dev/null"; then
  ok "leaf-01 can ping VIP $VIP"
else
  ko "leaf-01 cannot ping VIP $VIP"
fi

MASTER_FW=$(get_master_fw)
if [[ -z "$MASTER_FW" ]]; then
  ko "No firewall currently owns VIP"
  echo "Passed: $pass"
  echo "Failed: $fail"
  exit 1
fi
ok "Master firewall detected: $MASTER_FW"

ALLOW_RULE="ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy tcp dport { 53, 9100 } ct state new"
ALLOW_TOKEN="RING1_ALLOW_$(date +%s)"

run_in_container "server-student-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-student-9100.log; (nc -l -p 9100 >/tmp/ring1-student-9100.log 2>&1 &)"
sleep 1
before_allow="$(get_rule_packets "$MASTER_FW" "$ALLOW_RULE")"
run_in_container "server-admin-01" "printf '%s\n' '$ALLOW_TOKEN' | nc -w 3 192.168.10.10 9100 >/dev/null 2>&1 || true"
sleep 2
after_allow="$(get_rule_packets "$MASTER_FW" "$ALLOW_RULE")"

if run_in_container "server-student-01" "grep -Fqx '$ALLOW_TOKEN' /tmp/ring1-student-9100.log"; then
  ok "Admin -> Pedagogy 9100 delivered a real payload"
else
  ko "Admin -> Pedagogy 9100 did not deliver the expected payload"
fi

if [[ -n "$before_allow" && -n "$after_allow" && "$after_allow" -gt "$before_allow" ]]; then
  ok "Admin -> Pedagogy allow rule counter increased ($before_allow -> $after_allow)"
else
  ko "Admin -> Pedagogy allow rule counter did not increase"
fi

DROP_RULE="ip saddr @cluster_1_pedagogy ip daddr @cluster_2_admin"
DROP_TOKEN="RING1_DROP_$(date +%s)"

run_in_container "server-admin-01" "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9101.log; (nc -l -p 9101 >/tmp/ring1-admin-9101.log 2>&1 &)"
sleep 1
before_drop="$(get_rule_packets "$MASTER_FW" "$DROP_RULE")"
run_in_container "server-student-01" "printf '%s\n' '$DROP_TOKEN' | nc -w 3 192.168.50.10 9101 >/dev/null 2>&1 || true"
sleep 2
after_drop="$(get_rule_packets "$MASTER_FW" "$DROP_RULE")"

if run_in_container "server-admin-01" "grep -Fqx '$DROP_TOKEN' /tmp/ring1-admin-9101.log"; then
  ko "Pedagogy -> Admin 9101 unexpectedly delivered a payload"
else
  ok "Pedagogy -> Admin 9101 payload was blocked"
fi

if [[ -n "$before_drop" && -n "$after_drop" && "$after_drop" -gt "$before_drop" ]]; then
  ok "Pedagogy -> Admin drop rule counter increased ($before_drop -> $after_drop)"
else
  ko "Pedagogy -> Admin drop rule counter did not increase"
fi

echo "Passed: $pass"
echo "Failed: $fail"

if (( fail > 0 )); then
  exit 1
fi
