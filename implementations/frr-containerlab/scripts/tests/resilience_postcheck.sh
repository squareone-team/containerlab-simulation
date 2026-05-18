#!/usr/bin/env bash
set -euo pipefail

CLAB_PREFIX="${CLAB_PREFIX:-clab-esi-datacenter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESILIENCY_SCRIPT="$LAB_ROOT/scripts/resiliancy/simulate_node_down.sh"
RETRIES="${RESILIENCE_POSTCHECK_RETRIES:-20}"
DELAY="${RESILIENCE_POSTCHECK_DELAY:-2}"
COMMAND_TIMEOUT="${RESILIENCE_POSTCHECK_COMMAND_TIMEOUT:-15}"

pass=0
fail=0
last_output=""

ok() {
  echo "[PASS] $1"
  pass=$((pass + 1))
}

ko() {
  echo "[FAIL] $1"
  fail=$((fail + 1))
}

run_node() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

check() {
  local label="$1"
  local node="$2"
  local cmd="$3"
  local attempt=1

  while [ "$attempt" -le "$RETRIES" ]; do
    if last_output="$(timeout "$COMMAND_TIMEOUT" docker exec "${CLAB_PREFIX}-${node}" sh -lc "$cmd" 2>&1)"; then
      ok "$label"
      return 0
    fi
    sleep "$DELAY"
    attempt=$((attempt + 1))
  done

  ko "$label"
  if [ -n "$last_output" ]; then
    echo "$last_output" | sed 's/^/  /'
  fi
  return 0
}

check_host() {
  local label="$1"
  local cmd="$2"
  local attempt=1

  while [ "$attempt" -le "$RETRIES" ]; do
    if last_output="$(timeout "$COMMAND_TIMEOUT" bash -lc "$cmd" 2>&1)"; then
      ok "$label"
      return 0
    fi
    sleep "$DELAY"
    attempt=$((attempt + 1))
  done

  ko "$label"
  if [ -n "$last_output" ]; then
    echo "$last_output" | sed 's/^/  /'
  fi
  return 0
}

check_blocked() {
  local label="$1"
  local node="$2"
  local cmd="$3"

  if last_output="$(timeout "$COMMAND_TIMEOUT" docker exec "${CLAB_PREFIX}-${node}" sh -lc "$cmd" 2>&1)"; then
    ko "$label"
    if [ -n "$last_output" ]; then
      echo "$last_output" | sed 's/^/  /'
    fi
  else
    ok "$label"
  fi
  return 0
}

echo "=== Resilience Post-Check ==="

echo
echo "--- Firewall HA and transit ---"
check "firewall-01 has Ring1 transit route via an active border leaf" \
  "firewall-01" \
  "ip -4 route show 192.168.0.0/16 | grep -Eq 'via 192.168.1.(252|253) dev bond0( |$)'"

check "firewall-02 has Ring1 transit route via an active border leaf" \
  "firewall-02" \
  "ip -4 route show 192.168.0.0/16 | grep -Eq 'via 192.168.1.(252|253) dev bond0( |$)'"

check "firewall-01 keepalived is running" \
  "firewall-01" \
  "pgrep keepalived >/dev/null"

check "firewall-02 keepalived is running" \
  "firewall-02" \
  "pgrep keepalived >/dev/null"

vip_owners=0
if run_node "firewall-01" "ip -4 addr show bond0 | grep -q '192.168.1.254/24'" >/dev/null 2>&1; then
  vip_owners=$((vip_owners + 1))
fi
if run_node "firewall-02" "ip -4 addr show bond0 | grep -q '192.168.1.254/24'" >/dev/null 2>&1; then
  vip_owners=$((vip_owners + 1))
fi
if [ "$vip_owners" -eq 1 ]; then
  ok "Ring1 VIP has exactly one owner"
else
  ko "Ring1 VIP ownership is invalid (owners=${vip_owners}, expected=1)"
fi

echo
echo "--- Spine and leaf control plane ---"
for spine in spine-01 spine-02; do
  check "${spine} has all 10 fabric BGP neighbors" \
    "$spine" \
    "vtysh -c 'show bgp summary' 2>/dev/null | grep -q 'Total number of neighbors 10'"
done

for leaf in leaf-01 leaf-02 leaf-03 leaf-04 leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10; do
  check "${leaf} EVPN sessions are up" \
    "$leaf" \
    "vtysh -c 'show bgp l2vpn evpn summary' 2>/dev/null | grep -q 'Total number of neighbors 2'"
  for iface in eth1 eth2; do
    check "${leaf}:${iface} is operational" \
      "$leaf" \
      "ip -o link show dev ${iface} | grep -Eq 'state (UP|UNKNOWN)'"
  done
done

echo
echo "--- L3VNI RMAC programming ---"
for item in \
  "leaf-01:vxlan50020" "leaf-01:vxlan50030" \
  "leaf-02:vxlan50020" "leaf-02:vxlan50030" \
  "leaf-03:vxlan50020" "leaf-04:vxlan50020" \
  "leaf-05:vxlan50020" "leaf-06:vxlan50020" \
  "leaf-07:vxlan50020" "leaf-08:vxlan50020" \
  "leaf-09:vxlan50030" "leaf-10:vxlan50030"; do
  node="${item%%:*}"
  vxlan="${item##*:}"
  check "${node}:${vxlan} has remote RMAC FDB entries" \
    "$node" \
    "bridge fdb show dev ${vxlan} | grep -q 'dst 10.1.0.'"
done

echo
echo "--- Bonded pod access links ---"
for server in \
  server-student-01 server-student-02 \
  server-admin-01 server-admin-02 \
  server-hpc-01 server-hpc-02 \
  server-storage-01 dns-server dhcp-server ntp-server; do
  check "${server} bond0 MII status is up" \
    "$server" \
    "test -f /proc/net/bonding/bond0 && grep -q '^MII Status: up' /proc/net/bonding/bond0"
  check "${server} has an active bond0 slave" \
    "$server" \
    "grep -q '^Currently Active Slave: ' /proc/net/bonding/bond0 && ! grep -q '^Currently Active Slave: None' /proc/net/bonding/bond0"
done

echo
echo "--- Core services and pod reachability ---"
check "dns-server unbound is running" \
  "dns-server" \
  "pgrep unbound >/dev/null"

check "ntp-server chronyd is running" \
  "ntp-server" \
  "pgrep chronyd >/dev/null"

check "dhcp-server kea-dhcp4 is running" \
  "dhcp-server" \
  "pgrep kea-dhcp4 >/dev/null"

for source in server-admin-01 server-hpc-01 server-hpc-02 server-storage-01; do
  check "${source} reaches DNS core service" \
    "$source" \
    "ping -c2 -W2 192.168.50.30 >/dev/null"
done

check "student pod east-west reachability is intact" \
  "server-student-01" \
  "ping -c2 -W2 192.168.10.20 >/dev/null"

check "admin-02 reaches its administration gateway" \
  "server-admin-02" \
  "ping -c2 -W2 192.168.60.1 >/dev/null"

check "hpc pod east-west reachability is intact" \
  "server-hpc-01" \
  "ping -c2 -W2 192.168.70.20 >/dev/null"

check "storage pod reaches its anycast gateway" \
  "server-storage-01" \
  "ping -c2 -W2 192.168.80.1 >/dev/null"


check_blocked "unauthenticated guest cannot resolve DMZ name through core DNS" \
  "guest-01" \
  "nslookup dmz-server-01.esi.internal 192.168.50.30 >/dev/null 2>&1"

check_blocked "unauthenticated guest cannot reach DMZ HTTP service" \
  "guest-01" \
  "nc -z -w2 198.51.100.10 80"

check_blocked "unauthenticated guest cannot reach WiFi controller through campus path" \
  "guest-01" \
  "ping -c2 -W2 192.168.10.100 >/dev/null"

check_blocked "unauthenticated guest cannot reach Jupyter frontend" \
  "guest-01" \
  "nc -z -w2 192.168.70.30 8080"

check "distribution-switch reaches WiFi controller" \
  "distribution-switch" \
  "ping -c2 -W2 192.168.10.100 >/dev/null"

check "distribution-switch reaches DMZ HTTP service through firewall" \
  "distribution-switch" \
  "wget -qO- -T 5 http://198.51.100.10 | grep -q 'ESI Datacenter DMZ test service is reachable'"

check_host "all resilience state is restored" \
  "${RESILIENCY_SCRIPT} --status | grep -q 'No nodes are currently marked as isolated'"

echo
echo "Passed: ${pass}"
echo "Failed: ${fail}"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
