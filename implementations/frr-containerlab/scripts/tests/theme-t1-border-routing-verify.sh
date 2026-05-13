#!/bin/bash
set +e

LAB="esi-datacenter"
C="docker exec clab-${LAB}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNBOOK="${LAB_ROOT}/configs/orientation-runbook.sh"

PASS=0
FAIL=0
WARN=0
LAST_OUT=""
RETRIES="${T1_RETRIES:-12}"
DELAY="${T1_DELAY:-2}"

ok()   { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail() { echo "  [FAIL] $1"; ((FAIL++)); return 0; }
warn() { echo "  [WARN] $1"; ((WARN++)); return 0; }
info() { echo "  [INFO] $1"; }

container_exists() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

retry_match() {
  local cmd="$1"
  local regex="$2"
  local i=1
  while [ "$i" -le "$RETRIES" ]; do
    LAST_OUT=$(eval "$cmd" 2>/dev/null)
    if echo "$LAST_OUT" | grep -Eq "$regex"; then
      return 0
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  return 1
}

test_banner() {
  echo
  echo "[TEST] $1"
}

cmd_match() {
  local title="$1"
  local cmd="$2"
  local regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : /$regex/"
  if retry_match "$cmd" "$regex"; then
    ok "$title"
  else
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

cmd_no_match() {
  local title="$1"
  local cmd="$2"
  local regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : not /$regex/"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$regex"; then
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  else
    ok "$title"
  fi
}

only_default_from_neighbor() {
  local title="$1"
  local cmd="$2"
  local i=1
  local prefixes=""

  test_banner "$title"
  info "command: $cmd"
  info "expect : only 0.0.0.0/0"

  while [ "$i" -le "$RETRIES" ]; do
    LAST_OUT=$(eval "$cmd" 2>/dev/null)
    prefixes=$(echo "$LAST_OUT" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | sort -u)
    if [ "$prefixes" = "0.0.0.0/0" ]; then
      ok "$title"
      return 0
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done

  fail "$title"
  echo "  [DEBUG] extracted prefixes:"
  echo "$prefixes" | sed 's/^/    /'
  echo "  [DEBUG] output:"
  echo "$LAST_OUT" | sed 's/^/    /'
  return 0
}

ping_with_retry() {
  local title="$1"
  local cmd="$2"
  local recv_regex="$3"
  local i=1

  test_banner "$title"
  info "command: $cmd"
  info "expect : /$recv_regex/"

  while [ "$i" -le "$RETRIES" ]; do
    LAST_OUT=$(eval "$cmd" 2>/dev/null)
    if echo "$LAST_OUT" | grep -Eq "$recv_regex"; then
      ok "$title"
      return 0
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done

  fail "$title"
  echo "  [DEBUG] output:"
  echo "$LAST_OUT" | sed 's/^/    /'
  return 0
}

cmd_ping_no_dup() {
  local title="$1"
  local cmd="$2"
  local received_regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : /$received_regex/ and no duplicates"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$received_regex" && ! echo "$LAST_OUT" | grep -Eq "\(DUP!\)|duplicates"; then
    ok "$title"
  else
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

wait_http_ok() {
  local url="$1"
  local tries="${2:-20}"
  local delay="${3:-2}"
  local n=1

  while [ "$n" -le "$tries" ]; do
    curl -sS "$url" >/dev/null 2>&1 && return 0
    sleep "$delay"
    n=$((n + 1))
  done

  return 1
}

container_ip() {
  docker inspect "clab-${LAB}-$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1
}

check_container() {
  local node="$1"
  if docker ps --format '{{.Names}}' | grep -qx "clab-${LAB}-${node}"; then
    ok "container present: ${node}"
  else
    fail "container missing: ${node}"
  fi
}

echo "=== ESI Theme T1 Verification (Border Routing & Internet) ==="

echo
for node in campus-bp student-bp-01 internet-router-01 internet-web-01 internet-client-01 server-dmz-01 leaf-01; do
  check_container "$node"
done

# ---------------------------------------------------------------------------
# 1) External eBGP sessions (active links + third ISP reachability)
# ---------------------------------------------------------------------------
cmd_match "leaf-01 eBGP Up to isp-router-01 (VRF-PUBLIC)" \
  "$C-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC neighbors 203.0.113.2'" \
  "BGP state = Established"

cmd_match "leaf-02 eBGP Up to isp-router-02" \
  "$C-leaf-02 vtysh -c 'show bgp neighbors 203.0.113.6'" \
  "BGP state = Established"

cmd_match "leaf-01 third ISP neighbor present" \
  "$C-leaf-01 vtysh -c 'show bgp neighbors 203.0.114.2'" \
  "BGP state = Established"

cmd_match "leaf-01 ping isp-router-01" \
  "$C-leaf-01 ping -c2 -W1 203.0.113.2" \
  "2 (packets )?received"

cmd_match "leaf-02 ping isp-router-02" \
  "$C-leaf-02 ping -c2 -W1 203.0.113.6" \
  "2 (packets )?received"

cmd_match "leaf-01 ping isp-router-03" \
  "$C-leaf-01 ping -c2 -W1 203.0.114.2" \
  "2 (packets )?received"

# ---------------------------------------------------------------------------
# 2) Border policy controls: MD5 secrets, prefix-lists + max-prefix
# ---------------------------------------------------------------------------
cmd_match "leaf-01 uses external MD5 secret" \
  "$C-leaf-01 grep -c 'ESI-BGP-EXTERNAL' /etc/frr/frr.conf" \
  "^[1-9][0-9]*$"

cmd_match "leaf-02 uses external MD5 secret" \
  "$C-leaf-02 grep -c 'ESI-BGP-EXTERNAL' /etc/frr/frr.conf" \
  "^[1-9][0-9]*$"

cmd_match "leaf-01 still uses internal MD5 for fabric sessions" \
  "$C-leaf-01 grep -c 'ESI-BGP-INTERNAL' /etc/frr/frr.conf" \
  "1"
# ---------------------------------------------------------------------------
# 3) Route acceptance and leakage control
# ---------------------------------------------------------------------------
cmd_match "leaf-01 receives default route from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC ipv4 unicast neighbors 203.0.113.2 routes'" \
  "0\\.0\\.0\\.0/0"

cmd_match "leaf-02 receives default route from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show bgp ipv4 unicast neighbors 203.0.113.6 routes'" \
  "0\\.0\\.0\\.0/0"

only_default_from_neighbor "leaf-01 accepts only default from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC ipv4 unicast neighbors 203.0.113.2 routes'"

only_default_from_neighbor "leaf-02 accepts only default from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show bgp ipv4 unicast neighbors 203.0.113.6 routes'"

cmd_no_match "leaf-01 does not accept non-default from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC ipv4 unicast neighbors 203.0.113.2 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-02 does not accept non-default from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show bgp ipv4 unicast neighbors 203.0.113.6 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-01 does not leak RFC1918 to isp-router-01" \
  "$C-isp-router-01 vtysh -c 'show ip bgp neighbors 203.0.113.1 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

cmd_no_match "leaf-02 does not leak RFC1918 to isp-router-02" \
  "$C-isp-router-02 vtysh -c 'show ip bgp neighbors 203.0.113.5 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

# ---------------------------------------------------------------------------
# 4) Third ISP isolation + orientation activation runbook
# ---------------------------------------------------------------------------
cmd_no_match "VRF-ORIENTATION empty before activation" \
  "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
  "."

if [ -f "$RUNBOOK" ]; then
  if [ -x "$RUNBOOK" ]; then
    "$RUNBOOK" --activate >/dev/null 2>&1
    cmd_match "VRF-ORIENTATION receives route after activation" \
      "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
      "default|203\\.0\\.114"

    "$RUNBOOK" --deactivate >/dev/null 2>&1
    cmd_no_match "VRF-ORIENTATION empty after deactivation" \
      "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
      "."
  else
    fail "orientation runbook exists but is not executable"
  fi
else
  fail "missing configs/orientation-runbook.sh (required by T1)"
fi

# ---------------------------------------------------------------------------
# 5) Monitoring artifacts owned by T1 (Prometheus/Grafana/fabric-telemetry)
# ---------------------------------------------------------------------------
if container_exists "clab-${LAB}-prometheus"; then
  PROM_IP="$(container_ip prometheus)"
  if [ -n "$PROM_IP" ] && wait_http_ok "http://${PROM_IP}:9090/api/v1/targets" 25 2 && curl -s "http://${PROM_IP}:9090/api/v1/targets" >/tmp/t1-prom-targets.json 2>/dev/null; then
    ok "prometheus API reachable"
    grep -q "fabric-telemetry" /tmp/t1-prom-targets.json && ok "prometheus has fabric telemetry scraper target" || fail "prometheus has fabric telemetry scraper target"
    grep -Eq '"instance":"fabric-telemetry:9342".*"health":"up"' /tmp/t1-prom-targets.json && ok "prometheus fabric telemetry target health is up" || fail "prometheus fabric telemetry target health is up"
  else
    fail "prometheus API reachable"
    fail "prometheus has fabric telemetry scraper target"
    fail "prometheus fabric telemetry target health is up"
  fi
else
  fail "prometheus container missing"
  fail "prometheus fabric telemetry target health is up"
fi

if container_exists "clab-${LAB}-grafana"; then
  GRAFANA_IP="$(container_ip grafana)"
  [ -n "$GRAFANA_IP" ] && wait_http_ok "http://${GRAFANA_IP}:3000/api/health" 30 2 && ok "grafana HTTP reachable" || fail "grafana HTTP reachable"
else
  fail "grafana container missing"
fi

# ---------------------------------------------------------------------------
# 6) VNI Correction Validation (LMS and Services mapping, done in phase 1)
# ---------------------------------------------------------------------------
cmd_match "LMS-STAFF VNI on admin-leaf (leaf-03)" \
  "$C-leaf-03 vtysh -c 'show evpn vni 10030'" \
  "10030"

cmd_no_match "LMS-STAFF NOT on border-leaf (leaf-01)" \
  "$C-leaf-01 vtysh -c 'show evpn vni'" \
  "10030"

cmd_match "SERVICES-WEB VNI on admin-leaf (leaf-03)" \
  "$C-leaf-03 vtysh -c 'show evpn vni 10040'" \
  "10040"

cmd_no_match "SERVICES-WEB NOT on border-leaf (leaf-01)" \
  "$C-leaf-01 vtysh -c 'show evpn vni'" \
  "10040"

# ---------------------------------------------------------------------------
# 8) Intuitive Objective: True Internet Reachability (Behavioral E2E)
# ---------------------------------------------------------------------------
echo
cmd_match "authenticated campus student can reach internet-web-01" \
  "$C-campus-student-01 wget -qO- -T 5 http://198.18.3.10/" \
  "Google Search"

echo
cmd_match "authenticated campus student resolves moodle.esi.dz via dns-server" \
  "$C-campus-student-01 nslookup moodle.esi.dz 192.168.50.30" \
  "Address: 198\\.51\\.100\\.30|Address.*198\\.51\\.100\\.30"

cmd_match "authenticated campus student resolves www.google.com via dns-server" \
  "$C-campus-student-01 nslookup www.google.com 192.168.50.30" \
  "Address: 198\\.18\\.3\\.10|Address.*198\\.18\\.3\\.10"

cmd_match "authenticated campus student HTTP GET moodle.esi.dz reaches Moodle" \
  "$C-campus-student-01 wget -qO- -T 8 http://moodle.esi.dz/" \
  "Moodle|TP - NAC"

test_banner "unauthenticated campus client cannot reach internet-web-01"
info "command: $C-student-bp-01 timeout 4 nc -z -w2 198.18.3.10 80"
if $C-student-bp-01 timeout 4 nc -z -w2 198.18.3.10 80 >/dev/null 2>&1; then
  fail "unauthenticated campus client cannot reach internet-web-01"
else
  ok "unauthenticated campus client cannot reach internet-web-01"
fi

test_banner "unauthenticated campus client cannot reach server-dmz-01"
info "command: $C-student-bp-01 timeout 4 nc -z -w2 198.51.100.10 80"
if $C-student-bp-01 timeout 4 nc -z -w2 198.51.100.10 80 >/dev/null 2>&1; then
  fail "unauthenticated campus client cannot reach server-dmz-01"
else
  ok "unauthenticated campus client cannot reach server-dmz-01"
fi

echo
ping_with_retry "internet-client-01 can reach server-dmz-01 (198.51.100.10)" \
  "$C-internet-client-01 ping -c2 -W2 198.51.100.10" \
  "2 (packets )?received"

echo
echo "[TEST] DMZ endpoint uses non-RFC1918 addressing"
OUT=$($C-server-dmz-01 ip -4 -o addr show dev eth1 2>/dev/null)
if echo "$OUT" | grep -Eq "198\.51\.100\.10/24"; then
  ok "server-dmz-01 uses public/testnet address space"
else
  fail "server-dmz-01 is not using expected public/testnet address"
  echo "$OUT" | sed 's/^/    /'
fi

echo
echo "[TEST] No legacy static-route hacks on internet/ISP edge"
EDGE_FILES=(
  "/etc/frr/frr.conf:internet-router-01"
  "/etc/frr/frr.conf:isp-router-01"
  "/etc/frr/frr.conf:isp-router-04"
)
LEGACY_REGEX='ip route (192\.168\.|198\.19\.9\.)'
for item in "${EDGE_FILES[@]}"; do
  cfg="${item%%:*}"
  node="${item##*:}"
  OUT=$($C-${node} grep -E "$LEGACY_REGEX" "$cfg" 2>/dev/null)
  if [ -z "$OUT" ]; then
    ok "${node} has no legacy static private-route hacks"
  else
    fail "${node} still has legacy static private-route hacks"
    echo "$OUT" | sed 's/^/    /'
  fi
done

echo
echo "Results: ${PASS} passed / ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then
  echo "Theme T1 READY"
  exit 0
fi

echo "Theme T1 NOT ready"
exit 1
