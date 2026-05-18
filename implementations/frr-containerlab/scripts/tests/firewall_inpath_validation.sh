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

wait_for_listener() {
  local node="$1"
  local port="$2"
  local timeout="${3:-10}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if run_in_container "$node" "port_hex=\$(printf '%04X' $port); awk -v port=\"\$port_hex\" '\$2 ~ \":\" port \"\$\" && \$4 == \"0A\" {found=1} END {exit(found ? 0 : 1)}' /proc/net/tcp /proc/net/tcp6 2>/dev/null"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

wait_for_payload() {
  local node="$1"
  local logfile="$2"
  local token="$3"
  local timeout="${4:-10}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if run_in_container "$node" "grep -Fqx '$token' '$logfile'"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

start_nc_listener() {
  local node="$1"
  local port="$2"
  local logfile="$3"

  run_in_container "$node" "pkill nc >/dev/null 2>&1 || true; rm -f '$logfile'; nohup nc -l -p $port >'$logfile' 2>&1 </dev/null &"
  wait_for_listener "$node" "$port"
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
  docker exec "$fw" sh -lc "nft list chain inet filter forward | grep -F \"$fragment\" | sed -n 's/.*counter packets \\([0-9][0-9]*\\) bytes.*/\\1/p' | head -n1" || true
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
ALLOW_ATTEMPTS=6
allow_delivered=0
allow_success_attempt=""

before_allow="$(get_rule_packets "$MASTER_FW" "$ALLOW_RULE")"

# A single admin -> student attempt can hash onto different fabric buckets because
# the destination host is dual-homed. We retry a few real payload deliveries so
# this script stays scoped to Ring 1 firewall validation instead of random ECMP
# luck elsewhere in the topology.
for attempt in $(seq 1 "$ALLOW_ATTEMPTS"); do
  attempt_token="${ALLOW_TOKEN}_${attempt}"

  if ! start_nc_listener "server-student-01" 9100 "/tmp/ring1-student-9100.log"; then
    continue
  fi

  run_in_container "server-admin-01" "printf '%s\n' '$attempt_token' | nc -w 3 192.168.10.10 9100 >/dev/null 2>&1 || true"

  if wait_for_payload "server-student-01" "/tmp/ring1-student-9100.log" "$attempt_token" 3; then
    allow_delivered=1
    allow_success_attempt="$attempt"
    break
  fi
done

after_allow="$(get_rule_packets "$MASTER_FW" "$ALLOW_RULE")"

if (( allow_delivered == 1 )); then
  ok "Admin -> Pedagogy 9100 delivered a real payload (attempt $allow_success_attempt/$ALLOW_ATTEMPTS)"
else
  ko "Admin -> Pedagogy 9100 did not deliver the expected payload after $ALLOW_ATTEMPTS attempts"
fi

if [[ -n "$before_allow" && -n "$after_allow" && "$after_allow" -gt "$before_allow" ]]; then
  ok "Admin -> Pedagogy allow rule counter increased ($before_allow -> $after_allow)"
else
  ko "Admin -> Pedagogy allow rule counter did not increase"
fi

DROP_RULE="ip saddr @cluster_1_pedagogy ip daddr @cluster_2_admin"
DROP_TOKEN="RING1_DROP_$(date +%s)"

if start_nc_listener "server-admin-01" 9101 "/tmp/ring1-admin-9101.log"; then
  ok "Admin listener on 9101 is ready"
else
  ko "Admin listener on 9101 did not become ready"
fi

before_drop="$(get_rule_packets "$MASTER_FW" "$DROP_RULE")"
run_in_container "server-student-01" "printf '%s\n' '$DROP_TOKEN' | nc -w 3 192.168.50.10 9101 >/dev/null 2>&1 || true"
after_drop="$(get_rule_packets "$MASTER_FW" "$DROP_RULE")"

if wait_for_payload "server-admin-01" "/tmp/ring1-admin-9101.log" "$DROP_TOKEN" 3; then
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
