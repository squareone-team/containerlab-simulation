#!/bin/bash
# =============================================================================
# tests/snmp_verify.sh
# Theme   : T4 — Observability and Monitoring
# Section : Zabbix + SNMP verification
# Run as  : bash implementations/frr-containerlab/scripts/tests/snmp_verify.sh
# =============================================================================

set +e

LAB="${LAB:-esi-datacenter}"
C="docker exec clab-${LAB}"
ZABBIX="clab-${LAB}-zabbix-server"
PASS=0
FAIL=0
WARN=0
LAST_OUT=""

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); return 0; }
info() { echo "  [INFO] $1"; return 0; }

container_exists() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

chk() {
  local label="$1" cmd="$2" pattern="$3"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$pattern"; then
    ok "$label"
  else
    fail "$label"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

warn_chk() {
  local label="$1" cmd="$2" pattern="$3"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$pattern"; then
    ok "$label"
  else
    warn "$label"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

api_post() {
  local payload="$1"
  $C-zabbix-server sh -lc \
    "curl -fsS -H 'Content-Type: application/json-rpc' --data-binary '$payload' http://127.0.0.1:8080/api_jsonrpc.php" \
    2>/dev/null
}

snmp_sysdescr() {
  local node="$1" ip="$2"
  chk "$node: SNMP sysDescr reachable at $ip" \
    "$C-zabbix-server snmpget -v2c -c esi-read -t2 -r0 $ip 1.3.6.1.2.1.1.1.0" \
    "STRING:"
}

snmp_bgp_state() {
  local node="$1" ip="$2" minimum="$3"
  local count established non_established

  LAST_OUT=$($C-zabbix-server snmpwalk -v2c -c esi-read -t2 -r0 \
    "$ip" 1.3.6.1.2.1.15.3.1.2 2>/dev/null)

  count=$(echo "$LAST_OUT" | grep -c "INTEGER:")
  established=$(echo "$LAST_OUT" | grep -c "INTEGER: 6")
  non_established=$(echo "$LAST_OUT" | grep "INTEGER:" | grep -vc "INTEGER: 6")

  if [ "$count" -ge "$minimum" ] && [ "$non_established" -eq 0 ]; then
    ok "$node: BGP MIB state table has $established established peer(s)"
  else
    fail "$node: BGP MIB state table unhealthy (rows=$count, established=$established, non-established=$non_established, min=$minimum)"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

echo ""
echo "=== T4: SNMP + Zabbix Observability Verification ==="
echo "    Zabbix UI: http://localhost:4000 | login Admin / zabbix"
echo "    SNMP path : Containerlab management network (172.20.20.0/24)"
echo ""

echo "--- 1. Container and service health ---"

if container_exists "$ZABBIX"; then
  ok "container present: zabbix-server"
else
  fail "container missing: zabbix-server"
  echo ""
  echo "Results: $PASS passed / $FAIL failed / $WARN warnings"
  exit "$FAIL"
fi

for node in spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10; do
  container_exists "clab-${LAB}-${node}" \
    && ok "container present: $node" \
    || fail "container missing: $node"
done

chk "zabbix_server process running" \
  "$C-zabbix-server pgrep zabbix_server" \
  "[0-9]+"

chk "MariaDB accepts Zabbix TCP login" \
  "$C-zabbix-server mysql -u zabbix -pzabbix-lab-pass -h 127.0.0.1 -e 'SELECT 1;' zabbix" \
  "1"

chk "PHP-FPM process running for Zabbix web" \
  "$C-zabbix-server pgrep php-fpm82" \
  "[0-9]+"

chk "nginx process running for Zabbix web" \
  "$C-zabbix-server pgrep nginx" \
  "[0-9]+"

chk "Zabbix frontend answers inside container on 8080" \
  "$C-zabbix-server curl -fsS http://127.0.0.1:8080/index.php" \
  "Zabbix|zabbix"

chk "Zabbix frontend is published on host port 4000" \
  "docker port $ZABBIX 8080/tcp" \
  "4000"

if command -v curl >/dev/null 2>&1; then
  warn_chk "Host can reach Zabbix UI at http://127.0.0.1:4000" \
    "curl -fsS http://127.0.0.1:4000/index.php" \
    "Zabbix|zabbix"
else
  warn "host curl missing; skipped 127.0.0.1:4000 HTTP check"
fi

echo ""
echo "--- 2. Zabbix API and provisioned dashboard objects ---"

chk "Zabbix API returns version" \
  "api_post '{\"jsonrpc\":\"2.0\",\"method\":\"apiinfo.version\",\"params\":{},\"id\":1}'" \
  "\"result\""

AUTH=$(api_post '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":2}' \
  | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')

if [ -n "$AUTH" ]; then
  ok "Zabbix API login works as Admin"

  HOSTS_JSON=$(api_post "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"output\":[\"host\"],\"filter\":{\"host\":[\"spine-01\",\"spine-02\",\"leaf-01\",\"leaf-10\"]}},\"auth\":\"$AUTH\",\"id\":3}")
  echo "$HOSTS_JSON" | grep -q '"spine-01"' && echo "$HOSTS_JSON" | grep -q '"leaf-10"' \
    && ok "Provisioned fabric hosts are present in Zabbix" \
    || { fail "Provisioned fabric hosts missing from Zabbix"; echo "$HOSTS_JSON" | sed 's/^/    /'; }

  DASH_JSON=$(api_post "{\"jsonrpc\":\"2.0\",\"method\":\"dashboard.get\",\"params\":{\"output\":[\"name\"],\"filter\":{\"name\":[\"ESI Fabric NOC\"]}},\"auth\":\"$AUTH\",\"id\":4}")
  echo "$DASH_JSON" | grep -q '"ESI Fabric NOC"' \
    && ok "Zabbix dashboard exists: ESI Fabric NOC" \
    || { fail "Zabbix dashboard missing: ESI Fabric NOC"; echo "$DASH_JSON" | sed 's/^/    /'; }

  MAP_JSON=$(api_post "{\"jsonrpc\":\"2.0\",\"method\":\"map.get\",\"params\":{\"output\":[\"name\"],\"filter\":{\"name\":[\"ESI Datacenter Fabric\"]}},\"auth\":\"$AUTH\",\"id\":5}")
  echo "$MAP_JSON" | grep -q '"ESI Datacenter Fabric"' \
    && ok "Zabbix topology map exists: ESI Datacenter Fabric" \
    || { fail "Zabbix topology map missing: ESI Datacenter Fabric"; echo "$MAP_JSON" | sed 's/^/    /'; }
else
  fail "Zabbix API login failed as Admin"
fi

echo ""
echo "--- 3. FRR SNMP agent and AgentX wiring ---"

for node in spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10; do
  chk "$node: snmpd process running" \
    "$C-$node pgrep snmpd" \
    "[0-9]+"

  chk "$node: FRR BGP MIB pass_persist installed" \
    "$C-$node grep '^pass_persist .1.3.6.1.2.1.15.3 ' /etc/snmp/snmpd.conf" \
    "frr-bgp-peer-mib.py"
done

echo ""
echo "--- 4. End-to-end SNMP polling from zabbix-server ---"

TARGETS="
spine-01 172.20.20.11 10
spine-02 172.20.20.12 10
leaf-01 172.20.20.21 2
leaf-02 172.20.20.22 2
leaf-03 172.20.20.23 2
leaf-04 172.20.20.24 2
leaf-05 172.20.20.25 2
leaf-06 172.20.20.26 2
leaf-07 172.20.20.27 2
leaf-08 172.20.20.28 2
leaf-09 172.20.20.29 2
leaf-10 172.20.20.30 2
"

while read -r node ip minimum; do
  [ -z "$node" ] && continue

  chk "$node: loopback ping reachable from zabbix-server" \
    "$C-zabbix-server ping -c1 -W1 $ip" \
    "[1-9][0-9]* (packets )?received"

  snmp_sysdescr "$node" "$ip"
  snmp_bgp_state "$node" "$ip" "$minimum"
done < <(printf '%s\n' "$TARGETS")

echo ""
echo "======================================"
echo "SNMP/Zabbix Results: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
[ "$FAIL" -eq 0 ] \
  && echo "SNMP + Zabbix observability READY" \
  || echo "NOT ready — fix failures above"
echo "======================================"

exit "$FAIL"
