#!/usr/bin/env bash
set -euo pipefail

LAB_PREFIX="clab-esi-datacenter"
FW1="${LAB_PREFIX}-firewall-01"
FW2="${LAB_PREFIX}-firewall-02"
LEAF1="${LAB_PREFIX}-leaf-01"
ADMIN="${LAB_PREFIX}-server-admin-01"
STUDENT="${LAB_PREFIX}-server-student-01"
VIP="192.168.1.254"

pass=0
fail=0

ok() { echo "[PASS] $1"; pass=$((pass+1)); }
ko() { echo "[FAIL] $1"; fail=$((fail+1)); }

get_master_fw() {
  if docker exec "$FW1" sh -lc "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
    echo "$FW1"
  elif docker exec "$FW2" sh -lc "ip -4 addr show eth1 | grep -q '192.168.1.254/24'"; then
    echo "$FW2"
  else
    echo ""
  fi
}

get_eth1_counter_sum() {
  local fw="$1"
  local rx tx
  rx=$(docker exec "$fw" sh -lc "cat /sys/class/net/eth1/statistics/rx_packets")
  tx=$(docker exec "$fw" sh -lc "cat /sys/class/net/eth1/statistics/tx_packets")
  echo $((rx + tx))
}

echo "=== T3 Firewall In-Path Validation ==="

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

before=$(get_eth1_counter_sum "$MASTER_FW")

docker exec "$ADMIN" sh -lc "ping -c 5 -W 1 192.168.10.10 >/dev/null || true"
docker exec "$STUDENT" sh -lc "ping -c 5 -W 1 192.168.50.10 >/dev/null || true"

after=$(get_eth1_counter_sum "$MASTER_FW")

delta=$((after - before))
if (( delta > 0 )); then
  ok "Firewall eth1 packet counters increased after Admin<->General ICMP attempts (delta=$delta)"
else
  ko "Firewall eth1 packet counters did NOT increase after Admin<->General ICMP attempts"
fi

echo "---"
echo "Master: $MASTER_FW"
echo "eth1 packet counter before: $before"
echo "eth1 packet counter after : $after"
echo "delta                    : $delta"
echo "---"

echo "Passed: $pass"
echo "Failed: $fail"

if (( fail > 0 )); then
  exit 1
fi
