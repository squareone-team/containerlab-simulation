#!/bin/bash
set +e

# Theme T1 (Border Routing & Internet) verification gate.
# This script is strict for T1-owned features and intentionally avoids
# validating other members' theme-specific behavior.

LAB="esi-datacenter"
C="docker exec clab-${LAB}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNBOOK="${LAB_ROOT}/configs/orientation-runbook.sh"

PASS=0
FAIL=0
WARN=0
LAST_OUT=""

ok()   { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail() { echo "  [FAIL] $1"; ((FAIL++)); return 0; }
warn() { echo "  [WARN] $1"; ((WARN++)); return 0; }
info() { echo "  [INFO] $1"; }

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
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$regex"; then
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

container_exists() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

echo "=== ESI Theme T1 Verification (Border Routing & Internet) ==="

# ---------------------------------------------------------------------------
# 0) Preflight
# ---------------------------------------------------------------------------
for node in leaf-01 leaf-02 isp-router-01 isp-router-02 isp-router-03; do
  if container_exists "clab-${LAB}-${node}"; then
    ok "container present: ${node}"
  else
    fail "container missing: ${node}"
  fi
done

for node in internet-web-01 campus-bp server-student-01 server-dmz-01; do
  if container_exists "clab-${LAB}-${node}"; then
    ok "container present: ${node}"
  else
    fail "container missing: ${node}"
  fi
done

# ---------------------------------------------------------------------------
# 1) External eBGP sessions (active links + third ISP reachability)
# ---------------------------------------------------------------------------
cmd_match "leaf-01 eBGP Up to isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.113\\.2"

cmd_match "leaf-02 eBGP Up to isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.113\\.6"

cmd_match "leaf-01 third ISP neighbor present" \
  "$C-leaf-01 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.114\\.2"

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
  "1"

cmd_match "leaf-02 uses external MD5 secret" \
  "$C-leaf-02 grep -c 'ESI-BGP-EXTERNAL' /etc/frr/frr.conf" \
  "1"

cmd_match "leaf-01 still uses internal MD5 for fabric sessions" \
  "$C-leaf-01 grep -c 'ESI-BGP-INTERNAL' /etc/frr/frr.conf" \
  "1"

for leaf in leaf-01 leaf-02; do
  for line in \
    "ip prefix-list ISP-IN" \
    "ip prefix-list ISP-OUT" \
    "maximum-prefix"; do
    cmd_match "${leaf} has policy element: ${line}" \
      "$C-${leaf} vtysh -c 'show running-config'" \
      "${line}"
  done
done

cmd_match "leaf-01 applies ISP-IN inbound" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 prefix-list ISP-IN in"

cmd_match "leaf-01 applies ISP-OUT outbound" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 prefix-list ISP-OUT out"

cmd_match "leaf-02 applies ISP-IN inbound" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 prefix-list ISP-IN in"

cmd_match "leaf-02 applies ISP-OUT outbound" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 prefix-list ISP-OUT out"

cmd_match "leaf-01 max-prefix threshold on external peer" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 maximum-prefix 100 80"

cmd_match "leaf-02 max-prefix threshold on external peer" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 maximum-prefix 100 80"

cmd_no_match "leaf-01 does not set max-prefix on fabric peers" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 10\\.0\\.[01]\\.0 maximum-prefix"

cmd_no_match "leaf-02 does not set max-prefix on fabric peers" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 10\\.0\\.[01]\\.2 maximum-prefix"

# ---------------------------------------------------------------------------
# 3) Route acceptance and leakage control
# ---------------------------------------------------------------------------
cmd_match "leaf-01 receives default route from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp neighbors 203.0.113.2 routes'" \
  "0\\.0\\.0\\.0/0"

cmd_match "leaf-02 receives default route from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp neighbors 203.0.113.6 routes'" \
  "0\\.0\\.0\\.0/0"

cmd_no_match "leaf-01 does not accept non-default from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp neighbors 203.0.113.2 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-02 does not accept non-default from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp neighbors 203.0.113.6 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-01 does not leak RFC1918 to isp-router-01" \
  "$C-isp-router-01 vtysh -c 'show ip bgp neighbors 203.0.113.1 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

cmd_no_match "leaf-02 does not leak RFC1918 to isp-router-02" \
  "$C-isp-router-02 vtysh -c 'show ip bgp neighbors 203.0.113.5 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

# ---------------------------------------------------------------------------
# 4) VRF default-route behavior (T1 scope)
# ---------------------------------------------------------------------------
cmd_match "border has default in VRF-PEDAGOGY" \
  "$C-leaf-01 ip route show vrf VRF-PEDAGOGY" \
  "default"

cmd_match "student leaf imports default in VRF-PEDAGOGY" \
  "$C-leaf-09 ip route show vrf VRF-PEDAGOGY" \
  "default"

cmd_match "VRF-WIFI-CTRL contains only dedicated /32 destination" \
  "$C-leaf-01 ip route show vrf VRF-WIFI-CTRL" \
  "192\\.168\\.10\\.100(/32)?"

cmd_no_match "VRF-WIFI-CTRL has no default route" \
  "$C-leaf-01 ip route show vrf VRF-WIFI-CTRL" \
  "^default"

test_banner "campus-bp reaches WiFi controller via dedicated /32 path"
LAST_OUT=$($C-campus-bp ping -c2 -W1 192.168.10.100 2>/dev/null)
if echo "$LAST_OUT" | grep -Eq "2 (packets )?received"; then
  ok "campus-bp reaches WiFi controller via dedicated /32 path"
else
  warn "campus-bp cannot reach WiFi controller yet (endpoint path may depend on T2 readiness)"
  echo "  [DEBUG] output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 5) Third ISP isolation + orientation activation runbook
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
# 6) Monitoring artifacts owned by T1 (Prometheus/Grafana/frr-exporter)
# ---------------------------------------------------------------------------
if container_exists "clab-${LAB}-prometheus"; then
  PROM_IP="$(container_ip prometheus)"
  if [ -n "$PROM_IP" ] && wait_http_ok "http://${PROM_IP}:9090/api/v1/targets" 25 2 && curl -s "http://${PROM_IP}:9090/api/v1/targets" >/tmp/t1-prom-targets.json 2>/dev/null; then
    ok "prometheus API reachable"
    grep -Eq "frr[_-]exporter|frr-exporter" /tmp/t1-prom-targets.json && ok "prometheus has frr exporter target" || fail "prometheus has frr exporter target"
    grep -Eq '"instance":"frr-exporter:9342".*"health":"up"' /tmp/t1-prom-targets.json && ok "prometheus exporter target health is up" || fail "prometheus exporter target health is up"
  else
    fail "prometheus API reachable"
    fail "prometheus has frr exporter target"
    fail "prometheus exporter target health is up"
  fi
else
  fail "prometheus container missing"
  fail "prometheus exporter target health is up"
fi

if container_exists "clab-${LAB}-grafana"; then
  GRAFANA_IP="$(container_ip grafana)"
  [ -n "$GRAFANA_IP" ] && wait_http_ok "http://${GRAFANA_IP}:3000/api/health" 30 2 && ok "grafana HTTP reachable" || fail "grafana HTTP reachable"
else
  fail "grafana container missing"
fi

# ---------------------------------------------------------------------------
# 7) VNI Correction Validation (LMS and Services mapping)
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
# T1 must prove internet reachability outcomes while preserving security boundaries.
# Duplicate ICMP behavior can be related to multihoming/loop handling (T2 scope),
# so T1 gates only on reachability and logs duplicates as diagnostics.
cmd_match "Student reaches external internet endpoint" \
  "$C-server-student-01 ping -c2 -W2 198.18.3.10" \
  "2 (packets )?received"

test_banner "Student outbound duplicate check (diagnostic, T2/ESI-owned)"
LAST_OUT=$($C-server-student-01 ping -c2 -W2 198.18.3.10 2>/dev/null)
if echo "$LAST_OUT" | grep -Eq "\(DUP!\)|duplicates"; then
  warn "Duplicate ICMP replies observed on student outbound path (review T2 ESI behavior)"
else
  ok "No duplicate ICMP replies observed on student outbound path"
fi

test_banner "Internet cannot initiate unsolicited access to student host"
LAST_OUT=$($C-internet-web-01 ping -c2 -W2 192.168.10.10 2>/dev/null)
if echo "$LAST_OUT" | grep -Eq "0 (packets )?received|100% packet loss|unreachable"; then
  ok "Internet initiation toward student host is blocked"
else
  fail "Internet can initiate toward student host (unexpected)"
  echo "  [DEBUG] output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

cmd_match "Internet reaches public DMZ host" \
  "$C-internet-web-01 ping -c2 -W2 192.168.100.10" \
  "2 (packets )?received"

test_banner "Border leaf performs no NAT/PAT"
LAST_OUT=$($C-leaf-01 iptables-save -t nat 2>/dev/null | grep -E 'MASQUERADE|SNAT|DNAT' || true)
if [ -z "$LAST_OUT" ]; then
  ok "No NAT/PAT rules found on border leaf"
else
  fail "Border leaf has NAT/PAT rules (violates architecture ownership)"
  echo "  [DEBUG] output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

echo
echo "Results: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
if [ "$FAIL" -eq 0 ]; then
  echo "Theme T1 READY"
  exit 0
fi

echo "Theme T1 NOT ready"
exit 1
