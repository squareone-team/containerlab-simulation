#!/usr/bin/env bash
set +e

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="${CLAB_PREFIX:-clab-${LAB}}"
RESILIENCY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../resiliancy" && pwd)/simulate_node_down.sh"

FAILED_FIREWALL="${FAILED_FIREWALL:-firewall-01}"
FAILED_SPINE="${FAILED_SPINE:-spine-02}"
FAILED_LEAVES="${FAILED_LEAVES:-leaf-02 leaf-04 leaf-06 leaf-08 leaf-10}"
RETRIES="${HEAVY_RESILIENCE_RETRIES:-20}"
DELAY="${HEAVY_RESILIENCE_DELAY:-3}"
COMMAND_TIMEOUT="${HEAVY_RESILIENCE_COMMAND_TIMEOUT:-15}"

PASS=0
FAIL=0
LAST_OUT=""

ok() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

ko() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
  [ -n "$LAST_OUT" ] && echo "$LAST_OUT" | sed 's/^/  /'
}

node_cmd() {
  local node="$1"
  shift
  timeout "$COMMAND_TIMEOUT" docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*" 2>&1
}

check_node() {
  local label="$1"
  local node="$2"
  local cmd="$3"
  local attempt=1

  while [ "$attempt" -le "$RETRIES" ]; do
    LAST_OUT="$(node_cmd "$node" "$cmd")"
    if [ "$?" -eq 0 ]; then
      ok "$label"
      return 0
    fi
    sleep "$DELAY"
    attempt=$((attempt + 1))
  done

  ko "$label"
  return 0
}

check_host() {
  local label="$1"
  local cmd="$2"
  local attempt=1

  while [ "$attempt" -le "$RETRIES" ]; do
    LAST_OUT="$(timeout "$COMMAND_TIMEOUT" bash -lc "$cmd" 2>&1)"
    if [ "$?" -eq 0 ]; then
      ok "$label"
      return 0
    fi
    sleep "$DELAY"
    attempt=$((attempt + 1))
  done

  ko "$label"
  return 0
}

check_not_node() {
  local label="$1"
  local node="$2"
  local cmd="$3"

  LAST_OUT="$(node_cmd "$node" "$cmd")"
  if [ "$?" -ne 0 ]; then
    ok "$label"
  else
    ko "$label"
  fi
  return 0
}

echo "=== Heavy Resilience Scenario Validation ==="
echo "Failed firewall : ${FAILED_FIREWALL}"
echo "Failed spine    : ${FAILED_SPINE}"
echo "Failed leaves   : ${FAILED_LEAVES}"
echo

EXPECTED_ISOLATED="${FAILED_FIREWALL} ${FAILED_SPINE} ${FAILED_LEAVES}"
for node in $EXPECTED_ISOLATED; do
  check_host "resilience state marks ${node} isolated" \
    "${RESILIENCY_SCRIPT} --status | grep -qw '${node}'"
done

echo
echo "--- Management-plane observability isolation ---"
check_node "zabbix-server uses management IP 172.20.20.50" \
  "zabbix-server" \
  "ip -4 -o addr show dev eth0 | grep -q '172.20.20.50/'"

check_not_node "zabbix-server has no fabric eth1 link" \
  "zabbix-server" \
  "ip link show eth1"

check_node "syslog-server uses management IP 172.20.20.70" \
  "syslog-server" \
  "ip -4 -o addr show dev eth0 | grep -q '172.20.20.70/'"

check_not_node "syslog-server has no fabric eth1 link" \
  "syslog-server" \
  "ip link show eth1"

check_node "syslog-server listens on TCP/514" \
  "syslog-server" \
  "netstat -tln 2>/dev/null | grep -q ':514 ' || ss -tln 2>/dev/null | grep -q ':514 '"

MGMT_SNMP_TARGETS="
spine-01 172.20.20.11
spine-02 172.20.20.12
leaf-01 172.20.20.21
leaf-02 172.20.20.22
leaf-03 172.20.20.23
leaf-04 172.20.20.24
leaf-05 172.20.20.25
leaf-06 172.20.20.26
leaf-07 172.20.20.27
leaf-08 172.20.20.28
leaf-09 172.20.20.29
leaf-10 172.20.20.30
"

while read -r node ip; do
  [ -z "$node" ] && continue
  check_node "Zabbix SNMP reaches ${node} over management (${ip})" \
    "zabbix-server" \
    "snmpget -v2c -c esi-read -t2 -r0 ${ip} 1.3.6.1.2.1.1.1.0 | grep -q 'STRING:'"
done <<EOF
$MGMT_SNMP_TARGETS
EOF

TOKEN="HEAVY_RESILIENCE_$(date +%s)"
for source in $FAILED_SPINE $FAILED_LEAVES server-admin-01 server-student-01 server-dmz-01; do
  check_node "${source} can inject syslog over management" \
    "$source" \
    "logger -t HEAVY-RESILIENCE '${TOKEN}-${source}'"
  check_node "syslog-server received log from ${source}" \
    "syslog-server" \
    "grep -q '${TOKEN}-${source}' /var/log/messages"
done

echo
echo "--- Surviving data-plane reachability ---"
if [ "$FAILED_FIREWALL" = "firewall-01" ]; then
  ACTIVE_FIREWALL="firewall-02"
else
  ACTIVE_FIREWALL="firewall-01"
fi

check_node "${ACTIVE_FIREWALL} owns Ring1 VIP" \
  "$ACTIVE_FIREWALL" \
  "ip -4 addr show bond0 | grep -q '192.168.1.254/24'"

check_node "leaf-01 reaches active firewall VIP" \
  "leaf-01" \
  "ping -c2 -W2 192.168.1.254 >/dev/null"

check_node "student pod east-west reachability survives" \
  "server-student-01" \
  "ping -c2 -W2 192.168.10.20 >/dev/null"

check_node "student pod reaches core DNS through surviving path" \
  "server-student-01" \
  "nslookup dmz-server-01.esi.internal 192.168.50.30 | grep -q '198.51.100.10'"

check_node "admin workload reaches DNS core service" \
  "server-admin-01" \
  "ping -c2 -W2 192.168.50.30 >/dev/null"

check_node "HPC pod east-west reachability survives" \
  "server-hpc-01" \
  "ping -c2 -W2 192.168.70.20 >/dev/null"

check_node "HPC pod reaches DNS core service" \
  "server-hpc-01" \
  "ping -c2 -W2 192.168.50.30 >/dev/null"

check_node "storage server reaches its anycast gateway" \
  "server-storage-01" \
  "ping -c2 -W2 192.168.80.1 >/dev/null"

check_node "distribution-switch reaches DMZ HTTP through surviving firewall" \
  "distribution-switch" \
  "wget -qO- -T 5 http://198.51.100.10 | grep -q 'ESI Datacenter DMZ test service is reachable'"

if [ "$FAILED_SPINE" = "spine-01" ]; then
  ACTIVE_SPINE="spine-02"
  ACTIVE_UNDERLAY_PREFIX="10.0.1."
else
  ACTIVE_SPINE="spine-01"
  ACTIVE_UNDERLAY_PREFIX="10.0.0."
fi

for leaf in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
  case " ${FAILED_LEAVES} " in
    *" ${leaf} "*) continue ;;
  esac
  check_node "${leaf} keeps a BGP session to ${ACTIVE_SPINE}" \
    "$leaf" \
    "vtysh -c 'show bgp summary' 2>/dev/null | awk -v p='${ACTIVE_UNDERLAY_PREFIX}' '\$1 ~ (\"^\" p) && \$10 ~ /^[0-9]+$/ {found=1} END {exit !found}'"
done

echo
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[ "$FAIL" -eq 0 ]
